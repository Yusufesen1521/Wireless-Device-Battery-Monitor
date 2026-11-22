#!/bin/sh
# Builds the macOS version (experimental) with clang, IOKit and AppKit. Windows uses build.bat, Linux build-linux.sh.
# Everything macOS-only lives in mac/ and src/mac/; the other builds never compile those files.
#   ./build-mac.sh              build BatteryHub.app (menu-bar app) and ./batteryhub (command line)
#   ./build-mac.sh universal    the same, as arm64 + x86_64 universal binaries
#   ./build-mac.sh test         run the shared JSON output test
#   ./build-mac.sh clean        remove the macOS build output
set -e
cd "$(dirname "$0")"
exec make -f mac/Makefile.mac -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" "$@"
