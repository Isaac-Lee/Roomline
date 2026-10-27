#!/bin/sh
# usage: Tests/bench/bench.sh <audio> <reference.txt> [locales...]   (기본 en_US en_IN en_GB; --selfcheck 로 WER 검증)
set -e
if [ "$1" != "--selfcheck" ]; then   # cd 전에 파일 경로를 절대경로로
  a=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); r=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2; set -- "$a" "$r" "$@"
fi
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.4 \
  Roomline/Models.swift Roomline/Transcription.swift Roomline/AudioCapture.swift Tests/bench/Bench.swift -o "$out/bench"
"$out/bench" "$@"
