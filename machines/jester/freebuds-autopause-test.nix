{ runCommand, python3 }:

# Hermetic test of freebuds-autopause.py: fake socket and poll, no
# Bluetooth. See freebuds-autopause-test.py for the cases.
runCommand "freebuds-autopause-test"
  {
    nativeBuildInputs = [ python3 ];
  }
  ''
    cp ${./freebuds-autopause.py} freebuds-autopause.py
    cp ${./freebuds-autopause-test.py} freebuds-autopause-test.py
    python3 freebuds-autopause-test.py
    touch $out
  ''
