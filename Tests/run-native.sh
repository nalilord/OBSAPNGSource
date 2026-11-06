#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/native-tests
fpc -B -Mdelphi -FuSource -FU.build/native-tests -FE.build/native-tests -O3 -Cr -Co Tests/DecodeProbe.dpr
node Tests/test-decoder.cjs "$(pwd)/.build/native-tests/DecodeProbe" .build/native-tests/fixtures
fpc -B -Mdelphi -FuSource -FU.build/native-tests -FE.build/native-tests -O3 Tests/DecodeBenchmark.dpr
.build/native-tests/DecodeBenchmark .build/native-tests/fixtures/large-animation.apng
