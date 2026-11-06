#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Sources/WheelMotion.swift Tests/WheelMotionTests.swift -o build/WheelMotionTests
build/WheelMotionTests
python3 - <<'PY'
from pathlib import Path
source = Path("Sources/TimeWheel.swift").read_text()
body = source[source.index("final class WheelControl:"):source.index("/// The onboarding sheet")]
Path("build/WheelControlOnly.swift").write_text("import AppKit\n" + body)
PY
swiftc -parse-as-library Sources/WheelMotion.swift build/WheelControlOnly.swift Tests/WheelControlTests.swift -o build/WheelControlTests
build/WheelControlTests
