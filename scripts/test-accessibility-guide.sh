#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Sources/Runtime.swift Sources/AccessibilityPermissionPolicy.swift Sources/AccessibilityPermission.swift Sources/AccessibilityGuide.swift Tests/AccessibilityGuideTests.swift -o build/AccessibilityGuideTests
build/AccessibilityGuideTests
