#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Sources/Shortcuts.swift Tests/ShortcutTests.swift -o build/ShortcutTests
build/ShortcutTests
