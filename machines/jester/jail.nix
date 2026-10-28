# claude-jail: bwrap + landlock (landrun) + seccomp sandbox for commands.
#
# Address filtering uses a network namespace plus iptables, not landlock:
# landlock network rules match only TCP bind/connect ports, never
# destination addresses. So landlock limits which ports a jail may connect
# to, and the host firewall decides which addresses it may reach.
#
# Each run gets its own netns through the setuid helper jail-net (group
# "jail" only):
#  - `jail-net up RUNID POLICY [OPENING]...` takes a free /29 from
#    10.201.0.0/16 (.1 host, .2 jail, .3 proxy source) and a /126 from
#    fd00:201::/48, creates netns jail-RUNID with veth jh-<8hex>/jn-<8hex>,
#    and adds chain JAIL-RUNID (jumped from FORWARD on -i jh-<8hex>), an
#    INPUT DROP on that veth and a MASQUERADE for the run's subnet. State
#    lives in root-only /run/jail-net/RUNID (owner uid, wrapper pid, slot).
#    Every up first tears down runs whose recorded pid is dead.
#  - `jail-net down RUNID` removes all of it; only the owner or root.
#  - `jail-net exec RUNID -- /abs/cmd...` joins the run's netns, drops to
#    the caller's uid/gid with no supplementary groups, and execs.
#  - `jail-net resync` re-inserts every run's jumps; the firewall calls it
#    on each reload. Static `-i jh-+ -j DROP` rules make a missing jump
#    fail closed.
# Openings are addr[/cidr]:port/tcp|udp. The helper refuses any opening
# that overlaps 127/8, ::1, ::ffff:0:0/96, the jail pools or a local host
# address. Scope follows POLICY; the caller cannot widen it.
#
# Policies:
#  - internet: any public address (private, link-local, multicast and
#    reserved ranges dropped), plus private-range openings. Landlock allows
#    TCP 80/443 and opening ports.
#  - allowlist: default-deny. The wrapper starts tinyproxy in the run's
#    netns on 127.0.0.1:8888 (private to the run) with FilterDefaultDeny
#    and a filter built from the run's domain entries; it sends upstream
#    traffic from the .3 proxy address, which alone may reach public
#    addresses on TCP 80/443. The firewall also allows DNS to the jail
#    resolvers and the IP openings (public allowed), and drops the rest.
#    Landrun allows TCP connect only to the proxy port and opening ports.
#    Ceilings: DNS to 1.1.1.1/9.9.9.9 stays open in allowlist mode (an
#    exfiltration channel); the proxy egress is IPv4 only; a jail that can
#    bind() the .3 address reaches public 80/443 directly when landlock
#    allows that port; pid reuse can delay stale cleanup. The per-run
#    subnet is a /29, not a /30, to give the proxy its own source address.
{ config, lib, pkgs, ... }:
let
  # Commands that always run jailed: name = package. Each gets a
  # lib.hiPrio wrapper on PATH that execs `jail` with the package's binary,
  # so the raw binary is never on PATH. Example:
  #   jailedCommands = { claude = pkgs.claude-code; };
  # In the jail $HOME is ~/.jails/kimi, so Kimi's ~/.kimi-code lands at ~/.jails/kimi/.kimi-code.
  jailedCommands = { kimi = pkgs.kimi-code; };
  jailedWrappers = lib.mapAttrsToList (n: p: lib.hiPrio (pkgs.writeShellScriptBin n ''
    exec ${jail}/bin/jail -- ${lib.getExe' p n} "$@"
  '')) jailedCommands;

  ip = "${pkgs.iproute2}/bin/ip";
  iptables = "${pkgs.iptables}/bin/iptables";
  ip6tables = "${pkgs.iptables}/bin/ip6tables";

  resolvConf = pkgs.writeText "resolv.conf.jail" ''
    nameserver 1.1.1.1
    nameserver 9.9.9.9
  '';

  toolset = pkgs.buildEnv {
    name = "jail-toolset";
    paths = with pkgs; [ bash coreutils findutils gnugrep gnused diffutils jq git ];
  };

  extraTools = { inherit (pkgs) ripgrep fd; };
  extraToolsJson = pkgs.writeText "jail-extra-tools.json"
    (builtins.toJSON (lib.mapAttrs (_: p: "${p}") extraTools));

  cacert = "${pkgs.cacert}";
  cacertFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # Seccomp BPF filter, generated at Nix build time with libseccomp: default
  # allow, errors for the listed syscalls. Every libseccomp return value is
  # checked, so a rule the library rejects fails the build. Non-native
  # syscall ABIs (e.g. i386 int 0x80) hit libseccomp's bad-arch KILL action.
  seccompFilter = pkgs.runCommandCC "claude-jail-seccomp-filter" {
    buildInputs = [ pkgs.libseccomp ];
  } ''
    mkdir -p $out
    cat > filter.c << 'EOF'
    #include <errno.h>
    #include <seccomp.h>
    #include <stdio.h>
    #include <string.h>
    #include <sys/ioctl.h>
    #include <sys/socket.h>
    #include <unistd.h>

    #define RULE(act, sys, ...) do { \
      int rc = seccomp_rule_add(ctx, act, SCMP_SYS(sys), __VA_ARGS__); \
      if (rc < 0) { fprintf(stderr, "seccomp_rule_add(%s): %s\n", #sys, strerror(-rc)); return 1; } \
    } while (0)
    #define DENY(sys) RULE(SCMP_ACT_ERRNO(EPERM), sys, 0)

    int main(void) {
      scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
      if (!ctx) { fprintf(stderr, "seccomp_init failed\n"); return 1; }

      DENY(ptrace);
      DENY(process_vm_readv);
      DENY(process_vm_writev);
      DENY(bpf);
      DENY(keyctl);
      DENY(add_key);
      DENY(request_key);
      DENY(mount);
      DENY(umount2);
      DENY(pivot_root);
      DENY(move_mount);
      DENY(open_tree);
      DENY(fsopen);
      DENY(fsmount);
      DENY(io_uring_setup);
      DENY(io_uring_enter);
      DENY(io_uring_register);
      DENY(perf_event_open);
      DENY(kexec_load);
      DENY(kexec_file_load);
      DENY(init_module);
      DENY(finit_module);
      DENY(delete_module);
      DENY(userfaultfd);
      DENY(unshare);
      DENY(setns);

      /* clone3 flags live in a struct seccomp cannot inspect; ENOSYS makes
         libc fall back to clone(), and bwrap's --disable-userns covers it. */
      RULE(SCMP_ACT_ERRNO(ENOSYS), clone3, 0);

      /* personality: only the query (0xffffffff) and PER_LINUX (0). The
         kernel reads a 32-bit int, so compare the low 32 bits. libseccomp
         allows one comparison per argument, so cover "not all zeros, not
         all ones" as "some bit i set while bit i+1 (mod 32) is clear":
         32 masked rules. */
      for (unsigned i = 0; i < 32; i++) {
        uint32_t bi = 1u << i, bj = 1u << ((i + 1) % 32);
        RULE(SCMP_ACT_ERRNO(EPERM), personality, 1,
             SCMP_A0_32(SCMP_CMP_MASKED_EQ, bi | bj, bi));
      }

      /* Terminal input injection. */
      RULE(SCMP_ACT_ERRNO(EPERM), ioctl, 1, SCMP_A1_32(SCMP_CMP_EQ, TIOCSTI));
      RULE(SCMP_ACT_ERRNO(EPERM), ioctl, 1, SCMP_A1_32(SCMP_CMP_EQ, TIOCLINUX));

      /* socket(): AF_UNIX, AF_INET, AF_INET6 and AF_NETLINK only. */
      for (unsigned af = 0; af < AF_MAX; af++)
        if (af != AF_UNIX && af != AF_INET && af != AF_INET6 && af != AF_NETLINK)
          RULE(SCMP_ACT_ERRNO(EAFNOSUPPORT), socket, 1, SCMP_A0_32(SCMP_CMP_EQ, af));
      RULE(SCMP_ACT_ERRNO(EAFNOSUPPORT), socket, 1, SCMP_A0_32(SCMP_CMP_GE, AF_MAX));

      int rc = seccomp_export_bpf(ctx, STDOUT_FILENO);
      if (rc < 0) { fprintf(stderr, "seccomp_export_bpf: %s\n", strerror(-rc)); return 1; }
      seccomp_release(ctx);
      return 0;
    }
    EOF

    cc -Wall -Wextra -Werror -o filter-gen filter.c -lseccomp
    ./filter-gen > $out/seccomp.bpf
    test -s $out/seccomp.bpf
  '';
  seccompBpf = "${seccompFilter}/seccomp.bpf";
  landrun = pkgs.landrun;

  # Setuid helper for per-run network namespaces (see the top comment).
  # Validates every argument in C; runs ip/iptables via fork + execv with an
  # explicit argv and a cleared environment (no system(), no shell).
  jailNetSrc = pkgs.writeText "jail-net.c" ''
    #define _GNU_SOURCE
    #include <arpa/inet.h>
    #include <dirent.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <grp.h>
    #include <ifaddrs.h>
    #include <netinet/in.h>
    #include <sched.h>
    #include <signal.h>
    #include <stdarg.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/file.h>
    #include <sys/stat.h>
    #include <sys/types.h>
    #include <sys/wait.h>
    #include <unistd.h>

    #define IP "${ip}"
    #define IPT4 "${iptables}"
    #define IPT6 "${ip6tables}"
    #define STATE "/run/jail-net"
    #define SLOTS 8192 /* /29 slots in 10.201.0.0/16 */
    #define MAXOPEN 64
    #define MAXARGS 32

    struct run {
      char id[17];
      uid_t uid;
      pid_t pid;
      unsigned slot;
      int allow;
      char ns[32], jh[16], jn[16], chain[32];
      char h4[20], j4[20], p4[20], sub4[24], h4c[24], j4c[24], p4c[24];
      char h6[48], j6[48], sub6[56], h6c[56], j6c[56];
    };
    struct net { int fam; unsigned char a[16]; int plen; };
    struct opening { struct net n; char net[64]; char port[6]; char proto[4]; };

    static uid_t ruid;
    static gid_t rgid;
    static struct run runs[SLOTS];

    static const char *const forbid[] = {
      "127.0.0.0/8", "10.201.0.0/16", "::1/128", "::ffff:0:0/96", "fd00:201::/48", NULL };
    static const char *const private_[] = {
      "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
      "169.254.0.0/16", "fc00::/7", "fe80::/10", NULL };
    static const char *const drop4[] = {
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
      "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16",
      "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4",
      "240.0.0.0/4", NULL };
    static const char *const drop6[] = {
      "::/128", "::1/128", "::ffff:0:0/96", "64:ff9b::/96", "64:ff9b:1::/48",
      "100::/64", "2001::/32", "2001:db8::/32", "2002::/16", "fc00::/7",
      "fe80::/10", "fec0::/10", "ff00::/8", NULL };
    static const char *const dns4[] = { "1.1.1.1", "9.9.9.9", NULL };
    /* ICMPv6 types the jail veth needs to reach its gateway; INPUT drops the rest. */
    static const char *const nd6[] = { "neighbour-solicitation", "neighbour-advertisement", NULL };

    __attribute__((noreturn, format(printf, 1, 2)))
    static void die(const char *fmt, ...) {
      va_list ap;
      va_start(ap, fmt);
      fputs("jail-net: ", stderr);
      vfprintf(stderr, fmt, ap);
      fputc('\n', stderr);
      va_end(ap);
      exit(1);
    }

    __attribute__((noreturn))
    static void usage(void) {
      fputs("usage: jail-net up RUNID internet|allowlist [ADDR[/CIDR]:PORT/tcp|udp]...\n"
            "       jail-net down RUNID\n"
            "       jail-net exec RUNID -- /abs/cmd [ARGS]...\n"
            "       jail-net resync\n", stderr);
      exit(2);
    }

    static int valid_runid(const char *s) {
      if (strlen(s) != 16) return 0;
      for (; *s; s++)
        if (!((*s >= '0' && *s <= '9') || (*s >= 'a' && *s <= 'f'))) return 0;
      return 1;
    }

    /* fork + execv of an absolute path; argv is NULL-terminated varargs. */
    static int run(int quiet, const char *path, ...) {
      const char *argv[MAXARGS];
      int n = 0;
      va_list ap;
      va_start(ap, path);
      argv[n++] = path;
      for (const char *a; (a = va_arg(ap, const char *)) != NULL;) {
        if (n >= MAXARGS - 1) die("too many arguments");
        argv[n++] = a;
      }
      va_end(ap);
      argv[n] = NULL;
      pid_t pid = fork();
      if (pid < 0) die("fork: %s", strerror(errno));
      if (pid == 0) {
        if (quiet) {
          int fd = open("/dev/null", O_WRONLY);
          if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); }
        }
        execv(path, (char *const *)argv);
        _exit(127);
      }
      int st;
      while (waitpid(pid, &st, 0) < 0)
        if (errno != EINTR) return -1;
      return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    }
    #define Q(...) run(1, __VA_ARGS__, (char *)NULL)
    #define T(...) do { if (run(0, __VA_ARGS__, (char *)NULL) != 0) return -1; } while (0)

    static void v4(char *dst, size_t n, unsigned slot, unsigned off, const char *sfx) {
      struct in_addr a;
      char b[INET_ADDRSTRLEN];
      a.s_addr = htonl(0x0AC90000u + slot * 8 + off);
      inet_ntop(AF_INET, &a, b, sizeof b);
      snprintf(dst, n, "%s%s", b, sfx);
    }

    static void v6(char *dst, size_t n, unsigned slot, unsigned off, const char *sfx) {
      struct in6_addr a;
      char b[INET6_ADDRSTRLEN];
      unsigned v = slot * 4 + off;
      memset(&a, 0, sizeof a);
      a.s6_addr[0] = 0xfd; a.s6_addr[2] = 0x02; a.s6_addr[3] = 0x01;
      a.s6_addr[14] = (unsigned char)(v >> 8);
      a.s6_addr[15] = (unsigned char)v;
      inet_ntop(AF_INET6, &a, b, sizeof b);
      snprintf(dst, n, "%s%s", b, sfx);
    }

    static void fill(struct run *r) {
      snprintf(r->ns, sizeof r->ns, "jail-%s", r->id);
      snprintf(r->jh, sizeof r->jh, "jh-%.8s", r->id);
      snprintf(r->jn, sizeof r->jn, "jn-%.8s", r->id);
      snprintf(r->chain, sizeof r->chain, "JAIL-%s", r->id);
      v4(r->h4, sizeof r->h4, r->slot, 1, "");
      v4(r->j4, sizeof r->j4, r->slot, 2, "");
      v4(r->p4, sizeof r->p4, r->slot, 3, "");
      v4(r->sub4, sizeof r->sub4, r->slot, 0, "/29");
      v4(r->h4c, sizeof r->h4c, r->slot, 1, "/29");
      v4(r->j4c, sizeof r->j4c, r->slot, 2, "/29");
      v4(r->p4c, sizeof r->p4c, r->slot, 3, "/29");
      v6(r->h6, sizeof r->h6, r->slot, 1, "");
      v6(r->j6, sizeof r->j6, r->slot, 2, "");
      v6(r->sub6, sizeof r->sub6, r->slot, 0, "/126");
      v6(r->h6c, sizeof r->h6c, r->slot, 1, "/126");
      v6(r->j6c, sizeof r->j6c, r->slot, 2, "/126");
    }

    static int load(const char *id, struct run *r) {
      char p[64], pol[16];
      unsigned u, slot;
      int pid;
      memset(r, 0, sizeof *r);
      snprintf(p, sizeof p, STATE "/%s/state", id);
      FILE *f = fopen(p, "re");
      if (!f) return 0;
      int n = fscanf(f, "%u %d %u %15s", &u, &pid, &slot, pol);
      fclose(f);
      if (n != 4 || slot >= SLOTS) return 0;
      snprintf(r->id, sizeof r->id, "%s", id);
      r->uid = u; r->pid = pid; r->slot = slot;
      r->allow = strcmp(pol, "allowlist") == 0;
      fill(r);
      return 1;
    }

    static int list_runs(void) {
      int n = 0;
      DIR *d = opendir(STATE);
      if (!d) return 0;
      for (struct dirent *e; n < SLOTS && (e = readdir(d)) != NULL;)
        if (valid_runid(e->d_name) && load(e->d_name, &runs[n])) n++;
      closedir(d);
      return n;
    }

    /* Root-only state dir; the lock fd stays open (and locked) until exit. */
    static void lock_state(void) {
      struct stat st;
      if (mkdir(STATE, 0700) != 0 && errno != EEXIST) die("mkdir %s: %s", STATE, strerror(errno));
      if (lstat(STATE, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 || (st.st_mode & 077))
        die("%s: bad type, owner or mode", STATE);
      int fd = open(STATE "/lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
      if (fd < 0 || flock(fd, LOCK_EX) != 0) die("lock: %s", strerror(errno));
    }

    static int pfx_eq(const unsigned char *a, const unsigned char *b, int bits) {
      int i = 0;
      for (; bits >= 8; bits -= 8, i++)
        if (a[i] != b[i]) return 0;
      if (bits == 0) return 1;
      unsigned char m = (unsigned char)(0xff << (8 - bits));
      return (a[i] & m) == (b[i] & m);
    }
    static int overlaps(const struct net *x, const struct net *y) {
      return x->fam == y->fam && pfx_eq(x->a, y->a, x->plen < y->plen ? x->plen : y->plen);
    }
    static int inside(const struct net *x, const struct net *y) {
      return x->fam == y->fam && x->plen >= y->plen && pfx_eq(x->a, y->a, y->plen);
    }

    /* ADDR[/LEN] with host bits zero. */
    static int parse_net(const char *s, struct net *n) {
      char b[64];
      const char *sl = strchr(s, '/');
      size_t len = sl ? (size_t)(sl - s) : strlen(s);
      if (len == 0 || len >= sizeof b) return 0;
      memcpy(b, s, len);
      b[len] = 0;
      memset(n, 0, sizeof *n);
      if (inet_pton(AF_INET, b, n->a) == 1) { n->fam = AF_INET; n->plen = 32; }
      else if (inet_pton(AF_INET6, b, n->a) == 1) { n->fam = AF_INET6; n->plen = 128; }
      else return 0;
      if (sl) {
        const char *p = sl + 1;
        int v = 0;
        if (!*p || strlen(p) > 3) return 0;
        for (; *p; p++) {
          if (*p < '0' || *p > '9') return 0;
          v = v * 10 + (*p - '0');
        }
        if (v > n->plen) return 0;
        n->plen = v;
      }
      int bits = n->fam == AF_INET ? 32 : 128;
      for (int i = n->plen; i < bits; i++)
        if (n->a[i / 8] & (0x80 >> (i % 8))) return 0;
      return 1;
    }

    /* ADDR[/CIDR]:PORT/tcp|udp */
    static int parse_opening(const char *s, struct opening *o) {
      char b[96], a[INET6_ADDRSTRLEN];
      long port = 0;
      if (strlen(s) >= sizeof b) return 0;
      strcpy(b, s);
      char *pr = strrchr(b, '/');
      if (!pr) return 0;
      *pr++ = 0;
      if (strcmp(pr, "tcp") != 0 && strcmp(pr, "udp") != 0) return 0;
      char *po = strrchr(b, ':');
      if (!po) return 0;
      *po++ = 0;
      if (!*po || strlen(po) > 5) return 0;
      for (char *p = po; *p; p++) {
        if (*p < '0' || *p > '9') return 0;
        port = port * 10 + (*p - '0');
      }
      if (port < 1 || port > 65535) return 0;
      if (!parse_net(b, &o->n)) return 0;
      inet_ntop(o->n.fam, o->n.a, a, sizeof a);
      snprintf(o->net, sizeof o->net, "%s/%d", a, o->n.plen);
      snprintf(o->port, sizeof o->port, "%ld", port);
      memcpy(o->proto, pr, 4);
      return 1;
    }

    static int in_list(const struct net *x, const char *const *l,
                       int (*f)(const struct net *, const struct net *)) {
      struct net y;
      for (; *l; l++)
        if (parse_net(*l, &y) && f(x, &y)) return 1;
      return 0;
    }

    /* Every local address of the host, including other runs' veths. */
    static int host_overlap(const struct net *x, const struct ifaddrs *ifa) {
      for (; ifa; ifa = ifa->ifa_next) {
        struct net y;
        if (!ifa->ifa_addr) continue;
        memset(&y, 0, sizeof y);
        if (ifa->ifa_addr->sa_family == AF_INET) {
          y.fam = AF_INET; y.plen = 32;
          memcpy(y.a, &((const struct sockaddr_in *)(const void *)ifa->ifa_addr)->sin_addr, 4);
        } else if (ifa->ifa_addr->sa_family == AF_INET6) {
          y.fam = AF_INET6; y.plen = 128;
          memcpy(y.a, &((const struct sockaddr_in6 *)(const void *)ifa->ifa_addr)->sin6_addr, 16);
        } else continue;
        if (overlaps(x, &y)) return 1;
      }
      return 0;
    }

    static void teardown(const struct run *r) {
      char p[64];
      for (int v6 = 0; v6 < 2; v6++) {
        const char *b = v6 ? IPT6 : IPT4, *sub = v6 ? r->sub6 : r->sub4;
        while (Q(b, "-D", "FORWARD", "-i", r->jh, "-j", r->chain) == 0) {}
        while (Q(b, "-D", "INPUT", "-i", r->jh, "-j", "DROP") == 0) {}
        if (v6)
          for (const char *const *t = nd6; *t; t++)
            while (Q(b, "-D", "INPUT", "-i", r->jh, "-p", "ipv6-icmp", "--icmpv6-type", *t,
                     "-j", "ACCEPT") == 0) {}
        while (Q(b, "-t", "nat", "-D", "POSTROUTING", "-s", sub, "-j", "MASQUERADE") == 0) {}
        Q(b, "-F", r->chain);
        Q(b, "-X", r->chain);
      }
      Q(IP, "link", "del", r->jh);
      Q(IP, "netns", "del", r->ns);
      snprintf(p, sizeof p, STATE "/%s/state", r->id);
      unlink(p);
      snprintf(p, sizeof p, STATE "/%s", r->id);
      rmdir(p);
    }

    /* Idempotent: removes then re-inserts the jumps at the top. */
    static int jumps(const struct run *r) {
      int rc = 0;
      for (int v6 = 0; v6 < 2; v6++) {
        const char *b = v6 ? IPT6 : IPT4, *sub = v6 ? r->sub6 : r->sub4;
        while (Q(b, "-D", "FORWARD", "-i", r->jh, "-j", r->chain) == 0) {}
        while (Q(b, "-D", "INPUT", "-i", r->jh, "-j", "DROP") == 0) {}
        if (v6)
          for (const char *const *t = nd6; *t; t++)
            while (Q(b, "-D", "INPUT", "-i", r->jh, "-p", "ipv6-icmp", "--icmpv6-type", *t,
                     "-j", "ACCEPT") == 0) {}
        rc |= run(0, b, "-I", "FORWARD", "1", "-i", r->jh, "-j", r->chain, (char *)NULL);
        rc |= run(0, b, "-I", "INPUT", "1", "-i", r->jh, "-j", "DROP", (char *)NULL);
        /* Inserted last at position 1, so the ACCEPTs sit above the DROP. */
        if (v6)
          for (const char *const *t = nd6; *t; t++)
            rc |= run(0, b, "-I", "INPUT", "1", "-i", r->jh, "-p", "ipv6-icmp",
                      "--icmpv6-type", *t, "-j", "ACCEPT", (char *)NULL);
        if (Q(b, "-t", "nat", "-C", "POSTROUTING", "-s", sub, "-j", "MASQUERADE") != 0)
          rc |= run(0, b, "-t", "nat", "-A", "POSTROUTING", "-s", sub, "-j", "MASQUERADE", (char *)NULL);
      }
      return rc;
    }

    static int chain(const struct run *r, int v6, const struct opening *o, int n) {
      const char *b = v6 ? IPT6 : IPT4, *c = r->chain;
      const char *const *drop = v6 ? drop6 : drop4;
      T(b, "-N", c);
      for (int i = 0; i < n; i++)
        if (o[i].n.fam == (v6 ? AF_INET6 : AF_INET))
          T(b, "-A", c, "-s", v6 ? r->j6 : r->j4, "-d", o[i].net, "-p", o[i].proto,
            "--dport", o[i].port, "-j", "ACCEPT");
      if (!r->allow) {
        for (const char *const *d = drop; *d; d++) T(b, "-A", c, "-d", *d, "-j", "DROP");
        T(b, "-A", c, "-j", "ACCEPT");
        return 0;
      }
      if (!v6) {
        for (const char *const *d = dns4; *d; d++) {
          T(b, "-A", c, "-d", *d, "-p", "udp", "--dport", "53", "-j", "ACCEPT");
          T(b, "-A", c, "-d", *d, "-p", "tcp", "--dport", "53", "-j", "ACCEPT");
        }
        for (const char *const *d = drop; *d; d++)
          T(b, "-A", c, "-s", r->p4, "-d", *d, "-j", "DROP");
        T(b, "-A", c, "-s", r->p4, "-p", "tcp", "-m", "multiport", "--dports", "80,443",
          "-j", "ACCEPT");
      }
      T(b, "-A", c, "-j", "DROP");
      return 0;
    }

    static int build(const struct run *r, const struct opening *o, int n) {
      T(IP, "netns", "add", r->ns);
      T(IP, "link", "add", r->jh, "type", "veth", "peer", "name", r->jn, "netns", r->ns);
      T(IP, "addr", "add", r->h4c, "dev", r->jh);
      T(IP, "-6", "addr", "add", r->h6c, "dev", r->jh, "nodad");
      T(IP, "link", "set", r->jh, "up");
      T(IP, "-n", r->ns, "addr", "add", r->j4c, "dev", r->jn);
      T(IP, "-n", r->ns, "addr", "add", r->p4c, "dev", r->jn);
      T(IP, "-n", r->ns, "-6", "addr", "add", r->j6c, "dev", r->jn, "nodad");
      T(IP, "-n", r->ns, "link", "set", r->jn, "up");
      T(IP, "-n", r->ns, "link", "set", "lo", "up");
      T(IP, "-n", r->ns, "route", "add", "default", "via", r->h4);
      T(IP, "-n", r->ns, "-6", "route", "add", "default", "via", r->h6);
      for (int v6 = 0; v6 < 2; v6++)
        if (chain(r, v6, o, n) != 0) return -1;
      return jumps(r) ? -1 : 0;
    }

    static void cleanup_stale(void) {
      int n = list_runs();
      for (int i = 0; i < n; i++)
        if (runs[i].pid <= 0 || (kill(runs[i].pid, 0) != 0 && errno == ESRCH))
          teardown(&runs[i]);
    }

    static int cmd_up(const char *id, const char *pol, int n, char **args) {
      static struct opening o[MAXOPEN];
      static unsigned char used[SLOTS];
      struct ifaddrs *ifa;
      struct run r;
      char p[64];
      int allow;
      if (strcmp(pol, "internet") == 0) allow = 0;
      else if (strcmp(pol, "allowlist") == 0) allow = 1;
      else die("POLICY must be internet or allowlist");
      if (n > MAXOPEN) die("at most %d openings", MAXOPEN);
      if (getifaddrs(&ifa) != 0) die("getifaddrs: %s", strerror(errno));
      for (int i = 0; i < n; i++) {
        if (!parse_opening(args[i], &o[i]))
          die("bad opening %s (want ADDR[/CIDR]:PORT/tcp|udp, host bits zero)", args[i]);
        if (in_list(&o[i].n, forbid, overlaps) || host_overlap(&o[i].n, ifa))
          die("opening %s overlaps loopback, a jail pool or a host address", args[i]);
        if (!allow && !in_list(&o[i].n, private_, inside))
          die("opening %s: internet policy allows only private ranges", args[i]);
      }
      freeifaddrs(ifa);

      lock_state();
      cleanup_stale();
      int m = list_runs();
      for (int i = 0; i < m; i++) {
        if (strncmp(runs[i].id, id, 8) == 0) die("run id prefix %.8s in use", id);
        used[runs[i].slot] = 1;
      }
      unsigned slot = 0;
      while (slot < SLOTS && used[slot]) slot++;
      if (slot == SLOTS) die("no free address slot");

      memset(&r, 0, sizeof r);
      snprintf(r.id, sizeof r.id, "%s", id);
      r.uid = ruid; r.pid = getppid(); r.slot = slot; r.allow = allow;
      fill(&r);
      snprintf(p, sizeof p, STATE "/%s", id);
      if (mkdir(p, 0700) != 0) die("mkdir %s: %s", p, strerror(errno));
      snprintf(p, sizeof p, STATE "/%s/state", id);
      FILE *f = fopen(p, "wxe");
      if (!f || fprintf(f, "%u %d %u %s\n", (unsigned)r.uid, (int)r.pid, r.slot, pol) < 0
          || fclose(f) != 0) {
        teardown(&r);
        die("write %s failed", p);
      }
      if (build(&r, o, n) != 0) {
        teardown(&r);
        die("setup of run %s failed", id);
      }
      printf("%s\n", r.p4); /* proxy source address for tinyproxy Bind */
      return 0;
    }

    static int cmd_down(const char *id) {
      struct run r;
      lock_state();
      if (!load(id, &r)) die("no run %s", id);
      if (ruid != 0 && ruid != r.uid) die("run %s belongs to another user", id);
      teardown(&r);
      return 0;
    }

    static int cmd_resync(void) {
      int rc = 0;
      lock_state();
      int n = list_runs();
      for (int i = 0; i < n; i++)
        if (jumps(&runs[i]) != 0) {
          fprintf(stderr, "jail-net: resync of run %s failed\n", runs[i].id);
          rc = 1;
        }
      return rc;
    }

    static int cmd_exec(const char *id, char **argv) {
      struct run r;
      uid_t u[3];
      gid_t g[3];
      char p[64];
      if (!load(id, &r)) die("no run %s", id);
      if (r.uid != ruid) die("run %s belongs to another user", id);
      if (argv[0] == NULL || argv[0][0] != '/') die("exec needs an absolute command path");
      snprintf(p, sizeof p, "/run/netns/%s", r.ns);
      int fd = open(p, O_RDONLY | O_CLOEXEC);
      if (fd < 0 || setns(fd, CLONE_NEWNET) != 0) die("enter %s: %s", p, strerror(errno));
      close(fd);
      if (setgroups(0, NULL) != 0 || setresgid(rgid, rgid, rgid) != 0
          || setresuid(ruid, ruid, ruid) != 0)
        die("drop privileges: %s", strerror(errno));
      if (getresuid(&u[0], &u[1], &u[2]) != 0 || getresgid(&g[0], &g[1], &g[2]) != 0
          || u[0] != ruid || u[1] != ruid || u[2] != ruid
          || g[0] != rgid || g[1] != rgid || g[2] != rgid || getgroups(0, NULL) != 0)
        die("privileges did not drop");
      if (ruid != 0 && (setuid(0) == 0 || seteuid(0) == 0)) die("privileges did not drop");
      execv(argv[0], argv);
      die("exec %s: %s", argv[0], strerror(errno));
    }

    int main(int argc, char **argv) {
      ruid = getuid();
      rgid = getgid();
      if (argc < 2) usage();
      if (setresgid(0, 0, 0) != 0 || setresuid(0, 0, 0) != 0) die("must run setuid root");
      umask(022);
      if (strcmp(argv[1], "exec") == 0) {
        if (argc < 5 || !valid_runid(argv[2]) || strcmp(argv[3], "--") != 0) usage();
        return cmd_exec(argv[2], argv + 4);
      }
      if (clearenv() != 0) die("clearenv failed");
      /* Manage from the host netns even if the caller sits in a jail netns. */
      int fd = open("/proc/1/ns/net", O_RDONLY | O_CLOEXEC);
      if (fd < 0 || setns(fd, CLONE_NEWNET) != 0) die("join host netns: %s", strerror(errno));
      close(fd);
      if (strcmp(argv[1], "up") == 0 && argc >= 4 && valid_runid(argv[2]))
        return cmd_up(argv[2], argv[3], argc - 4, argv + 4);
      if (strcmp(argv[1], "down") == 0 && argc == 3 && valid_runid(argv[2]))
        return cmd_down(argv[2]);
      if (strcmp(argv[1], "resync") == 0 && argc == 2)
        return cmd_resync();
      usage();
    }
  '';
  jail-net = pkgs.runCommandCC "jail-net" { } ''
    mkdir -p $out/bin
    cc -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 -o $out/bin/jail-net ${jailNetSrc}
  '';

  # jq check for .jail.json: exactly policy, allow and mounts, typed.
  jailJsonCheck = pkgs.writeText "jail-json-check.jq" ''
    type == "object"
    and (keys - ["allow", "mounts", "policy"]) == []
    and has("policy") and has("allow") and has("mounts")
    and (.policy | IN("internet", "allowlist"))
    and (.allow | type == "array" and all(.[]; type == "string"))
    and (.mounts | type == "object" and all(to_entries[];
      (.key | test("^[A-Za-z0-9._-]+$"))
      and (.value | type == "array" and all(.[]; type == "string"))))
  '';

  # --disable-userns (bwrap 0.8.0) is mandatory: no fallback without it.
  jail = assert lib.assertMsg (lib.versionAtLeast pkgs.bubblewrap.version "0.8.0")
    "jail needs bubblewrap >= 0.8.0 for --disable-userns";
    pkgs.writeShellApplication {
    name = "jail";
    # SC2016: jq programs carry jq's own $vars in single quotes on purpose.
    excludeShellChecks = [ "SC2016" ];
    runtimeInputs = [
      pkgs.bubblewrap
      pkgs.coreutils
      pkgs.jq
      pkgs.git
      pkgs.gnugrep
      pkgs.util-linux
      pkgs.nix
      landrun
    ];
    text = ''
      usage() { echo "usage: jail [--home NAME] [--policy internet|allowlist] [--allow ENTRY]... [--] COMMAND [ARGS]" >&2; exit 2; }
      die() { echo "jail: $*" >&2; exit 1; }
      # jqlist VAR JQ-ARGS...: the lines of `jq -r JQ-ARGS...` into array VAR.
      # A jq failure aborts the run instead of yielding a short list.
      jqlist() {
        local -n _jl=$1
        shift
        local out
        out=$(jq -r "$@") || die "jq failed: $*"
        _jl=()
        if [[ -n "$out" ]]; then mapfile -t _jl <<<"$out"; fi
      }

      # --- jail allow: review and approve a .jail.json file ---
      if [[ "''${1:-}" == "allow" ]]; then
        shift
        target="''${1:-$PWD/.jail.json}"
        target=$(readlink -f "$target") || die "cannot resolve $target"
        [[ -f "$target" ]] || die "file not found: $target"

        # Show and hash the same bytes: one private copy.
        copy=$(umask 077; mktemp)
        trap 'rm -f "$copy"' EXIT
        cat -- "$target" >"$copy"
        jq -e -f "${jailJsonCheck}" "$copy" >/dev/null 2>&1 || die "$target fails schema validation"

        allowed_file="$HOME/.config/jail/allowed"
        sha=$(sha256sum "$copy"); sha=''${sha%% *}
        mkdir -p "$(dirname "$allowed_file")"
        touch "$allowed_file"
        if grep -q "^$sha " "$allowed_file"; then
          echo "jail: $target already approved"
          exit 0
        fi

        # Print every effect.
        echo "Policy: $(jq -r '.policy' "$copy")"
        echo "Allow entries:"
        entries=() # assigned by jqlist via nameref
        jqlist entries '.allow[]' "$copy"
        for e in "''${entries[@]}"; do echo "  $e"; done
        echo "Mounts:"
        jq -r '.mounts | to_entries[] | "  \(.key): \(.value | join(", "))"' "$copy"

        # Flag profiles containing credential paths.
        cred_patterns='\.claude|\.ssh|\.gnupg|\bgh\b|credentials'
        profs=() # assigned by jqlist via nameref
        jqlist profs '.mounts | to_entries[] | .key as $cmd | .value[] | "\($cmd):\(.)"' "$copy"
        for e in "''${profs[@]}"; do
          if grep -qiE "$cred_patterns" <<<"''${e#*:}"; then echo "  CREDENTIAL: ''${e%%:*} mounts ''${e#*:}"; fi
        done

        printf "Approve? [y/N] "
        read -r reply
        [[ "$reply" == [yY] ]] || die "not approved"
        echo "$sha $target" >> "$allowed_file"
        echo "jail: approved $target"
        exit 0
      fi

      name="" policy=internet allows=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --home) [[ $# -ge 2 ]] || usage; name="$2"; shift 2 ;;
          --policy) [[ $# -ge 2 ]] || usage; policy="$2"; shift 2 ;;
          --allow) [[ $# -ge 2 ]] || usage; allows+=("$2"); shift 2 ;;
          --) shift; break ;;
          -*) usage ;;
          *) break ;;
        esac
      done
      [[ $# -ge 1 ]] || usage
      case "$policy" in internet|allowlist) ;; *) echo "jail: --policy must be internet or allowlist" >&2; exit 2 ;; esac
      cmd="$1"; shift

      cmdpath=$(command -v "$cmd") || die "command not found: $cmd"
      cmdpath=$(readlink -f "$cmdpath")
      [[ "$cmdpath" == /nix/store/* ]] || die "refusing non-store command: $cmdpath"
      cmdname=$(basename "$cmd")
      name="''${name:-$cmdname}"
      [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != . && "$name" != .. ]] || { echo "jail: bad home name: $name" >&2; exit 2; }

      # Refuse broad working directories: $PWD is bound read-write into the jail.
      pwd_real=$(realpath -- "$PWD")
      for bad in / "$HOME" /home "$(realpath -- "$HOME")" "$(realpath -- /home)"; do
        [[ "$pwd_real" != "$bad" ]] || die "refusing to run in $pwd_real: cd into a project directory first"
      done

      # Per-run state: a private temp dir and the run's netns, both removed
      # by the EXIT trap. `down` before `up` is a harmless no-op.
      jnet=/run/wrappers/bin/jail-net
      runid=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
      pdir=$(mktemp -d)
      proxy_pid=""
      # shellcheck disable=SC2329 # invoked via trap EXIT
      cleanup() {
        if [[ -n "$proxy_pid" ]]; then kill "$proxy_pid" 2>/dev/null || true; fi
        "$jnet" down "$runid" 2>/dev/null || true
        rm -rf "$pdir"
      }
      trap cleanup EXIT
      trap 'exit 130' INT TERM HUP

      config="$HOME/.config/jail/config.json"
      [[ -f "$config" ]] || config=/dev/null

      # Extra tools from config; unknown names are an error.
      tools=() # assigned by jqlist via nameref
      jqlist tools --arg c "$cmdname" '.commands[$c].tools // [] | .[]' "$config"
      toolpaths=() path="${toolset}/bin"
      for t in "''${tools[@]}"; do
        p=$(jq -r --arg t "$t" '.[$t] // empty' "${extraToolsJson}")
        [[ -n "$p" ]] || die "unknown tool: $t"
        toolpaths+=("$p"); path="$path:$p/bin"
      done

      # Host variables passed in: LANG, LC_ALL and commands.<cmd>.env names.
      envnames=() # assigned by jqlist via nameref
      jqlist envnames --arg c "$cmdname" '.commands[$c].env // [] | .[]' "$config"
      envargs=()
      # landrun clears the environment: each variable bwrap sets is passed on by name.
      landenv=(--env HOME --env USER --env PATH --env TERM --env SSL_CERT_FILE --env JAIL_POLICY --env JAIL_ALLOW)
      for n in LANG LC_ALL "''${envnames[@]}"; do
        [[ "$n" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad env name in $config: $n"
        if [[ -n "''${!n+x}" ]]; then envargs+=(--setenv "$n" "''${!n}"); landenv+=(--env "$n"); fi
      done

      # Fresh root: only the store closure of the command, toolset, cacert and resolvConf.
      args=()
      closure_inputs=("$cmdpath" "${landrun}" "${toolset}" "${cacert}" "${resolvConf}" "''${toolpaths[@]}")
      while IFS= read -r p; do args+=(--ro-bind "$p" "$p"); done < <(
        nix-store -qR "''${closure_inputs[@]}")

      jhome="$HOME/.jails/$name"
      mkdir -p "$jhome"
      # Build the sanitized gitconfig in the host-private per-run dir ($pdir),
      # never inside $jhome: $jhome is the jail's writable HOME, so a planted
      # symlink there could redirect the host-side write to an arbitrary host
      # file (e.g. ~/.ssh keys). The ro-bind below mounts $pdir/gitconfig into
      # the jail as $HOME/.gitconfig, so the jail sees a read-only copy.
      gitconfig="$pdir/gitconfig"
      git config --global --list 2>/dev/null \
        | { grep -E '^((user|init|pull|merge|diff|rebase|alias|color)\.|core\.(autocrlf|eol|quotepath|ignorecase|filemode|safecrlf|whitespace)=|push\.default=)' || [[ $? -eq 1 ]]; } \
        | while IFS='=' read -r k v; do git config -f "$gitconfig" "$k" "$v"; done
      # `git config -f` creates the file on first write; ensure it exists even
      # if the global list was empty, so the ro-bind always has a target.
      [[ -f "$gitconfig" ]] || : >"$gitconfig"

      # .jail.json: read once into a private copy; the check, the hash, the
      # parse and the bind into the jail all use that copy, never the
      # original. Absent, /dev/null takes its place so the jail cannot
      # create one.
      jail_copy=/dev/null
      jail_profiles=()
      # -s: the empty mount point bwrap leaves behind for the /dev/null bind counts as absent.
      if [[ -s "$PWD/.jail.json" ]]; then
        jail_copy=$(umask 077; mktemp "$pdir/jail.json.XXXXXX")
        cat -- "$PWD/.jail.json" >"$jail_copy"
        jq -e -f "${jailJsonCheck}" "$jail_copy" >/dev/null 2>&1 || die "$PWD/.jail.json fails schema validation"
        sha=$(sha256sum "$jail_copy"); sha=''${sha%% *}
        if ! grep -q "^$sha " "$HOME/.config/jail/allowed" 2>/dev/null; then
          echo "jail: warning: $PWD/.jail.json not approved (jail allow), ignoring" >&2
        else
          policy=$(jq -r '.policy' "$jail_copy")
          jallows=() # assigned by jqlist via nameref
          jqlist jallows '.allow[]' "$jail_copy"
          allows+=("''${jallows[@]}")
          jqlist jail_profiles --arg c "$cmdname" '.mounts[$c] // [] | .[]' "$jail_copy"
        fi
      fi

      # Mount paths: the command's profiles in config.json, then the
      # approved .jail.json profiles (which must exist in config.json).
      jqlist mounts --arg c "$cmdname" '.profiles as $p | .commands[$c].mounts // [] | .[] | $p[.] // [] | .[]' "$config"
      for prof in "''${jail_profiles[@]}"; do
        if ! jq -e --arg p "$prof" '.profiles | has($p)' "$config" >/dev/null 2>&1; then
          echo "jail: .jail.json mount profile not in config.json: $prof" >&2
          continue
        fi
        pm=() # assigned by jqlist via nameref
        jqlist pm --arg p "$prof" '.profiles[$p][]' "$config"
        mounts+=("''${pm[@]}")
      done

      # Landlock arguments for landrun (inside bwrap).
      LANDLOCK_ARGS=(--rox /nix/store --rw "$HOME" --rw "$PWD" --rw /tmp --rw /dev --ro /etc --ro /proc)
      ipre='^([0-9a-fA-F.:]+)(/[0-9]+)?:([0-9]+)/(tcp|udp)$'
      domre='^([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)(:[0-9]+)?$'
      if [[ "$policy" == internet ]]; then
        LANDLOCK_ARGS+=(--connect-tcp 80 --connect-tcp 443)
        for entry in "''${allows[@]}"; do
          [[ "$entry" != */udp ]] || die "internet policy does not support UDP openings: $entry"
          if [[ "$entry" =~ :([0-9]+)(/tcp)?$ ]]; then
            LANDLOCK_ARGS+=(--connect-tcp "''${BASH_REMATCH[1]}")
          fi
        done
        if [[ -n "''${CLAUDE_JAIL_EXTRA_TCP_PORTS:-}" ]]; then
          IFS=',' read -ra extra_ports <<< "''${CLAUDE_JAIL_EXTRA_TCP_PORTS}"
          for port in "''${extra_ports[@]}"; do
            if [[ "$port" =~ ^[0-9]+$ ]]; then LANDLOCK_ARGS+=(--connect-tcp "$port"); fi
          done
        fi
      else
        # allowlist: proxy port plus TCP ports of IP/CIDR entries only.
        proxy_port=8888 # loopback is private to the run's netns
        LANDLOCK_ARGS+=(--connect-tcp "$proxy_port")
        filter_lines=()
        for entry in "''${allows[@]}"; do
          if [[ "$entry" =~ $ipre ]]; then
            if [[ "''${BASH_REMATCH[4]}" == tcp ]]; then LANDLOCK_ARGS+=(--connect-tcp "''${BASH_REMATCH[3]}"); fi
          elif [[ "$entry" =~ $domre ]]; then
            d="''${BASH_REMATCH[1]}"
            filter_lines+=("(^|\.)''${d//./\\.}$")
          else
            echo "jail: ignoring bad allowlist entry: $entry" >&2
          fi
        done
      fi

      # The bwrap root holds only the store closure and the binds below.
      # /run is never mounted, so /run/wrappers (setuid jail-net and the
      # other wrappers) does not exist inside the jail.
      args+=(
        --ro-bind "${cacert}/etc/ssl/certs" /etc/ssl/certs
        --ro-bind /etc/passwd /etc/passwd
        --ro-bind /etc/group /etc/group
        --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf
        --ro-bind /etc/hosts /etc/hosts
        --ro-bind "${resolvConf}" /etc/resolv.conf
        --proc /proc --dev /dev --tmpfs /tmp
        --bind "$jhome" "$HOME"
        --ro-bind "$gitconfig" "$HOME/.gitconfig"
      )

      # Profile mounts: rw unless ":ro"; a leading "~" means $HOME. Same
      # mode in bwrap and landlock.
      for m in "''${mounts[@]}"; do
        [[ -n "$m" ]] || continue
        ro=0
        if [[ "$m" == *:ro ]]; then ro=1; m="''${m%:ro}"; fi
        m="''${m/#\~/$HOME}"
        if [[ ! -e "$m" ]]; then echo "jail: skipping missing $m" >&2; continue; fi
        if [[ "$ro" == 1 ]]; then
          args+=(--ro-bind "$m" "$m"); LANDLOCK_ARGS+=(--ro "$m")
        else
          args+=(--bind "$m" "$m"); LANDLOCK_ARGS+=(--rw "$m")
        fi
      done

      args+=(--bind "$PWD" "$PWD" --ro-bind "$jail_copy" "$PWD/.jail.json")
      args+=(--chdir "$PWD" --unshare-all --unshare-user --disable-userns --share-net
             --die-with-parent --new-session)

      # Seccomp: pass BPF filter to bwrap via --seccomp FD.
      args+=(--seccomp 3)

      args+=(
        --clearenv
        --setenv HOME "$HOME" --setenv USER "$(id -un)" --setenv PATH "$path"
        --setenv TERM "''${TERM:-dumb}"
        --setenv SSL_CERT_FILE "${cacertFile}"
        --setenv JAIL_POLICY "$policy"
        --setenv JAIL_ALLOW "''${allows[*]:-}"
        "''${envargs[@]}"
      )

      # Per-run netns via jail-net. "addr[/cidr]:port/tcp|udp" entries become
      # firewall openings; jail-net refuses the run if any is bad. The EXIT
      # trap tears the run down, so bwrap runs as a child, not via exec.
      openings=()
      for entry in "''${allows[@]}"; do
        if [[ "$entry" =~ $ipre ]]; then openings+=("$entry"); fi
      done
      # No subshell: jail-net records its parent pid (this shell) for stale cleanup.
      "$jnet" up "$runid" "$policy" "''${openings[@]}" >"$pdir/proxy-addr"

      if [[ "$policy" == allowlist ]]; then
        : >"$pdir/filter"
        for l in "''${filter_lines[@]}"; do printf '%s\n' "$l" >>"$pdir/filter"; done
        printf '%s\n' "Port $proxy_port" "Listen 127.0.0.1" "Bind $(<"$pdir/proxy-addr")" \
          "Timeout 600" "MaxClients 32" "Filter \"$pdir/filter\"" "FilterType ere" \
          "FilterDefaultDeny Yes" "ConnectPort 443" "ConnectPort 80" > "$pdir/tinyproxy.conf"
        # Minimal-root tinyproxy: only its store closure, the per-run config,
        # the filter, resolv.conf and the hosts/nsswitch files it needs for DNS.
        # --unshare-all + --share-net keeps it in the run's netns; --disable-userns
        # and --die-with-parent match the jail; --seccomp applies the same BPF.
        # landrun restricts filesystem access to those paths only and allows
        # only the proxy bind port and upstream 80/443 connects.
        proxy_closure=("${pkgs.tinyproxy}" "${landrun}")
        proxy_bwrap=(--ro-bind "${resolvConf}" /etc/resolv.conf
                     --ro-bind /etc/hosts /etc/hosts
                     --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf
                     --ro-bind "$pdir/tinyproxy.conf" "$pdir/tinyproxy.conf"
                     --ro-bind "$pdir/filter" "$pdir/filter"
                     --proc /proc --dev /dev --tmpfs /tmp
                     --unshare-all --share-net --disable-userns
                     --die-with-parent --new-session)
        while IFS= read -r p; do proxy_bwrap+=(--ro-bind "$p" "$p"); done < <(
          nix-store -qR "''${proxy_closure[@]}")
        proxy_land=(--ro "$pdir" --ro /etc --rox /nix/store
                    --bind-tcp "$proxy_port" --connect-tcp 80 --connect-tcp 443)
        exec 4<"${seccompBpf}"
        "$jnet" exec "$runid" -- "${pkgs.util-linux}/bin/setpriv" --inh-caps -all --ambient-caps -all -- \
          "${pkgs.bubblewrap}/bin/bwrap" "''${proxy_bwrap[@]}" --seccomp 4 -- \
          "${landrun}/bin/landrun" "''${proxy_land[@]}" -- \
          "${pkgs.tinyproxy}/bin/tinyproxy" -d -c "$pdir/tinyproxy.conf" >"$pdir/log" 2>&1 &
        proxy_pid=$!
        exec 4<&-
        purl="http://127.0.0.1:$proxy_port"
        args+=(--setenv HTTPS_PROXY "$purl" --setenv HTTP_PROXY "$purl"
               --setenv https_proxy "$purl" --setenv http_proxy "$purl")
        landenv+=(--env HTTPS_PROXY --env HTTP_PROXY --env https_proxy --env http_proxy)
      fi

      # Open FD 3 for the seccomp BPF filter, then run bwrap with landrun inside.
      exec 3<"${seccompBpf}"
      rc=0
      "$jnet" exec "$runid" -- "${pkgs.util-linux}/bin/setpriv" --inh-caps -all --ambient-caps -all -- \
        "${pkgs.bubblewrap}/bin/bwrap" "''${args[@]}" -- \
        "${landrun}/bin/landrun" "''${LANDLOCK_ARGS[@]}" "''${landenv[@]}" -- "$cmdpath" "$@" || rc=$?
      exit "$rc"
    '';
  };

in
{
  users.groups.jail = { };
  users.users.jonas.extraGroups = [ "jail" ];

  # Setuid helper for per-run jail netns; executable by root and group jail only.
  security.wrappers.jail-net = {
    source = "${jail-net}/bin/jail-net";
    owner = "root";
    group = "jail";
    setuid = true;
    permissions = "u+rx,g+x";
  };

  environment.systemPackages = [ jail ] ++ jailedWrappers;

  # Environment variable for extra allowed TCP ports (from stage 1).
  environment.variables.CLAUDE_JAIL_EXTRA_TCP_PORTS = "";

  # IP forwarding for jail namespace traffic (same values as netns-claude-glecom).
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = lib.mkDefault 1;
    "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
  };

  # Static, jump-free state only: jail veths reach nothing unless a per-run
  # rule above these says so, so a lost jump fails closed. Per-run chains
  # survive a reload; resync puts their jumps back on top.
  networking.firewall.extraCommands = lib.mkAfter ''
    for t in iptables ip6tables; do
      for c in INPUT FORWARD; do
        $t -C "$c" -i jh-+ -j DROP 2>/dev/null || $t -I "$c" 1 -i jh-+ -j DROP
      done
    done
    # IPv6 neighbour discovery must reach the host or the jail cannot find its
    # gateway; the INPUT DROP above would discard it. Inserted above the DROP.
    for nd in neighbour-solicitation neighbour-advertisement; do
      ip6tables -C INPUT -i jh-+ -p ipv6-icmp --icmpv6-type "$nd" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -i jh-+ -p ipv6-icmp --icmpv6-type "$nd" -j ACCEPT
    done
    ${jail-net}/bin/jail-net resync || echo "jail-net resync failed" >&2
  '';
}
