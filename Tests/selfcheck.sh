#!/bin/sh
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.4 \
  Roomline/Models.swift Roomline/TranscriptStore.swift Roomline/NotesGenerator.swift Roomline/EchoDedup.swift Tests/SelfCheck.swift \
  -o "$out/selfcheck"
"$out/selfcheck"
