#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Sources/FeishuAutomationPolicy.swift Tests/FeishuAutomationTests.swift -o build/FeishuAutomationTests
build/FeishuAutomationTests
