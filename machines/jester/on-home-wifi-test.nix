{ runCommand, writeShellScriptBin, callPackage }:

let
  # Fake nmcli: prints $FAKE_OUT, exits with $FAKE_RC (default 0).
  fakeNmcli = writeShellScriptBin "nmcli" ''
    printf '%s' "''${FAKE_OUT-}"
    exit "''${FAKE_RC:-0}"
  '';
  mk = homeSsids: callPackage ./on-home-wifi.nix { } { inherit homeSsids; nmcli = fakeNmcli; };
  home = mk [ "Happylainen" ];
  none = mk [ ];
in
runCommand "on-home-wifi-test" { } ''
  fail=0
  check() { # want-rc script output [nmcli-rc]
    want=$1 script=$2 fakeout=$3 rc=''${4:-0}
    set +e
    FAKE_OUT=$fakeout FAKE_RC=$rc $script/bin/on-home-wifi
    got=$?
    set -e
    if { [ "$want" = 0 ] && [ "$got" -ne 0 ]; } || { [ "$want" != 0 ] && [ "$got" -eq 0 ]; }; then
      echo "FAIL: want rc=$want got $got for '$fakeout' (nmcli rc $rc)"; fail=1
    fi
  }
  check 0 ${home} $'yes:Happylainen\nno:Other\n'
  check 1 ${home} $'yes:Other\nno:Happylainen\n'
  check 1 ${home} $'yes:Happylainen2\n'
  check 1 ${home} $'yes:xHappylainen\n'
  check 1 ${home} $'yes:Happylainen\n' 1
  check 1 ${home} ""
  check 1 ${none} $'yes:Happylainen\n'
  check 0 ${mk [ "MG:s wifi" ]} $'no:Other\nyes:MG\\:s wifi\n'
  [ "$fail" = 0 ]
  touch $out
''
