#!/bin/bash
# Builds MicPatch, copies it to /Applications, registers it to open at login, and starts it.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
pkill -x MicPatch || true
rm -rf /Applications/MicPatch.app
ditto MicPatch.app /Applications/MicPatch.app
/Applications/MicPatch.app/Contents/MacOS/MicPatch --register-login
open /Applications/MicPatch.app
