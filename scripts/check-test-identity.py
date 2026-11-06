#!/usr/bin/env python3
"""Reject a notification test bundle that shares the production application ID."""
import plistlib
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
if info.get("DailyTodoIntegrationBuild") is not True or info.get("CFBundleIdentifier") != "com.personal.dailytodo.testing":
    raise SystemExit("拒绝共享正式应用标识的测试构建")
print("PASS: test notification identity is separate from production")
