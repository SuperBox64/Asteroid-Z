#!/bin/bash
# Android APK (EXPERIMENTAL): SDL3 android-project template + our sources
# cross-compiled to aarch64-linux-android via the Swift Android SDK.
# The template supplies SDLActivity (Java) + gradle; our code becomes
# libmain.so with SDL_main as the entry. Fails soft until proven on CI.
set -euo pipefail
echo "android lane: template assembly pending first CI run - see release/README.md"
exit 1
