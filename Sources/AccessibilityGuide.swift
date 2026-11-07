import AppKit
import ApplicationServices
import SwiftUI

/// A passive companion to the Accessibility page. Only `show()` starts observation;
/// neither displaying nor following the guide requests or changes a permission.
@MainActor final class AccessibilityGuide: NSObject {
    static let shared = AccessibilityGuide()

    private static let settingsBundleIdentifier = "com.apple.systempreferences"
    fileprivate static let panelSize = NSSize(width: 350, height: 300)
    private let applicationURL = Bundle.main.bundleURL
    private let permissions = AccessibilityPermission.shared
    private var panel: AccessibilityGuidePanel?
    private var timer: Timer?

    private override init() { super.init() }

    func show(repair:Bool=false) {
        if repair,panel != nil {close()}
        if panel == nil {
            let panel = AccessibilityGuidePanel(
                contentRect: NSRect(origin: .zero, size: Self.panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "完成辅助功能授权"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentMinSize = Self.panelSize
            panel.contentMaxSize = Self.panelSize
            panel.contentView = AccessibilityGuideHostingView(rootView: AccessibilityGuideView(
                permissions: permissions,
                appName: applicationURL.deletingPathExtension().lastPathComponent,
                close: { [weak self] in self?.close() },
                locateApp: { [weak self] in self?.locateApp() },
                returnToApp: { [weak self] in self?.returnToApp() },
                initialRecovery:repair
            ))
            self.panel = panel
            permissions.startMonitoring()

            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationWillTerminate(_:)),
                name: NSApplication.willTerminateNotification, object: NSApp
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentDidChange(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(environmentDidChange(_:)),
                name: NSWorkspace.didActivateApplicationNotification, object: nil
            )
            let timer = Timer(timeInterval: 0.5, target: self,
                              selector: #selector(timerDidFire(_:)), userInfo: nil, repeats: true)
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refresh()
    }

    func close() {
        if panel != nil { permissions.stopMonitoring() }
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    @objc private func applicationWillTerminate(_ notification: Notification) { close() }
    @objc private func environmentDidChange(_ notification: Notification) { refresh() }
    @objc private func timerDidFire(_ timer: Timer) { refresh() }

    private func returnToApp() {
        // Activation is deliberately confined to this explicit button action.
        close()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func locateApp() {
        // Reveal precisely this running bundle, so a test copy cannot be mistaken for the installed app.
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
    }

    private func refresh() {
        guard let panel else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isOwnApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let isSettings = frontmost?.bundleIdentifier == Self.settingsBundleIdentifier
        guard isOwnApp || isSettings else {
            panel.orderOut(nil)
            return
        }
        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else {
            panel.orderOut(nil)
            return
        }
        let activeScreen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? primaryScreen
        let settings = isSettings ? frontmost : NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.settingsBundleIdentifier
        ).first
        let settingsFrame = settings.flatMap {
            settingsWindowFrame(pid: $0.processIdentifier, primaryScreenTop: primaryScreen.frame.maxY)
        }
        let screen = settingsFrame.flatMap { frame in
            screens.max(by: {
                intersectionArea(frame, $0.frame) < intersectionArea(frame, $1.frame)
            }).flatMap { intersectionArea(frame, $0.frame) > 0 ? $0 : nil }
        } ?? activeScreen
        let frame = AccessibilityGuidePositioning.frame(
            panelSize: Self.panelSize, settingsFrame: settingsFrame, visibleFrame: screen.visibleFrame
        )
        // No animated following: this also respects Reduce Motion while moving Settings.
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func settingsWindowFrame(pid: pid_t, primaryScreenTop: CGFloat) -> NSRect? {
        // Window metadata only. Never read names, capture pixels, or inspect another app's AX tree.
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        var largestFrame: CGRect?
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 250, frame.height >= 200,
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { continue }
            // Prefer the main Settings window over smaller floating sheets or alerts.
            let largestArea = largestFrame.map { $0.width * $0.height } ?? 0
            if frame.width * frame.height > largestArea {
                largestFrame = frame
            }
        }
        return largestFrame.map {
            AccessibilityGuidePositioning.appKitFrame(fromQuartz: $0, primaryScreenTop: primaryScreenTop)
        }
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

/// Pure geometry helpers so secondary displays and edge placement can be checked separately.
enum AccessibilityGuidePositioning {
    static func appKitFrame(fromQuartz frame: CGRect, primaryScreenTop: CGFloat) -> NSRect {
        // Both systems share the primary display's x origin. Quartz y grows down from
        // its top; AppKit y grows up, including on displays above or below that display.
        NSRect(x: frame.minX, y: primaryScreenTop - frame.maxY,
               width: frame.width, height: frame.height)
    }

    static func frame(panelSize: NSSize, settingsFrame: NSRect?, visibleFrame: NSRect) -> NSRect {
        let inset = visibleFrame.insetBy(dx: 8, dy: 8)
        let safeFrame = inset.width >= panelSize.width && inset.height >= panelSize.height
            ? inset : visibleFrame
        var origin = NSPoint(x: safeFrame.maxX - panelSize.width - 10, y: safeFrame.minY + 10)
        if let settingsFrame {
            let below = settingsFrame.minY - 10 - panelSize.height
            if below >= safeFrame.minY {
                origin = NSPoint(x: settingsFrame.maxX - panelSize.width, y: below)
            } else {
                origin = NSPoint(x: settingsFrame.maxX - panelSize.width - 14,
                                 y: settingsFrame.minY + 14)
            }
        }
        origin.x = min(max(origin.x, safeFrame.minX), max(safeFrame.minX, safeFrame.maxX - panelSize.width))
        origin.y = min(max(origin.y, safeFrame.minY), max(safeFrame.minY, safeFrame.maxY - panelSize.height))
        return NSRect(origin: origin, size: panelSize)
    }
}

@MainActor private final class AccessibilityGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private struct AccessibilityGuideView: View {
    @ObservedObject var permissions: AccessibilityPermission
    let appName: String
    let close: () -> Void
    let locateApp: () -> Void
    let returnToApp: () -> Void
    let initialRecovery:Bool
    @State private var showingRecovery = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 28, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("完成辅助功能授权").font(.system(size: 16, weight: .semibold))
                    Text(statusDescription)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.86))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.14), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭权限引导")
                .help("关闭权限引导")
            }
            .fixedSize(horizontal: false, vertical: true)
            // Keep the status and check controls visible even if recovery text wraps.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    guidance
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            checkControls
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: AccessibilityGuide.panelSize.width,
               height: AccessibilityGuide.panelSize.height, alignment: .topLeading)
        .foregroundStyle(.white)
        .background {
            ZStack {
                if !reduceTransparency { AccessibilityGuideGlass() }
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.41, blue: 0.78),
                             Color(red: 0.04, green: 0.24, blue: 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ).opacity(reduceTransparency ? 1 : 0.91)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .transaction { $0.animation = nil }
        .onAppear {showingRecovery=initialRecovery}
    }

    private var statusDescription: String {
        switch permissions.status {
        case .checking: return "正在检测当前应用的授权状态"
        case .notGranted: return "当前版本尚未获得辅助功能授权"
        case .restartRequired: return "授权已保存，重启后生效"
        case .allowed: return "已允许当前应用"
        }
    }

    @ViewBuilder private var guidance: some View {
        if permissions.status == .allowed {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 23))
                Text("返回应用，继续设置转发方式。")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
            }
            .accessibilityElement(children: .combine)
            primaryButton("返回继续设置", action: returnToApp)
        } else if showingRecovery {
            VStack(alignment: .leading, spacing: 7) {
                step(1, "选中旧的同名条目，点击 − 移除")
                step(2, "点击 +，添加当前的 \(appName)")
                step(3, "打开开关，再重启以重新检测授权")
            }
            recoveryControls
        } else if permissions.status == .restartRequired {
            Text("当前应用需要重启。重启后会自动返回设置，继续完成转发配置。")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            primaryButton("重启并继续设置") { permissions.restart() }
            recoveryControls
        } else {
            VStack(alignment: .leading, spacing: 9) {
                step(1, "找到 \(appName)，未列出则点 + 添加")
                step(2, "打开 \(appName) 右侧开关")
            }
            recoveryControls
        }
    }

    private var recoveryControls: some View {
        HStack(spacing: 8) {
            Button(showingRecovery ? recoveryReturnTitle : "开关已开但无效") {
                showingRecovery.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .help(showingRecovery ? recoveryReturnTitle : "查看移除旧条目、重新添加当前应用的步骤")
            Spacer(minLength: 0)
            Button(action: locateApp) {
                Text("定位应用").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("在访达中显示当前正在运行的应用，将它添加到辅助功能列表。")
            if showingRecovery {
                Button { permissions.restart() } label: {
                    Text("重启并继续设置").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.05, green: 0.25, blue: 0.55))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(.white, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(permissions.status == .checking)
                .help("先完成重新添加和开启步骤；重启后会重新检测权限，并返回设置。")
            }
        }
    }

    private var checkControls: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let error = permissions.error {
                    Text(error).lineLimit(1).truncationMode(.tail).help(error)
                } else {
                    Text(checkResult)
                }
                if let lastCheck = permissions.lastCheck {
                    Text("上次检测 \(lastCheck.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.72))
                }
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button {
                Task { await permissions.refresh() }
            } label: {
                HStack(spacing: 5) {
                    if permissions.isChecking {
                        ProgressView().controlSize(.mini).tint(.white)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(permissions.isChecking ? "检测中" : "重新检测")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 28)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(permissions.isChecking)
            .help("重新检查当前应用的辅助功能授权，不会修改系统权限。")
        }
    }

    private var recoveryReturnTitle: String {
        permissions.status == .restartRequired ? "返回重启提示" : "返回授权步骤"
    }

    private var checkResult: String {
        switch permissions.status {
        case .checking: return "正在检测授权"
        case .notGranted: return "检测结果：当前版本未获授权"
        case .restartRequired: return "检测结果：需要重启应用"
        case .allowed: return "检测结果：当前应用已获授权"
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.05, green: 0.25, blue: 0.55))
                .frame(maxWidth: .infinity).frame(height: 29)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 9) {
            Text(String(number)).font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.17), in: Circle())
            Text(text).font(.system(size: 12, weight: .medium))
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true).help(text)
        }.accessibilityElement(children: .combine)
    }
}

private struct AccessibilityGuideGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

@MainActor private final class AccessibilityGuideHostingView: NSHostingView<AccessibilityGuideView> {
    // A nonactivating guide's controls should work on the first click without taking focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
