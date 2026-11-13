{ lib, writeShellApplication, writeText, gnugrep, networkmanager }:

# Exit 0 iff the active wifi SSID is in homeSsids; non-zero in every other
# case (nmcli missing or failing, no wifi, empty output, empty list), so
# failure falls toward the strict not-home behaviour. nmcli is a parameter so
# the test can pass a fake.
{ homeSsids, nmcli ? networkmanager }:
let
  # One "yes:<ssid>" line per home SSID; an empty file matches nothing.
  # nmcli -t escapes ':' and '\' in values, so the patterns do too.
  escape = lib.replaceStrings [ "\\" ":" ] [ "\\\\" "\\:" ];
  patterns = writeText "home-ssids" (lib.concatMapStrings (s: "yes:${escape s}\n") homeSsids);
in
writeShellApplication {
  name = "on-home-wifi";
  runtimeInputs = [ nmcli gnugrep ];
  # No grep -q: it exits at the first match, nmcli then dies on SIGPIPE and
  # pipefail turns a home match into a failure.
  text = ''
    nmcli -t -f active,ssid dev wifi | grep -xF -f ${patterns} >/dev/null
  '';
}
