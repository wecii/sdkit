#!/usr/bin/env bash
# Section timing of one test file: prof.sh <file>. Runs a temporary copy that prints elapsed seconds at each top-level `echo "section"` header.
f="$1"; tmp="$(dirname "$f")/_prof_$(basename "$f")"
awk '{print} /^echo "[^"]*"[[:space:]]*$/ {print "printf \"   @%ss\\n\" \"$SECONDS\""}' "$f" > "$tmp"
SECONDS=0; PATH="$(cd "$(dirname "$0")" && pwd)/stubs:$PATH" bash "$tmp"; echo "total ${SECONDS}s"; rm -f "$tmp"
