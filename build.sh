#!/bin/bash
# Builds MicPatch.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf MicPatch.app
mkdir -p MicPatch.app/Contents/MacOS MicPatch.app/Contents/Resources
swiftc -O -o MicPatch.app/Contents/MacOS/MicPatch MicPatch.swift
cp Info.plist MicPatch.app/Contents/
cp menubar-bg.png MicPatch.app/Contents/Resources/
codesign --force --sign - MicPatch.app
