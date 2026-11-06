#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Sources/Core.swift Sources/OfficialReminder.swift Tests/ReminderTests.swift -o build/ReminderTests
build/ReminderTests
