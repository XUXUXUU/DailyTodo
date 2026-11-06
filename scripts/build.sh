#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bootstrap-sparkle.sh
BUILD_DIR="${BUILD_DIR:-build}"
ARCH="${ARCH:-$(uname -m)}"
SWIFT_FLAGS=(-swift-version 5)
if [[ "${INTEGRATION_BUILD:-0}" == "1" ]]; then SWIFT_FLAGS+=(-D INTEGRATION_TESTING); fi
mkdir -p "$BUILD_DIR/DailyTodo.app/Contents/"{MacOS,Resources,Library/LaunchAgents}
swiftc "${SWIFT_FLAGS[@]}" -F Vendor/Sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -O -parse-as-library -target "$ARCH-apple-macosx13.0" Sources/*.swift -o "$BUILD_DIR/DailyTodo.app/Contents/MacOS/DailyTodo"
swiftc "${SWIFT_FLAGS[@]}" -O -target "$ARCH-apple-macosx13.0" Sources/Core.swift Sources/OfficialReminder.swift ReminderAgent/main.swift -o "$BUILD_DIR/DailyTodo.app/Contents/Resources/DailyTodoReminderAgent"
iconutil -c icns Resources/AppIcon.iconset -o "$BUILD_DIR/DailyTodo.app/Contents/Resources/AppIcon.icns"
cp Assets.xcassets/BrandLogo.imageset/BrandLogo.png "$BUILD_DIR/DailyTodo.app/Contents/Resources/BrandLogo.png"
cp Resources/CopyMessages.json "$BUILD_DIR/DailyTodo.app/Contents/Resources/CopyMessages.json"
mkdir -p "$BUILD_DIR/DailyTodo.app/Contents/Frameworks"
ditto Vendor/Sparkle/Sparkle.framework "$BUILD_DIR/DailyTodo.app/Contents/Frameworks/Sparkle.framework"
ditto Resources/zh-Hans.lproj "$BUILD_DIR/DailyTodo.app/Contents/Resources/zh-Hans.lproj"
cp Vendor/Sparkle/LICENSE "$BUILD_DIR/DailyTodo.app/Contents/Resources/Sparkle-LICENSE"
cp Info.plist "$BUILD_DIR/DailyTodo.app/Contents/Info.plist"
if [[ "${INTEGRATION_BUILD:-0}" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.personal.dailytodo.testing" "$BUILD_DIR/DailyTodo.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 dailytodo-reminder-testing" "$BUILD_DIR/DailyTodo.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Daily Todo 测试" "$BUILD_DIR/DailyTodo.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Daily Todo 测试" "$BUILD_DIR/DailyTodo.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :DailyTodoIntegrationBuild bool true" "$BUILD_DIR/DailyTodo.app/Contents/Info.plist"
fi
cp LaunchAgents/*.plist "$BUILD_DIR/DailyTodo.app/Contents/Library/LaunchAgents/"
codesign --force --sign - "$BUILD_DIR/DailyTodo.app/Contents/Resources/DailyTodoReminderAgent"
codesign --force --sign - "$BUILD_DIR/DailyTodo.app"
codesign --verify --deep --strict "$BUILD_DIR/DailyTodo.app"
touch "$BUILD_DIR/DailyTodo.app"
echo "Built: $BUILD_DIR/DailyTodo.app"
