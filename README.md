# Daily Todo

蓝色玻璃主题的原生 macOS 每日工作汇报工具，使用 SwiftUI 与 AppKit 开发。支持 macOS 13 及以上，发布包同时包含 Apple Silicon 和 Intel 架构。

## 下载与更新

从 [GitHub Releases](https://github.com/XUXUXUU/DailyTodo/releases/latest) 下载 DMG，将 DailyTodo 拖入“应用程序”完成首次安装。已有版本低于 1.11 时，也需要先安装一次带更新功能的版本。

之后在应用菜单或“设置 → 数据与工具”点击“检查更新…”，阅读更新内容并确认即可自动安装和重新启动。应用也会定期检查新版本。更新订阅及安装包由 Sparkle 的 Ed25519 签名验证，更新私钥不在仓库中。

当前发布使用 ad-hoc 应用签名，尚未进行 Apple Developer ID 公证。首次打开下载的应用可能需要在 macOS 的隐私与安全性设置中手动允许。Ed25519 更新签名用于验证后续更新来源。

## 功能

- 今日任务、当前进度、卡点三张卡片自由编辑。
- 空闲约三秒自动保存，复制时立即保存。
- Enter 换行，Tab 下一栏，可自定义快捷键并检查冲突。
- 复制成功展示蓝色反馈卡片和随机文案。
- 设置中可启用“发给瑶总”：自动打开飞书并精确查找联系人；默认仅填入草稿，也可显式选择直接发送。未授权辅助功能、联系人不唯一、已有草稿或发送结果无法确认时会停止，正文仍保留在剪贴板。
- 固定周一至周五按设置时分提醒，成功复制后当天免提醒。
- 独立历史快照、跨日继承、系统通知与后台弹窗。
- 中文菜单、原生自动更新及版本说明。

任务保存在本机 `~/Library/Application Support/DailyTodo`。完成状态保存在独立的 `DailyTodo-ReminderState` 目录，升级会继续使用已有数据。访问 GitHub 用于检查和下载更新，应用不上传任务正文。飞书自动化仅通过本机辅助功能操作已安装的飞书；发送去重记录也只保存在本机。

## 飞书自动化

在自动化卡片中设置收件人和发送方式，并通过 macOS“隐私与安全性 → 辅助功能”允许 DailyTodo。新手引导也包含这一入口。设置完成后启用一键转发，主按钮变为“发给瑶总”（自定义联系人时跟随姓名）。已有草稿、重名联系人、无法确认焦点或正文时会停止，正文仍可手动粘贴。

转发期间应用需要操作前台飞书，并会在粘贴前重新写入本次 Todo 到剪贴板，请勿同时复制或切换聊天。“直接发送”会执行飞书的发送操作；客户端不能提供独立服务器送达回执，最终状态以飞书为准，同一目标同日同正文不会自动重发。发送键无法识别时保留草稿交由用户处理。

当前应用使用 ad-hoc 签名。构建更新后 macOS 可能需要重新授权；如果系统列表显示开启、应用仍显示未允许，请移除该条目，重新添加当前应用并重启。应用不会代开或伪造系统权限。

## 本地构建

需要 macOS 及 Xcode Command Line Tools。

```sh
scripts/build.sh
open build/DailyTodo.app
```

首次构建会下载并验证固定版本 Sparkle 2.10.1。依赖不提交到仓库。Xcode 用户先运行 `scripts/bootstrap-sparkle.sh`，再打开 `DailyTodo.xcodeproj`。项目已包含框架链接和嵌入步骤。

`scripts/build-universal.sh` 生成通用发布版本。`scripts/test.sh`、`scripts/test-shortcuts.sh`、`scripts/test-reminders.sh`、`scripts/test-menus.sh`、`scripts/test-wheel-motion.sh`、`scripts/test-feishu.sh` 可运行本地回归。

集成测试使用独立应用标识 `com.personal.dailytodo.testing` 和 `DailyTodoTesting/<UUID>` 数据目录，必须指定有效会话。测试构建关闭自动更新。不要用正式应用标识运行通知调度实验。

## 发布新版本

1. 修改 `Info.plist` 的版本号与递增构建号。
2. 添加 `release-notes/<版本号>.md`，以列表说明更新内容。
3. 提交后推送 `v<版本号>` 标签。

GitHub Actions 会运行测试、构建通用应用、签名更新包、生成 appcast，并发布 ZIP、DMG 和校验和。仓库需要配置 `SPARKLE_EDDSA_PRIVATE_KEY` Actions secret，其对应公钥必须与 Info.plist 中的 `SUPublicEDKey` 一致。

也可以本地执行：

```sh
scripts/build-universal.sh
SPARKLE_PRIVATE_KEY_FILE=/安全位置/ed25519.key python3 scripts/package-release.py
```

更新采用替换目录进行安装。清理本地临时构建时可先归档，再移除临时文件，避免第三方废纸篓卸载工具错误关联正式数据。

## 许可

本项目采用 MIT 许可。Sparkle 的许可及第三方声明见 [第三方依赖说明](THIRD_PARTY_NOTICES.md)。
