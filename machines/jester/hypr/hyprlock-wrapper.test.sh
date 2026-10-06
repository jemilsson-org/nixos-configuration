#!/usr/bin/env bash
# Needs bash, grep, coreutils on PATH; the Nix check derivation (flake.nix)
# supplies these via nativeBuildInputs. Resolved through PATH, not hardcoded
# /run/current-system/sw/bin, so this runs hermetically in the build sandbox.
#
# Hermetic, stateless test for verifymatch_watch()'s state machine in
# hyprlock-wrapper.sh: the "fingerprint matched but hyprlock hung" workaround
# (2026-10-06). Fakes kill/grep/pgrep/hyprlock-resume-relock so the whole
# sequence runs in milliseconds with no real hyprlock, fprintd, or signals.
#
# Regression coverage:
#   - never fires without a logged verify-match
#   - sends exactly one SIGUSR1 when the process is still alive 3s after match
#   - never sends SIGUSR1 if the process already exited on its own
#   - falls back to hyprlock-resume-relock --replace-pids only when SIGUSR1
#     itself hangs, then signals the replacement too
#
# Runnable from a clean checkout with a single command:
#
#   bash machines/jester/hypr/hyprlock-wrapper.test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/hyprlock-wrapper.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0
check() { # desc, expected, actual
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1 (expected '$2', got '$3')"
        fails=$((fails + 1))
    fi
}

# Pull verifymatch_watch() out of the real script, same approach as
# hyprlock-resume-relock.test.sh's check_option() extraction: tests the real
# logic, not a reimplementation that could drift from it. Its hardcoded
# /run/current-system/sw/bin/ paths are redirected to our fake bin dir.
func_src="$tmp/verifymatch_watch.sh"
sed -n '/^verifymatch_watch() {/,/^}/p' "$SCRIPT" \
    | sed -E 's#/run/current-system/sw/bin/#'"$tmp"'/bin/#g' \
    > "$func_src"
[ -s "$func_src" ] || { echo "FAIL - could not extract verifymatch_watch() from $SCRIPT"; exit 1; }

mkdir -p "$tmp/bin"
ln -sf "$(command -v grep)" "$tmp/bin/grep"

# fake sleep: instant, so the test doesn't spend 6+ real seconds per case.
# Shebang is $(command -v bash), not /usr/bin/env bash: the Nix build
# sandbox has no /usr/bin/env, which silently failed every fake-script exec
# there (the real-world local run masked this, since env exists outside the
# sandbox) and made every signals/relock_calls assertion below see nothing.
cat > "$tmp/bin/sleep" <<EOF
#!$(command -v bash)
exit 0
EOF

# fake kill: "-0 PID" liveness checks succeed for the first
# $ALIVE_FOR_ZERO_CHECKS calls and fail after; any other invocation (a real
# signal) is just logged to $FAKE_STATE/signals.
cat > "$tmp/bin/kill" <<EOF
#!$(command -v bash)
if [ "\$1" = "-0" ]; then
    n=\$(( \$(cat "\$FAKE_STATE/zero_calls" 2>/dev/null || echo 0) + 1 ))
    echo "\$n" > "\$FAKE_STATE/zero_calls"
    [ "\$n" -le "\${ALIVE_FOR_ZERO_CHECKS:-0}" ]
    exit \$?
fi
echo "\$*" >> "\$FAKE_STATE/signals"
exit 0
EOF

# fake hyprlock-resume-relock: records that it ran; never touches a real
# process. Exit code controlled by $RELOCK_EXIT (default success).
cat > "$tmp/bin/hyprlock-resume-relock" <<EOF
#!$(command -v bash)
echo "\$*" >> "\$FAKE_STATE/relock_calls"
exit "\${RELOCK_EXIT:-0}"
EOF

# fake pgrep: reports a new PID distinct from the original, simulating the
# replacement hyprlock-resume-relock just started.
cat > "$tmp/bin/pgrep" <<EOF
#!$(command -v bash)
echo "\${FAKE_NEW_PID:-99999}"
EOF

chmod +x "$tmp/bin"/sleep "$tmp/bin"/kill "$tmp/bin"/hyprlock-resume-relock "$tmp/bin"/pgrep

run_watch() { # alive_for_zero_checks, relock_exit, verify_match_present(0/1)
    local alive=$1 relock_exit=$2 have_match=$3
    rm -rf "$tmp/state"; mkdir -p "$tmp/state"
    local log_file="$tmp/state/hyprlock.log"
    [ "$have_match" -eq 1 ] && echo "fprint: handling status verify-match" > "$log_file" || : > "$log_file"
    FAKE_STATE="$tmp/state" ALIVE_FOR_ZERO_CHECKS="$alive" RELOCK_EXIT="$relock_exit" \
        PATH="$tmp/bin:$PATH" bash -c "
        set -u
        source '$func_src'
        verifymatch_watch 12345 '$log_file'
    "
}

signals() { cat "$tmp/state/signals" 2>/dev/null; }
relock_calls() { cat "$tmp/state/relock_calls" 2>/dev/null; }

echo "## verifymatch_watch() state machine"

# No verify-match ever logged, process already gone: must never signal.
run_watch 0 0 0
check "no verify-match -> no SIGUSR1"        "" "$(signals)"
check "no verify-match -> no replace"        "" "$(relock_calls)"

# Match logged, but process already exited by the first liveness check after
# it (natural unlock): must never signal.
run_watch 1 0 1
check "dies before 3s mark -> no SIGUSR1"    "" "$(signals)"
check "dies before 3s mark -> no replace"    "" "$(relock_calls)"

# Match logged, alive at the 3s mark, dies after SIGUSR1 (the common,
# working case): exactly one SIGUSR1, no replace.
run_watch 3 0 1
check "SIGUSR1 unlocks -> one signal"        "-USR1 12345" "$(signals)"
check "SIGUSR1 unlocks -> no replace"        "" "$(relock_calls)"

# Match logged, still alive at every liveness check (SIGUSR1 itself hangs
# too): replace via hyprlock-resume-relock, then signal the replacement too.
run_watch 99 0 1
check "SIGUSR1 hangs -> replace invoked"     "--replace-pids 12345" "$(relock_calls)"
check "SIGUSR1 hangs -> signals old and new" "$(printf '%s\n%s' '-USR1 12345' '-USR1 99999')" "$(signals)"

echo
if [ "$fails" -eq 0 ]; then
    echo "All hyprlock-wrapper verifymatch_watch tests passed."
else
    echo "$fails hyprlock-wrapper verifymatch_watch test(s) FAILED."
fi
exit "$fails"
