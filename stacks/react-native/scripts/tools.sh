#!/usr/bin/env bash
# $1: the repo root (doctor and the check-tools hook pass it; defaults to the git top level)
root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
echo "required|node|install Node.js (see .nvmrc or engines in package.json)"
echo "required|jq|brew install jq (used to read package.json)"
echo "optional|prettier|install it as a devDependency (format-on-edit is skipped without it)"
echo "optional|watchman|brew install watchman (Metro and jest-haste-map file watching)"
# native projects present (bare app or Expo prebuild): device tooling, hints only
[ -d "$root/ios" ] && [ "$(uname -s)" = Darwin ] && echo "optional|xcrun|install Xcode and its command line tools (xcode-select --install) to build and run ios/"
[ -d "$root/android" ] && echo "optional|adb|install Android Studio or the platform-tools and put adb on PATH to run android/"
exit 0
