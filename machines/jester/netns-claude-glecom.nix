{ config, lib, pkgs, ... }:
let
  ip = "${pkgs.iproute2}/bin/ip";

  # Setuid helper: enters the claude-glecom netns and drops back to calling user
  nsenter-cg = pkgs.runCommandCC "nsenter-claude-glecom" { } ''
    mkdir -p $out/bin
    cat > main.c << 'EOF'
#define _GNU_SOURCE
#include <sched.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
  int fd = open("/var/run/netns/claude-glecom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) { perror("open /var/run/netns/claude-glecom"); return 1; }
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
    cc -o $out/bin/nsenter-claude-glecom main.c
  '';
in
{
  # Setuid wrapper so regular users can enter the namespace
  security.wrappers.nsenter-claude-glecom = {
    source = "${nsenter-cg}/bin/nsenter-claude-glecom";
    owner = "root";
    group = "root";
    setuid = true;
  };

  # claude-glecom wrapper: runs claude inside the namespace with its own config dir.
  # claude-glecom-local: same config dir, no namespace (MCP servers stay on loopback).
  environment.systemPackages =
    let
      wrapper = name: mcpHost: execPrefix:
        pkgs.writeShellScriptBin name ''
          # Sync mcpServers from main Claude config so both profiles expose the same MCPs.
          # Everything else (oauthAccount, projects, subscription state) stays isolated.
          src="$HOME/.claude.json"
          dst="$HOME/.claude-glecom/.claude.json"
          if [ -f "$src" ] && [ -f "$dst" ]; then
            mcp=$(${pkgs.jq}/bin/jq -c .mcpServers "$src" 2>/dev/null)
            if [ -n "$mcp" ] && [ "$mcp" != "null" ]; then
              tmp=$(${pkgs.coreutils}/bin/mktemp "$dst.XXXXXX")
              if ${pkgs.jq}/bin/jq --argjson mcp "$mcp" '
                  .mcpServers = ($mcp | walk(
                    if type == "string"
                    then gsub("http://127\\.0\\.0\\.1:"; "http://${mcpHost}:")
                    else . end
                  ))' "$dst" > "$tmp"; then
                ${pkgs.coreutils}/bin/mv "$tmp" "$dst"
              else
                ${pkgs.coreutils}/bin/rm -f "$tmp"
                echo "${name}: mcp sync failed, continuing" >&2
              fi
            fi
          fi
          exec ${execPrefix} \
            env HOME="$HOME" CLAUDE_CONFIG_DIR="$HOME/.claude-glecom" \
            claude "$@"
        '';
    in
    [
      (wrapper "claude-glecom" "10.200.200.1" "/run/wrappers/bin/nsenter-claude-glecom")
      (wrapper "claude-glecom-local" "127.0.0.1" "")
    ];

  # wg2: move Claude Code CIDRs out of main table into table 200
  # so regular processes use the default route for those destinations
  networking.wireguard.interfaces.wg2.postShutdown = lib.mkAfter ''
    ${ip} route del 160.79.104.0/23 dev wg2 table 200 2>/dev/null || true
    ${ip} -6 route del 2607:6bc0::/48 dev wg2 table 200 2>/dev/null || true
  '';

  # Move Claude Code CIDRs out of main routing table into table 200.
  # The wireguard peer service runs concurrently with this and re-adds all
  # allowedIP routes (including the Claude CIDRs) to main. We poll briefly
  # until the route appears, then move it to table 200.
  # Note: the peer service name contains '=' which NixOS's type checker rejects
  # in systemd.services keys, so we cannot use After/BindsTo on it directly.
  systemd.services.wg2-move-claude-routes = {
    description = "Move Claude Code CIDRs from main routing table to table 200";
    after = [ "wireguard-wg2.service" ];
    wantedBy = [ "wireguard-wg2.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "wg2-move-claude-routes" ''
        # Wait up to 10s for the peer service to add the route to main
        for i in $(seq 10); do
          ${ip} route show table main | ${pkgs.gnugrep}/bin/grep -q 160.79.104.0/23 && break
          sleep 1
        done
        ${ip} route del 160.79.104.0/23 dev wg2 table main 2>/dev/null || true
        ${ip} -6 route del 2607:6bc0::/48 dev wg2 table main 2>/dev/null || true
        ${ip} route replace 160.79.104.0/23 dev wg2 table 200
        ${ip} -6 route replace 2607:6bc0::/48 dev wg2 table 200
      '';
    };
  };

  # Network namespace setup
  systemd.services.netns-claude-glecom = {
    description = "claude-glecom network namespace";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "wireguard-wg2.service" ];
    wants = [ "wireguard-wg2.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${ip} netns add claude-glecom

      # veth pair: veth-cg (host) <-> veth-cg-ns (namespace)
      ${ip} link add veth-cg type veth peer name veth-cg-ns
      ${ip} link set veth-cg-ns netns claude-glecom

      # Host side
      ${ip} addr add 10.200.200.1/30 dev veth-cg
      ${ip} addr add fd00:200::1/64 dev veth-cg
      ${ip} link set veth-cg up
      # Allow DNAT to 127.0.0.1 from veth-cg (must be set after interface exists)
      ${pkgs.procps}/bin/sysctl -w net.ipv4.conf.veth-cg.route_localnet=1

      # Namespace side
      ${ip} -n claude-glecom addr add 10.200.200.2/30 dev veth-cg-ns
      ${ip} -n claude-glecom addr add fd00:200::2/64 dev veth-cg-ns
      ${ip} -n claude-glecom link set veth-cg-ns up
      ${ip} -n claude-glecom link set lo up

      # Routes inside namespace: Claude Code CIDRs and default via host
      ${ip} -n claude-glecom route add 160.79.104.0/23 via 10.200.200.1
      ${ip} -n claude-glecom -6 route add 2607:6bc0::/48 via fd00:200::1
      ${ip} -n claude-glecom route add default via 10.200.200.1
      ${ip} -n claude-glecom -6 route add default via fd00:200::1

      # DNAT inside namespace: redirect localhost ports to host veth IP
      # so host services (muninn:3001, chrome-devtools:9222, venice proxy:8000)
      # are reachable via the bridge
      for port in 3001 9222 8000; do
        ${ip} netns exec claude-glecom \
          ${pkgs.iptables}/bin/iptables -t nat -A OUTPUT \
            -d 127.0.0.1 -p tcp --dport $port \
            -j DNAT --to-destination 10.200.200.1:$port
      done

      # Policy rule: traffic from veth-cg uses table 200 (routes to wg2)
      ${ip} rule add iif veth-cg lookup 200 priority 100
      ${ip} -6 rule add iif veth-cg lookup 200 priority 100

      # DNAT on host: forward traffic arriving on veth IP to the matching localhost port
      for port in 3001 9222 8000; do
        ${pkgs.iptables}/bin/iptables -t nat -A PREROUTING \
          -d 10.200.200.1 -p tcp --dport $port \
          -j DNAT --to-destination 127.0.0.1:$port
      done
    '';
    preStop = ''
      for port in 3001 9222 8000; do
        ${pkgs.iptables}/bin/iptables -t nat -D PREROUTING \
          -d 10.200.200.1 -p tcp --dport $port \
          -j DNAT --to-destination 127.0.0.1:$port 2>/dev/null || true
      done
      ${ip} rule del iif veth-cg lookup 200 priority 100 2>/dev/null || true
      ${ip} -6 rule del iif veth-cg lookup 200 priority 100 2>/dev/null || true
      ${ip} link del veth-cg 2>/dev/null || true
      ${ip} netns del claude-glecom 2>/dev/null || true
    '';
  };

  # IP forwarding for namespace traffic
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Trust veth-cg so firewall accepts DNAT'd traffic from the namespace
  # (ports 3001/muninn, 8000/venice-api, 9222/chrome-devtools)
  networking.firewall.trustedInterfaces = [ "veth-cg" ];

  # NAT: masquerade namespace traffic leaving via wg2
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables  -t nat -A POSTROUTING -s 10.200.200.0/30 -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -s fd00:200::/64   -j MASQUERADE
  '';
  networking.firewall.extraStopCommands = lib.mkAfter ''
    iptables  -t nat -D POSTROUTING -s 10.200.200.0/30 -j MASQUERADE 2>/dev/null || true
    ip6tables -t nat -D POSTROUTING -s fd00:200::/64   -j MASQUERADE 2>/dev/null || true
  '';
}
