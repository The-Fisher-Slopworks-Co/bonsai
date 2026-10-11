#!/bin/bash
cd "$(dirname "$0")/.." && xcodegen generate >/dev/null && \
xcodebuild -scheme Bonsai test "$@" 2>&1 | grep -E 'error:|✘|recorded an issue|Test run|TEST (SUCCEEDED|FAILED)|BUILD FAILED' | grep -v -E 'Connection\]|boringssl' | tail -${TAIL:-40}; exit ${PIPESTATUS[0]}
