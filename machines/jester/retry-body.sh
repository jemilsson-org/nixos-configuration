# shellcheck shell=bash
# shellcheck disable=SC2154  # $real / $RETRY_KIND come from the sourcing scope
# Core dispatch + transient-retry logic shared by the `nix` and `nixos-rebuild`
# retry wrappers (nix-retry.nix), factored out so the hermetic test
# (retry-body.test.sh) exercises the EXACT code the deployed wrappers run.
#
# Why two wrappers share one body:
#   jester offloads ALL builds to a remote builder (closure.build's Fly.io
#   gateway). The long-haul ssh-ng mux drops mid-build and nix has NO
#   built-in retry, so transient remote-builder failures crash builds
#   outright. `nix build`/`nix flake check` (jonas's interactive builds;
#   ~/.config/nix max-jobs=0 force-offloads with no local fallback) AND
#   `nixos-rebuild switch` (system deploys) both hit this. nixos-rebuild-ng runs
#   its OWN bundled `nix` (prepended to PATH) via PATH lookup, so wrapping `nix`
#   alone does NOT protect system rebuilds; `nixos-rebuild` must be wrapped too.
#   Both retry on the SAME transient allowlist below and fail fast on genuine
#   build errors.
#
# Expects in the sourcing scope:
#   $real         absolute path to the real binary being wrapped
#   $RETRY_KIND   "nix" or "nixos-rebuild" (selects which subcommands retry)
#   "$@"          the invocation args (source preserves the caller's positionals)
# Tools (mktemp/tail/grep/sleep) come from PATH; the wrappers prepend them and
# the test relies on the system PATH.
#
# Env overrides (used by the test to run fast and bounded):
#   RETRY_MAX     max attempts (default 4)
#   RETRY_DELAY   per-attempt backoff multiplier in seconds (default 15)

# Allowlist of TRANSIENT remote-builder failures, taken verbatim from real
# jester-side crash output (frequencies from Claude transcripts):
#   error: writing to file: Broken pipe              (dominant mid-build mux drop)
#   Nix daemon disconnected unexpectedly             (mid-build mux drop, jester view)
#   Connection reset/closed/timed out, ssh_exchange  (ssh transport drop)
#   failed to start SSH connection / Failed to find a machine for remote build /
#     Unable to start any build                      (cold-box wake race)
#   error: path '...' is not valid                   (a build INPUT wasn't yet
#     available on the builder during copy-to-builder; converges across retries
#     as a different path resolves each attempt)
# Genuine build failures ("builder failed with exit code 101", rustc/clippy
# diagnostics, eval errors) match NEITHER tier, so they fail fast.
# `interrupted by the user` is deliberately excluded: it is the Ctrl-C /
# sibling-reaper signature; a real drop co-emits a HARD marker (Broken pipe).
#
# Two tiers, by how safely each phrase can be matched against nix's build-log
# output (plain assignments, not ${VAR:-default}: single quotes inside a
# ${...:-...} word toggle quoting even within double quotes and would trip the
# '[^']*' fragment):
#   RETRY_HARD  nix-daemon / transport phrases that NEVER appear in legitimate
#     application build output -> matched against the FULL stderr, so a relayed
#     mid-build drop buried in an indented/drvname-prefixed build-log line under
#     a top-level "exit code 101" summary is still caught.
#   RETRY_SOFT  phrases an app COULD print ("Connection reset", a stray "is not
#     valid") -> matched only against TOP-LEVEL nix diagnostics (build-log lines
#     stripped) to avoid app-layer false positives. "download buffer is full" is
#     here as cheap insurance: if non-fatal (rc=0) it is never consulted; if it
#     ever aborts, a re-run under different burst timing may clear it.
RETRY_HARD="writing to file: Broken pipe|Nix daemon disconnected unexpectedly"
RETRY_SOFT="failed to start SSH connection|Failed to find a machine for remote build|Unable to start any build|Connection reset by peer|Connection timed out|Connection closed by|client_loop: send disconnect|ssh_exchange_identification|kex_exchange_identification|connection unexpectedly closed|download buffer is full|error: path '/nix/store/[^']*' is not valid"

# True if the captured stderr ($1) looks like a transient remote-builder
# failure. HARD markers match anywhere; SOFT markers match only outside nix's
# indented ("  > ") and drvname-prefixed ("name> ") build-log lines.
retry_is_transient() {
  grep -qE "$RETRY_HARD" "$1" && return 0
  grep -vE '^[[:space:]]*>|^[^[:space:]]+> ' "$1" | grep -qE "$RETRY_SOFT" && return 0
  return 1
}

# Predicate: is this `nix` invocation a `build` or `flake check`? Scans ALL args
# for the subcommand token rather than assuming it is $1: nix is frequently
# called with global flags first, e.g.
#   nix --extra-experimental-features 'nix-command flakes' build --print-out-paths .#foo
# (nixos-rebuild does exactly this). A global flag VALUE that equals the whole
# token "build"/"flake"/"check" is effectively nonexistent, so whole-arg
# matching is safe; worst case we wrap a non-build command, which is transparent
# (retry only ever fires on the transient allowlist, which never appears
# otherwise).
retry_wraps_nix() {
  local a saw_flake=0 saw_check=0
  for a in "$@"; do
    case "$a" in
      build) return 0 ;;
      flake) saw_flake=1 ;;
      check) saw_check=1 ;;
    esac
  done
  [ "$saw_flake" = 1 ] && [ "$saw_check" = 1 ]
}

# Predicate: is this `nixos-rebuild` invocation one that BUILDS (and thus
# offloads to a remote builder)? Allowlist the building actions; everything else (repl,
# edit, list-generations, ...) is passed straight through with exec so its
# TTY/stdin/interactivity is preserved. Like the nix predicate we scan all args
# because the action can follow global flags (e.g. `--flake .#x switch`); a flag
# named like an action (`--build-host`) is a distinct whole arg and never
# matches an action token.
retry_wraps_nixos_rebuild() {
  local a
  for a in "$@"; do
    case "$a" in
      switch|boot|test|build|dry-build|dry-run|dry-activate|build-vm|build-vm-with-bootloader|build-image)
        # dry-run is a deprecated alias nixos-rebuild-ng rewrites to dry-build;
        # it still offloads the build to the remote builder, so it must be retried too.
        return 0 ;;
    esac
  done
  return 1
}

retry_wraps() {
  case "${RETRY_KIND:?RETRY_KIND must be set to nix or nixos-rebuild}" in
    nix)           retry_wraps_nix "$@" ;;
    nixos-rebuild) retry_wraps_nixos_rebuild "$@" ;;
    *)             return 1 ;;
  esac
}

retry_main() {
  # Only wrap building invocations; everything else is a pure passthrough
  # (exec = zero overhead, preserves TTY/stdin/signals/exit).
  retry_wraps "$@" || exec "$real" "$@"

  local max="${RETRY_MAX:-4}" attempt=1 err="" rc delay realpid="" tailpid=""
  # Clean the in-flight capture file and children on Ctrl-C / SIGTERM (the
  # in-loop rm only runs on a normal return); a clean Ctrl-C also aborts
  # immediately rather than spinning the retry loop.
  trap 'kill "$realpid" "$tailpid" 2>/dev/null; rm -f "$err"; exit 130' INT TERM

  while :; do
    err=$(mktemp)
    # Capture stderr to a plain FILE, never a pipe: a pipe's write fd is
    # inherited by every grandchild $real forks, including the ssh -M
    # ControlMaster mux nix keeps alive for ssh-ng://builder@closure-build. If
    # such a mux child outlives $real (e.g. it's still reconnecting after a
    # "Nix daemon disconnected unexpectedly" drop), it holds the pipe's write
    # end open forever; `tee` then never sees EOF and never exits, and the
    # command hangs indefinitely even though $real already exited with the
    # right code (observed: 435/435 checks pass, then a ~60min hang). A
    # regular file has no such handle for a grandchild to hold.
    # $real runs backgrounded so we can `wait` on ITS pid for the exit code
    # (never on however long a stream consumer takes); `tail -f --pid=` mirrors
    # $err to the terminal live and exits on its own once that pid is gone,
    # not on pipe EOF. stdout is untouched (inherited directly), so --json /
    # --print-out-paths pass through unmodified.
    # NOTE: stderr goes to a file, not a TTY, so nix falls back from its
    # animated progress bar to plain per-line logs. Accepted tradeoff for
    # transparent retry (unchanged from before this fix).
    "$real" "$@" 2>>"$err" &
    realpid=$!
    tail -n +1 -f --pid="$realpid" "$err" >&2 &
    tailpid=$!
    wait "$realpid"
    rc=$?
    # Don't wait out tail's own --pid poll interval (up to ~1s per attempt):
    # $err already has the full output by the time $real has exited (its
    # writes are synchronous appends, and tail -f follows via inotify), so the
    # live mirror to the terminal has nothing further to add. Killing it here
    # is a display-only optimization; retry_is_transient reads $err directly.
    kill "$tailpid" 2>/dev/null
    wait "$tailpid" 2>/dev/null
    if [ "$rc" -eq 0 ]; then
      rm -f "$err"
      return 0
    fi
    if [ "$attempt" -ge "$max" ] || ! retry_is_transient "$err"; then
      rm -f "$err"
      return "$rc"
    fi
    rm -f "$err"
    delay=$(( attempt * ${RETRY_DELAY:-15} ))
    echo "retry: transient remote-builder failure (attempt $attempt/$max, rc=$rc); retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
}

retry_main "$@"
