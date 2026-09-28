#!/usr/bin/env bash
# Hermetic, stateless test for the shared retry body (retry-body.sh) used by
# both the `nix` and `nixos-rebuild` retry wrappers. Creates fake `real`
# binaries with scripted behavior and asserts that each wrapper retries
# transient remote-builder failures, fails fast on genuine build errors, passes
# non-building subcommands straight through, and preserves stdout. Runnable from
# a clean checkout with a single command:
#
#   bash machines/jester/retry-body.test.sh
#
# shellcheck disable=SC1090  # $BODY is a runtime path we deliberately source
# shellcheck disable=SC2034  # real / RETRY_KIND are consumed by the sourced body
# shellcheck disable=SC2016  # make_fake bodies are single-quoted templates by design
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BODY="$HERE/retry-body.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export RETRY_DELAY=0   # no real sleeping
export RETRY_MAX=4
# Absolute bash path for fake-binary shebangs: the Nix build sandbox has no
# /usr/bin/env, so #!/usr/bin/env bash is a "bad interpreter" there.
BASH_BIN=$(command -v bash)

fails=0
check() { # desc, expected, actual
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fails=$((fails + 1))
  fi
}

# Build a fake `real` binary that records each invocation (one line per call) to
# $CTR and runs $2 with the call number as $n.
make_fake() { # name, body
  local name=$1
  local ctr="$tmp/$name.ctr"
  : >"$ctr"
  cat >"$tmp/$name" <<EOF
#!$BASH_BIN
echo x >>"$ctr"
n=\$(wc -l <"$ctr")
$2
EOF
  chmod +x "$tmp/$name"
}

run() { # kind, fake-name, args...  -> sets global RC; positionals reach the body
  local kind=$1 fake=$2; shift 2
  ( real="$tmp/$fake"; RETRY_KIND="$kind"; source "$BODY" "$@" )
  RC=$?
}
calls() { wc -l <"$tmp/$1.ctr" | tr -d ' '; }

echo "## nix wrapper (RETRY_KIND=nix)"

# 1. Transient failure twice, then success -> retried, ends 0, called 3x.
make_fake transient_then_ok '
if [ "$n" -lt 3 ]; then echo "error: writing to file: Broken pipe" >&2; exit 1; fi
echo built; exit 0'
run nix transient_then_ok build .#foo
check "transient-then-ok exits 0" 0 "$RC"
check "transient-then-ok retried to 3rd attempt" 3 "$(calls transient_then_ok)"

# 2. Genuine build failure -> NOT retried, exits 101, called once.
make_fake genuine_fail '
echo "       > error: could not compile \`node\`" >&2
echo "error: builder failed with exit code 101" >&2
exit 101'
run nix genuine_fail build .#foo
check "genuine-fail exits 101" 101 "$RC"
check "genuine-fail not retried (1 call)" 1 "$(calls genuine_fail)"

# 3. Always transient -> retried up to max, exits 1, called RETRY_MAX times.
make_fake always_transient '
echo "error: Nix daemon disconnected unexpectedly (maybe it crashed?)" >&2
exit 1'
run nix always_transient build .#foo
check "always-transient exhausts to rc 1" 1 "$RC"
check "always-transient capped at max attempts" 4 "$(calls always_transient)"

# 4. Cold-box wake race signature -> retried then succeeds.
make_fake wake_race '
if [ "$n" -lt 2 ]; then
  echo "error: failed to start SSH connection to '"'"'closure-build-gateway.fly.dev'"'"'" >&2
  echo "Failed to find a machine for remote build!" >&2
  echo "error: Unable to start any build; remote machines may not have all required system features." >&2
  exit 1
fi
echo built; exit 0'
run nix wake_race build .#foo
check "wake-race recovers (rc 0)" 0 "$RC"
check "wake-race retried once" 2 "$(calls wake_race)"

# 5. False-positive guard: "Connection reset" only inside an indented build-log
#    line of a genuinely-failing build must NOT trigger a retry.
make_fake log_false_positive '
echo "       > thread panicked: Connection reset by peer" >&2
echo "error: builder failed with exit code 101" >&2
exit 101'
run nix log_false_positive build .#foo
check "indented-log false positive not retried" 1 "$(calls log_false_positive)"

# 6. flake check is wrapped (retried); flake update / develop are not.
make_fake flake_check_transient '
if [ "$n" -lt 2 ]; then echo "error: writing to file: Broken pipe" >&2; exit 1; fi
exit 0'
run nix flake_check_transient flake check
check "flake check retried (rc 0)" 0 "$RC"
check "flake check retried once" 2 "$(calls flake_check_transient)"

make_fake flake_update_passthrough '
echo "error: writing to file: Broken pipe" >&2; exit 1'
run nix flake_update_passthrough flake update
check "flake update passthrough not retried" 1 "$(calls flake_update_passthrough)"

make_fake develop_passthrough '
echo "error: writing to file: Broken pipe" >&2; exit 1'
run nix develop_passthrough develop
check "develop passthrough not retried" 1 "$(calls develop_passthrough)"

# 6b. Global flags BEFORE the subcommand (as nixos-rebuild invokes nix) must
#     still be detected and retried.
make_fake flags_then_build '
if [ "$n" -lt 2 ]; then echo "error: writing to file: Broken pipe" >&2; exit 1; fi
exit 0'
run nix flags_then_build --extra-experimental-features "nix-command flakes" build --print-out-paths .#foo
check "flags-before-build detected + retried (rc 0)" 0 "$RC"
check "flags-before-build retried once" 2 "$(calls flags_then_build)"

# 6c. "path is not valid" (transient copy-to-builder input coherence) is retried.
make_fake invalid_path '
if [ "$n" -lt 2 ]; then echo "error: path '"'"'/nix/store/abc-farstream-0.2.9'"'"' is not valid" >&2; exit 1; fi
exit 0'
run nix invalid_path build .#foo
check "path-not-valid retried (rc 0)" 0 "$RC"
check "path-not-valid retried once" 2 "$(calls invalid_path)"

# 6d. stdout is preserved (not merged into stderr) for build.
make_fake stdout_preserve 'echo "/nix/store/abc-out"; exit 0'
out=$( ( real="$tmp/stdout_preserve"; RETRY_KIND=nix; source "$BODY" build --print-out-paths .#foo ) 2>/dev/null )
check "stdout preserved on success" "/nix/store/abc-out" "$out"

# 6e. HARD marker (Broken pipe) relayed INSIDE an indented build-log line under a
#     top-level "exit code 101" summary IS retried (HARD tier matches full stderr).
make_fake hard_in_log '
if [ "$n" -lt 2 ]; then
  echo "       > error: writing to file: Broken pipe" >&2
  echo "error: builder for '"'"'/nix/store/x.drv'"'"' failed with exit code 101" >&2
  exit 1
fi
exit 0'
run nix hard_in_log build .#foo
check "HARD marker in indented log retried (rc 0)" 0 "$RC"
check "HARD marker in indented log retried once" 2 "$(calls hard_in_log)"

# 6f. SOFT marker inside a drvname-prefixed build-log line is NOT transient
#     (an app printing "Connection reset" must not trigger a retry).
make_fake soft_in_drvlog '
echo "myapp> thread panicked: Connection reset by peer" >&2
echo "error: builder for '"'"'/nix/store/x.drv'"'"' failed with exit code 101" >&2
exit 101'
run nix soft_in_drvlog build .#foo
check "SOFT in drvname-prefixed log not retried" 1 "$(calls soft_in_drvlog)"

# 6g. "download buffer is full" is retried (SOFT insurance).
make_fake dl_buffer '
if [ "$n" -lt 2 ]; then echo "error: download buffer is full; consider increasing download-buffer-size" >&2; exit 1; fi
exit 0'
run nix dl_buffer build .#foo
check "download-buffer-full retried (rc 0)" 0 "$RC"

# 6h. "is not valid" for a NON-store path is NOT retried (regex anchored to /nix/store).
make_fake nonstore_invalid '
echo "error: path '"'"'/home/jonas/thing'"'"' is not valid" >&2
echo "error: builder failed with exit code 1" >&2
exit 1'
run nix nonstore_invalid build .#foo
check "non-store path-not-valid not retried" 1 "$(calls nonstore_invalid)"

# 6i. REGRESSION (tee-pipe hang): $real exits immediately (success or failure)
#     but leaves behind a lingering background grandchild that still holds an
#     inherited fd open (the ssh -M ControlMaster mux case in production).
#     With stderr routed through a pipe/tee, the pipeline never sees EOF and
#     hangs forever even though $real already returned. Assert the wrapper
#     returns within a few seconds regardless, for both a successful and a
#     failing $real.
run_with_timeout() { # seconds, kind, fake, args... -> sets RC (124 = timed out)
  local secs=$1 kind=$2 fake=$3; shift 3
  timeout "$secs" "$BASH_BIN" -c '
      real="$1"; RETRY_KIND="$2"; shift 2; source "$0" "$@"
    ' "$BODY" "$tmp/$fake" "$kind" "$@"
  RC=$?
}

make_fake lingering_child_ok '
( sleep 5; echo "late child output" ) >&2 &
disown
exit 0'
run_with_timeout 8 nix lingering_child_ok build .#foo
check "lingering-child success returns promptly (not timed out)" 0 "$RC"

make_fake lingering_child_fail '
( sleep 5; echo "late child output" ) >&2 &
disown
echo "error: builder failed with exit code 101" >&2
exit 101'
run_with_timeout 8 nix lingering_child_fail build .#foo
check "lingering-child genuine failure returns promptly" 101 "$RC"

echo
echo "## nixos-rebuild wrapper (RETRY_KIND=nixos-rebuild)"

# 7. `switch` that drops mid-build twice, then succeeds -> retried, ends 0.
make_fake nrb_switch_transient '
if [ "$n" -lt 3 ]; then echo "error: writing to file: Broken pipe" >&2; exit 1; fi
echo "activating the configuration..."; exit 0'
run nixos-rebuild nrb_switch_transient switch --flake .#jester
check "nrb switch transient-then-ok exits 0" 0 "$RC"
check "nrb switch retried to 3rd attempt" 3 "$(calls nrb_switch_transient)"

# 8. Flags before the action (as the user types `--flake .#jester switch`).
make_fake nrb_flags_first '
if [ "$n" -lt 2 ]; then echo "error: Nix daemon disconnected unexpectedly (maybe it crashed?)" >&2; exit 1; fi
exit 0'
run nixos-rebuild nrb_flags_first --flake .#jester switch
check "nrb flags-before-action detected + retried" 2 "$(calls nrb_flags_first)"

# 9. Genuine activation/build failure (exit 101, no transient text) -> fail fast.
make_fake nrb_genuine '
echo "error: builder for '"'"'/nix/store/x.drv'"'"' failed with exit code 1" >&2
exit 1'
run nixos-rebuild nrb_genuine switch --flake .#jester
check "nrb genuine failure not retried (1 call)" 1 "$(calls nrb_genuine)"
check "nrb genuine failure exits 1" 1 "$RC"

# 10. dry-build / dry-activate are building actions -> retried.
make_fake nrb_dry '
if [ "$n" -lt 2 ]; then echo "error: writing to file: Broken pipe" >&2; exit 1; fi
exit 0'
run nixos-rebuild nrb_dry dry-activate --flake .#jester
check "nrb dry-activate retried (rc 0)" 0 "$RC"
check "nrb dry-activate retried once" 2 "$(calls nrb_dry)"

# 10b. dry-run (alias nixos-rebuild-ng rewrites to dry-build; still offloads) is retried.
make_fake nrb_dryrun '
if [ "$n" -lt 2 ]; then echo "error: Nix daemon disconnected unexpectedly (maybe it crashed?)" >&2; exit 1; fi
exit 0'
run nixos-rebuild nrb_dryrun dry-run --flake .#jester
check "nrb dry-run retried (rc 0)" 0 "$RC"
check "nrb dry-run retried once" 2 "$(calls nrb_dryrun)"

# 11. Interactive / non-building actions pass straight through (NOT retried)
#     even if they happen to print transient-looking text.
for action in repl edit list-generations; do
  make_fake "nrb_$action" '
echo "error: writing to file: Broken pipe" >&2; exit 1'
  run nixos-rebuild "nrb_$action" "$action" --flake .#jester
  check "nrb $action passthrough not retried" 1 "$(calls "nrb_$action")"
done

echo
if [ "$fails" -eq 0 ]; then
  echo "All retry-body tests passed."
else
  echo "$fails retry-body test(s) FAILED."
fi
exit "$fails"
