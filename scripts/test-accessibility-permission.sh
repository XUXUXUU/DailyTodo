#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Sources/AccessibilityPermissionPolicy.swift Tests/AccessibilityPermissionTests.swift -o build/AccessibilityPermissionTests
build/AccessibilityPermissionTests
