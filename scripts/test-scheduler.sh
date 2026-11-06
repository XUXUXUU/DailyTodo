#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Sources/Core.swift Sources/LaunchAgentScheduler.swift Tests/Scheduler/main.swift -o build/SchedulerTests
build/SchedulerTests
