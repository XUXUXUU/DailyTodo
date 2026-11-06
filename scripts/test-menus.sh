#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Sources/MenuLocalization.swift Tests/MenuLocalizationTests.swift -o build/MenuTests
build/MenuTests
