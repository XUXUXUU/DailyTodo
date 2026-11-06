#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH=arm64 BUILD_DIR=build-arm64 scripts/build.sh
ARCH=x86_64 BUILD_DIR=build-x86_64 scripts/build.sh
mkdir -p build
ditto build-arm64/DailyTodo.app build/DailyTodo.app
for executable in MacOS/DailyTodo Resources/DailyTodoReminderAgent; do
    lipo -create "build-arm64/DailyTodo.app/Contents/$executable" \
        "build-x86_64/DailyTodo.app/Contents/$executable" \
        -output "build/DailyTodo.app/Contents/$executable"
done
codesign --force --sign - build/DailyTodo.app/Contents/Resources/DailyTodoReminderAgent
codesign --force --sign - build/DailyTodo.app
codesign --verify --deep --strict build/DailyTodo.app
lipo -info build/DailyTodo.app/Contents/MacOS/DailyTodo
