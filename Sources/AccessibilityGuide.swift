import AppKit
import ApplicationServices
import SwiftUI

/// A passive companion to the Accessibility page. Only `show()` starts observation;
/// neither displaying nor following the guide requests or changes a permission.
@MainActor final class AccessibilityGuide: NSObject {
    static let shared = AccessibilityGuide()

    private static let settingsBundleIdentifier = "com.apple.systempreferences"
    private static let panelSize = NSSize(width: 310, height: 190)
    private let applicationURL = Bundle.main.bundleURL
    private let state = AccessibilityGuideState()
    private var panel: AccessibilityGuidePanel?
    private var timer: Timer?

    private override init() { super.init() }

    func show() {
        if panel == nil {
            let panel = AccessibilityGuidePanel(
                contentRect: NSRect(origin: .zero, size: Self.panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "开启一键转发"
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
                state: state,
                appName: applicationURL.deletingPathExtension().lastPathComponent,
                close: { [weak self] in self?.close() },
                locateApp: { [weak self] in self?.locateApp() },
                returnToApp: { [weak self] in self?.returnToApp() }
            ))
            self.panel = panel

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
        let trusted = AXIsProcessTrusted()
        if state.trusted != trusted { state.trusted = trusted }

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

@MainActor private final class AccessibilityGuideState: ObservableObject {
    @Published var trusted = false
}

private struct AccessibilityGuideView: View {
    @ObservedObject var state: AccessibilityGuideState
    let appName: String
    let close: () -> Void
    let locateApp: () -> Void
    let returnToApp: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 28, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("开启一键转发").font(.system(size: 16, weight: .semibold))
                    Text(state.trusted ? "辅助功能权限已生效" : "在「辅助功能」中完成以下两步")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.86))
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
            if state.trusted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 23))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已允许").font(.system(size: 15, weight: .semibold))
                        Text("现在可以使用一键转发。")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button(action: returnToApp) {
                    Text("返回应用").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.05, green: 0.25, blue: 0.55))
                        .frame(maxWidth: .infinity).frame(height: 29)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    step(1, "点击 +，选择 \(appName)")
                    step(2, "打开 \(appName) 右侧开关")
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Label("等待你打开开关", systemImage: "circle.dotted")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.86))
                    Spacer(minLength: 0)
                    Button(action: locateApp) {
                        Text("定位应用").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("在访达中显示当前应用，也可将它拖入辅助功能列表。")
                }
            }
        }
        .padding(16)
        .frame(width: 310, height: 190, alignment: .topLeading)
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
