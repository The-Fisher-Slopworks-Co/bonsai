#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

step_format() { xcrun swift-format lint --strict --parallel --recursive Bonsai BonsaiTests tools/icon; }
step_unused() { xcodegen generate >/dev/null && periphery scan; }
step_reuse() { uvx --from 'reuse[charset-normalizer]' reuse lint --quiet; }
step_test() { tools/test.sh; }

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(format unused reuse test)
for step in "${steps[@]}"; do
    echo "==> $step"
    "step_$step"
done
