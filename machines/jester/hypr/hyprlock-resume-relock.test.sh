#!/usr/bin/env bash
# Needs sed, grep, bash, sleep, mkdir, rm, jq (optional) on PATH; the Nix check
# derivation (flake.nix) supplies these via nativeBuildInputs. Resolved
# through PATH, not hardcoded /run/current-system/sw/bin, so this also runs
# hermetically in the build sandbox, which has no /run/current-system.
#
# Hermetic, stateless test for check_option()'s JSON parsing in
# hyprlock-resume-relock.sh. Stubs hyprctl with each real output shape
# Hyprland can return (int, bool true, bool false) and asserts check_option's
# pass/fail verdict, for both the jq and non-jq (grep/sed) code paths,
# without needing a real Hyprland running.
#
# Regression coverage: check_option used to parse only .int // .str, so a
# boolean option (returned as {"bool": true/false}, no "int"/"str" key) never
# matched and the function always failed, even when the option was correctly
# set. Confirmed live against this machine's Hyprland:
# misc:allow_session_lock_restore returns {"bool": true},
# misc:lockdead_screen_delay returns {"int": 0}.
#
# Runnable from a clean checkout with a single command:
#
#   bash machines/jester/hypr/hyprlock-resume-relock.test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/hyprlock-resume-relock.sh"

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

# Pull check_option() out of the real script (rather than re-implementing the
# parsing logic separately, which could drift from it and mask a
# regression), with its hardcoded /run/current-system/sw/bin/ paths
# redirected to a fake bin dir we control.
func_src="$tmp/check_option.sh"
sed -n '/^check_option() {/,/^}/p' "$SCRIPT" \
    | sed -E 's#/run/current-system/sw/bin/#'"$tmp"'/bin/#g' \
    > "$func_src"
[ -s "$func_src" ] || { echo "FAIL - could not extract check_option() from $SCRIPT"; exit 1; }

mkdir -p "$tmp/bin" "$tmp/bin-nojq"
ln -sf "$(command -v sleep)" "$tmp/bin/sleep"
ln -sf "$(command -v grep)" "$tmp/bin/grep"
ln -sf "$(command -v sed)" "$tmp/bin/sed"
ln -sf "$(command -v sleep)" "$tmp/bin-nojq/sleep"
ln -sf "$(command -v grep)" "$tmp/bin-nojq/grep"
ln -sf "$(command -v sed)" "$tmp/bin-nojq/sed"
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$tmp/bin/jq"
fi
# bin-nojq deliberately has no jq, to exercise the grep/sed fallback branch.

# Fake hyprctl: prints whatever JSON the test case supplies via $FAKE_JSON.
for dir in "$tmp/bin" "$tmp/bin-nojq"; do
    cat > "$dir/hyprctl" <<EOF
#!$(command -v bash)
[ "\$1" = "getoption" ] && echo "\$FAKE_JSON"
EOF
    chmod +x "$dir/hyprctl"
done

run_case() { # desc, json, opt, want, expect_pass(0/1), with_jq(0/1)
    local desc=$1 json=$2 opt=$3 want=$4 expect=$5 with_jq=$6
    local bindir="$tmp/bin"
    [ "$with_jq" -eq 0 ] && bindir="$tmp/bin-nojq"
    FAKE_JSON="$json" PATH="$bindir:$PATH" bash -c "
        set -u
        source '$func_src'
        check_option '$opt' '$want'
    "
    local rc=$?
    local got=1
    [ "$rc" -eq 0 ] && got=0
    check "$desc" "$expect" "$got"
}

echo "## check_option() parsing (jq present)"
run_case "bool true matches want=true"     '{"option":"misc:allow_session_lock_restore","bool":true,"set":true}'  misc:allow_session_lock_restore true 0 1
run_case "bool false vs want=true fails"   '{"option":"misc:allow_session_lock_restore","bool":false,"set":true}' misc:allow_session_lock_restore true 1 1
run_case "int 0 matches want=0"            '{"option":"misc:lockdead_screen_delay","int":0,"set":true}'          misc:lockdead_screen_delay 0 0 1
run_case "int 5 vs want=0 fails"           '{"option":"misc:lockdead_screen_delay","int":5,"set":true}'          misc:lockdead_screen_delay 0 1 1

echo "## check_option() parsing (no jq, grep/sed fallback)"
run_case "fallback: bool true matches want=true"   '{"option": "misc:allow_session_lock_restore", "bool": true, "set": true }'  misc:allow_session_lock_restore true 0 0
run_case "fallback: bool false vs want=true fails" '{"option": "misc:allow_session_lock_restore", "bool": false, "set": true }' misc:allow_session_lock_restore true 1 0
run_case "fallback: int 0 matches want=0"          '{"option": "misc:lockdead_screen_delay", "int": 0, "set": true }'          misc:lockdead_screen_delay 0 0 0

echo "## kill-before-start ordering"
# Root cause of the "fresh hyprlock never arms" failures (2026-10-06): while
# the old hyprlock is still alive it holds the fprintd claim, so a new one
# started before the old one is confirmed dead logs "AlreadyInUse" and never
# arms. The script already enforces kill-then-verify-then-start (lines
# ~114-150); this runs it end to end against a fully faked toolchain and
# asserts the old process is confirmed dead before hyprlock-wrapper is ever
# invoked, with no real hyprctl/pkill/hyprlock/sleep involved.
order_tmp=$(mktemp -d)
mkdir -p "$order_tmp/bin"

# hyprctl: getoption always reports the two required options as set
# correctly; dispatch is a no-op. Satisfies the precondition checks so the
# script proceeds to the kill/start sequence under test.
cat > "$order_tmp/bin/hyprctl" <<EOF
#!$(command -v bash)
if [ "\$1" = "getoption" ]; then
    case "\$2" in
        misc:allow_session_lock_restore) echo '{"option":"misc:allow_session_lock_restore","bool":true,"set":true}' ;;
        misc:lockdead_screen_delay)      echo '{"option":"misc:lockdead_screen_delay","int":0,"set":true}' ;;
    esac
fi
exit 0
EOF

# pkill: records the kill event and marks the old PID dead. Does not touch
# any real process; "dead" here is purely the fake kill/pgrep state below.
cat > "$order_tmp/bin/pkill" <<EOF
#!$(command -v bash)
echo "pkill" >> "$order_tmp/events"
touch "$order_tmp/old_dead"
EOF

# kill: "-0 PID" reports alive until old_dead exists, matching the script's
# own post-pkill verification loop. Any other invocation is a no-op.
cat > "$order_tmp/bin/kill" <<EOF
#!$(command -v bash)
[ "\$1" = "-0" ] || exit 0
[ -e "$order_tmp/old_dead" ] && exit 1
exit 0
EOF

# hyprlock-wrapper: the replacement start. Refuses outright, loudly, if the
# old PID has not been confirmed dead yet -- this is the ordering invariant
# under test, enforced here rather than merely hoped for. On success it
# records a fresh fake PID for the fake pgrep below to report.
cat > "$order_tmp/bin/hyprlock-wrapper" <<EOF
#!$(command -v bash)
if [ ! -e "$order_tmp/old_dead" ]; then
    echo "wrapper-start-before-kill" >> "$order_tmp/events"
    exit 1
fi
echo "wrapper-start" >> "$order_tmp/events"
echo 55555 > "$order_tmp/new_pid"
EOF

# pgrep: once hyprlock-wrapper has "started", report its fake new PID (never
# one of the old PIDs, so the script's started-detection logic sees a real
# replacement rather than mistaking a surviving old process for success).
cat > "$order_tmp/bin/pgrep" <<EOF
#!$(command -v bash)
[ -f "$order_tmp/new_pid" ] && cat "$order_tmp/new_pid"
exit 0
EOF

ln -sf "$(command -v sleep)" "$order_tmp/bin/sleep"
ln -sf "$(command -v seq)" "$order_tmp/bin/seq"
ln -sf "$(command -v grep)" "$order_tmp/bin/grep"
ln -sf "$(command -v sed)" "$order_tmp/bin/sed"
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$order_tmp/bin/jq"
fi
cat > "$order_tmp/bin/systemd-cat" <<EOF
#!$(command -v bash)
cat >> "$order_tmp/log_err"
EOF
chmod +x "$order_tmp/bin/systemd-cat"
chmod +x "$order_tmp/bin"/hyprctl "$order_tmp/bin"/pkill "$order_tmp/bin"/kill \
    "$order_tmp/bin"/hyprlock-wrapper "$order_tmp/bin"/pgrep

# Same hardcoded-path redirection as the check_option() extraction above:
# the real script calls /run/current-system/sw/bin/<tool> directly, not
# whatever's on PATH, so a copy with those paths rewritten to our fake bin
# dir is what actually exercises the fakes.
order_script="$order_tmp/hyprlock-resume-relock.sh"
sed -E 's#/run/current-system/sw/bin/#'"$order_tmp"'/bin/#g' "$SCRIPT" > "$order_script"

PATH="$order_tmp/bin:$PATH" bash "$order_script" --replace-pids 11111 >"$order_tmp/stdout" 2>"$order_tmp/stderr"
rc=$?
check "ordering run exits 0"                 "0" "$rc"
check "ordering: no start-before-kill"        "0" "$(grep -c '^wrapper-start-before-kill$' "$order_tmp/events" 2>/dev/null)"
events="$(cat "$order_tmp/events" 2>/dev/null)"
check "ordering: pkill then wrapper-start"    "$(printf '%s\n%s' pkill wrapper-start)" "$events"

rm -rf "$order_tmp"

echo
if [ "$fails" -eq 0 ]; then
    echo "All hyprlock-resume-relock tests passed."
else
    echo "$fails hyprlock-resume-relock test(s) FAILED."
fi
exit "$fails"
