{ config, lib, pkgs, ... }:
let
  ip = "${pkgs.iproute2}/bin/ip";
  iptables = "${pkgs.iptables}/bin/iptables";
  ip6tables = "${pkgs.ip6tables}/bin/ip6tables";

  # Setuid helper: enters the claude-jail netns and drops back to calling user
  nsenter-cj = pkgs.runCommandCC "nsenter-claude-jail" { } ''
    mkdir -p $out/bin
    cat > main.c << 'EOF'
#define _GNU_SOURCE
#include <sched.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
  int fd = open("/var/run/netns/claude-jail", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { perror("open /var/run/netns/claude-jail"); return 1; }
  if (setns(fd, CLONE_NEWNET) < 0) { perror("setns"); return 1; }
  close(fd);
  if (setgid(getgid()) < 0 || setuid(getuid()) < 0) { perror("drop privs"); return 1; }
  if (argc < 2) {
    char *sh[] = {"/bin/sh", NULL};
    execv("/bin/sh", sh);
  } else {
    execvp(argv[1], argv + 1);
  }
  perror(argc < 2 ? "/bin/sh" : argv[1]);
  return 1;
}
EOF
    cc -o $out/bin/nsenter-claude-jail main.c
  '';

  # Public DNS resolvers for the jail
  publicResolvers = [
    "1.1.1.1"    # Cloudflare
    "9.9.9.9"    # Quad9
    "8.8.8.8"    # Google
  ];

  # Generate resolv.conf content with public resolvers
  resolvConfContent = lib.concatStringsSep "\n" (
    map (r: "nameserver ${r}") publicResolvers
  );

  resolvConfPath = pkgs.writeText "resolv.conf.claude-jail" "${resolvConfContent}\n";

  # Wrapper script: nsenter -> setpriv -> bwrap -> landrun -> claude
  claudeJailWrapper = pkgs.writeShellScriptBin "claude-jail" ''
    #!${pkgs.runtimeShell}
    set -euo pipefail

    # Ensure we're in the namespace
    exec ${nsenter-cj}/bin/nsenter-claude-jail ${pkgs.setpriv}/bin/setpriv --reuid=$(id -u) --regid=$(id -g) --clear-groups --init-groups -- ${pkgs.bubblewrap}/bin/bwrap \
      --ro-bind /nix/store /nix/store \
      --ro-bind /run/opengl-driver /run/opengl-driver \
      --ro-bind /run/current-system/sw /run/current-system/sw \
      --ro-bind /etc/passwd /etc/passwd \
      --ro-bind /etc/group /etc/group \
      --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf \
      --ro-bind /etc/ssl/certs /etc/ssl/certs \
      --ro-bind /etc/ca-certificates /etc/ca-certificates \
      --ro-bind /etc/machine-id /etc/machine-id \
      --bind ${resolvConfPath} /etc/resolv.conf \
      --bind $PWD $PWD \
      --bind $HOME/.claude $HOME/.claude \
      --bind $HOME/.claude.json $HOME/.claude.json \
      --bind $HOME/.cache $HOME/.cache \
      --bind $HOME/.config $HOME/.config \
      --bind $HOME/.local $HOME/.local \
      --tmpfs /tmp \
      --tmpfs /run/user/$(id -u) \
      --proc /proc \
      --dev /dev \
      --dev-bind /dev/dri /dev/dri \
      --chdir $PWD \
      --unshare-all \
      --share-net \
      --die-with-parent \
      -- ${pkgs.landrun}/bin/landrun -- ${pkgs.claude-code}/bin/claude "$@"
  '';

in
{
  # Setuid wrapper so regular users can enter the namespace
  security.wrappers.nsenter-claude-jail = {
    source = "${nsenter-cj}/bin/nsenter-claude-jail";
    owner = "root";
    group = "root";
    setuid = true;
  };

  environment.systemPackages = [ claudeJailWrapper ];

  # Network namespace setup with egress filtering
  systemd.services.netns-claude-jail = {
    description = "claude-jail network namespace (egress filtered)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${ip} netns add claude-jail

      # veth pair: veth-cj (host) <-> veth-cj-ns (namespace)
      ${ip} link add veth-cj type veth peer name veth-cj-ns
      ${ip} link set veth-cj-ns netns claude-jail

      # Host side: 10.200.201.1/30
      ${ip} addr add 10.200.201.1/30 dev veth-cj
      ${ip} addr add fd00:201::1/64 dev veth-cj
      ${ip} link set veth-cj up

      # Namespace side: 10.200.201.2/30
      ${ip} -n claude-jail addr add 10.200.201.2/30 dev veth-cj-ns
      ${ip} -n claude-jail addr add fd00:201::2/64 dev veth-cj-ns
      ${ip} -n claude-jail link set veth-cj-ns up
      ${ip} -n claude-jail link set lo up

      # Default route via host
      ${ip} -n claude-jail route add default via 10.200.201.1
      ${ip} -n claude-jail -6 route add default via fd00:201::1

      # EGRESS FILTERING: Drop traffic to LAN/host subnets
      # RFC1918
      ${iptables} -n claude-jail -A OUTPUT -d 10.0.0.0/8 -j DROP
      ${iptables} -n claude-jail -A OUTPUT -d 172.16.0.0/12 -j DROP
      ${iptables} -n claude-jail -A OUTPUT -d 192.168.0.0/16 -j DROP
      # Host link-local / loopback (except DNS to host veth IP)
      ${iptables} -n claude-jail -A OUTPUT -d 127.0.0.0/8 -j DROP
      ${iptables} -n claude-jail -A OUTPUT -d 169.254.0.0/16 -j DROP
      # Host's other interfaces (get primary IP dynamically would be better, but static for now)
      ${iptables} -n claude-jail -A OUTPUT -d 10.200.200.0/30 -j DROP  # glecom netns
      ${iptables} -n claude-jail -A OUTPUT -d 10.200.201.0/30 -j DROP  # own netns host side
      # Allow only: default route (internet via host), DNS to public resolvers
      # The default route via 10.200.201.1 handles internet egress
      # Explicitly allow DNS to public resolvers (redundant with default route but explicit)
      for resolver in 1.1.1.1 9.9.9.9 8.8.8.8; do
        ${iptables} -n claude-jail -I OUTPUT -d $resolver -p udp --dport 53 -j ACCEPT
        ${iptables} -n claude-jail -I OUTPUT -d $resolver -p tcp --dport 53 -j ACCEPT
      done
      # IPv6 equivalents
      ${ip6tables} -n claude-jail -A OUTPUT -d fc00::/7 -j DROP      # ULA
      ${ip6tables} -n claude-jail -A OUTPUT -d fe80::/10 -j DROP     # link-local
      ${ip6tables} -n claude-jail -A OUTPUT -d ::1/128 -j DROP        # loopback
      ${ip6tables} -n claude-jail -A OUTPUT -d fd00:200::/64 -j DROP  # glecom netns
      ${ip6tables} -n claude-jail -A OUTPUT -d fd00:201::/64 -j DROP  # own netns host side
      for resolver in 2606:4700:4700::1111 2620:fe::fe 2001:4860:4860::8888; do
        ${ip6tables} -n claude-jail -I OUTPUT -d $resolver -p udp --dport 53 -j ACCEPT
        ${ip6tables} -n claude-jail -I OUTPUT -d $resolver -p tcp --dport 53 -j ACCEPT
      done

      # Host side: DNAT for DNS to public resolvers (optional, namespace has direct route)
      # Masquerade namespace traffic leaving host
      ${iptables} -t nat -A POSTROUTING -s 10.200.201.0/30 -j MASQUERADE
      ${ip6tables} -t nat -A POSTROUTING -s fd00:201::/64 -j MASQUERADE
    '';
    preStop = ''
      ${iptables} -t nat -D POSTROUTING -s 10.200.201.0/30 -j MASQUERADE 2>/dev/null || true
      ${ip6tables} -t nat -D POSTROUTING -s fd00:201::/64 -j MASQUERADE 2>/dev/null || true
      # Clean up iptables rules in namespace (best effort)
      ${ip} netns exec claude-jail ${iptables} -F OUTPUT 2>/dev/null || true
      ${ip} netns exec claude-jail ${ip6tables} -F OUTPUT 2>/dev/null || true
      ${ip} link del veth-cj 2>/dev/null || true
      ${ip} netns del claude-jail 2>/dev/null || true
    '';
  };

  # IP forwarding for namespace traffic
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # NAT: masquerade namespace traffic leaving via default route
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables  -t nat -A POSTROUTING -s 10.200.201.0/30 -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -s fd00:201::/64   -j MASQUERADE
  '';
  networking.firewall.extraStopCommands = lib.mkAfter ''
    iptables  -t nat -D POSTROUTING -s 10.200.201.0/30 -j MASQUERADE 2>/dev/null || true
    ip6tables -t nat -D POSTROUTING -s fd00:201::/64   -j MASQUERADE 2>/dev/null || true
  '';
}
