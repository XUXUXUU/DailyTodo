#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Sources/Core.swift Sources/CopyMessages.swift Sources/CleanReset.swift Tests/main.swift -o build/CoreTests
build/CoreTests
