#!/usr/bin/env bash
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
/run/current-system/sw/bin/sed -n '/^check_option() {/,/^}/p' "$SCRIPT" \
    | /run/current-system/sw/bin/sed -E 's#/run/current-system/sw/bin/#'"$tmp"'/bin/#g' \
    > "$func_src"
[ -s "$func_src" ] || { echo "FAIL - could not extract check_option() from $SCRIPT"; exit 1; }

mkdir -p "$tmp/bin" "$tmp/bin-nojq"
ln -sf /run/current-system/sw/bin/sleep "$tmp/bin/sleep"
ln -sf /run/current-system/sw/bin/grep "$tmp/bin/grep"
ln -sf /run/current-system/sw/bin/sed "$tmp/bin/sed"
ln -sf /run/current-system/sw/bin/sleep "$tmp/bin-nojq/sleep"
ln -sf /run/current-system/sw/bin/grep "$tmp/bin-nojq/grep"
ln -sf /run/current-system/sw/bin/sed "$tmp/bin-nojq/sed"
if [ -x /run/current-system/sw/bin/jq ]; then
    ln -sf /run/current-system/sw/bin/jq "$tmp/bin/jq"
fi
# bin-nojq deliberately has no jq, to exercise the grep/sed fallback branch.

# Fake hyprctl: prints whatever JSON the test case supplies via $FAKE_JSON.
for dir in "$tmp/bin" "$tmp/bin-nojq"; do
    cat > "$dir/hyprctl" <<'EOF'
#!/run/current-system/sw/bin/bash
[ "$1" = "getoption" ] && echo "$FAKE_JSON"
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

echo
if [ "$fails" -eq 0 ]; then
    echo "All hyprlock-resume-relock check_option tests passed."
else
    echo "$fails hyprlock-resume-relock check_option test(s) FAILED."
fi
exit "$fails"
