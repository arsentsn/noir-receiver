#!/bin/zsh
# Everything that can be checked without a phone, in one go — run it before a commit:
#   ./check.sh    builds every target, then eq-check, protocol-test.py and preview
#
# Exits non-zero at the first failure. Building the app stops a running copy (see build.sh), so
# this relaunches it at the end if one was running.
set -e
cd ${0:A:h}
running=0
pgrep -f "Noir Receiver.app/Contents/MacOS" >/dev/null && running=1
./build.sh
./build.sh preview
./eq-check
./protocol-test.py
./preview
(( running )) && open "Noir Receiver.app"
print "\ncheck.sh: all passed"
