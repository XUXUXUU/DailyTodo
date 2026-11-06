#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
python3 - <<'PY'
from pathlib import Path
s=Path('Sources/App.swift').read_text().split('@MainActor final class AppDelegate')[0]
Path('build/ModelOnly.swift').write_text(s)
PY
swiftc -D INTEGRATION_TESTING -parse-as-library Sources/Core.swift Sources/Runtime.swift Sources/Shortcuts.swift Sources/StableEditor.swift build/ModelOnly.swift Tests/EditorModelTests.swift -o build/EditorModelTests
EDITOR_TEST_SESSION="$(uuidgen)"
printf '%s\n' "$EDITOR_TEST_SESSION" > build/editor-model-session.txt
build/EditorModelTests --integration-session "$EDITOR_TEST_SESSION"
