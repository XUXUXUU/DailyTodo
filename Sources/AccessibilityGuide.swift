import AppKit
import ApplicationServices
import SwiftUI

/// A passive companion to the Accessibility page. Only `show()` starts observation;
/// neither displaying nor following the guide requests or changes a permission.
@MainActor final class AccessibilityGuide: NSObject {
    static let shared = AccessibilityGuide()

    private static let settingsBundleIdentifier = "com.apple.systempreferences"
    fileprivate static let panelSize = NSSize(width: 428, height: 148)
    private let applicationURL = Bundle.main.bundleURL
    private let permissions = AccessibilityPermission.shared
    private var panel: AccessibilityGuidePanel?
    private var timer: Timer?
    private var continuation=AccessibilityGuideContinuation()

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
                close: { [weak self] in self?.close() },
                locateApp: { [weak self] in self?.locateApp() },
                initialRecovery:repair
            ))
            self.panel = panel
            continuation.begin()
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
        continuation.cancel()
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

    private func finishAuthorization(_ action:AccessibilityGuideContinuation.Action,origin:String?) {
        close()
        if action == .returnToApp {NSApp.activate(ignoringOtherApps:true)}
        Task { @MainActor in
            try? await Task.sleep(nanoseconds:200_000_000)
            Runtime.report("accessibility-guide-completion",payload:[
                "action":action == .returnToApp ? "return-to-app" : "close-quietly",
                "origin":origin ?? "unknown",
                "appActive":NSApp.isActive,
                "helperOpen":panel != nil,
                "frontmost":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            ])
        }
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
        let completion=continuation.take(ready:permissions.ready,setupOwnsFocus:isOwnApp || isSettings)
        if completion != .none {
            finishAuthorization(completion,origin:frontmost?.bundleIdentifier)
            return
        }
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
        guard let frame = AccessibilityGuidePositioning.frame(
            panelSize: Self.panelSize, settingsFrame: settingsFrame, visibleFrame: screen.visibleFrame
        ) else {panel.orderOut(nil);return}
        // No animated following: this also respects Reduce Motion while moving Settings.
        if panel.frame != frame {
            panel.setFrame(frame,display:true,animate:false)
            Runtime.report("accessibility-guide-frame",payload:[
                "guide":[frame.minX,frame.minY,frame.width,frame.height],
                "settings":settingsFrame.map {[$0.minX,$0.minY,$0.width,$0.height]} ?? [],
                "overlap":settingsFrame.map {$0.intersects(frame)} ?? false
            ])
        }
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

    static func frame(panelSize:NSSize,settingsFrame:NSRect?,visibleFrame:NSRect)->NSRect? {
        guard let settingsFrame else {return nil}
        let safe=visibleFrame.insetBy(dx:8,dy:8)
        guard safe.width>=panelSize.width,safe.height>=panelSize.height else {return nil}
        let gap:CGFloat=10
        let x=min(max(settingsFrame.midX-panelSize.width/2,safe.minX),safe.maxX-panelSize.width)
        let y=min(max(settingsFrame.minY,safe.minY),safe.maxY-panelSize.height)
        let candidates=[
            NSRect(x:x,y:settingsFrame.minY-gap-panelSize.height,width:panelSize.width,height:panelSize.height),
            NSRect(x:settingsFrame.maxX+gap,y:y,width:panelSize.width,height:panelSize.height),
            NSRect(x:settingsFrame.minX-gap-panelSize.width,y:y,width:panelSize.width,height:panelSize.height),
            NSRect(x:x,y:settingsFrame.maxY+gap,width:panelSize.width,height:panelSize.height)
        ]
        return candidates.first {safe.contains($0) && !settingsFrame.intersects($0)}
    }

}

@MainActor private final class AccessibilityGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private struct AccessibilityGuideView:View {
    @ObservedObject var permissions:AccessibilityPermission
    let close:()->Void
    let locateApp:()->Void
    let initialRecovery:Bool
    @State private var showingRecovery=false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(showingRecovery ? "先移除旧项，再拖入图标" : "拖入 Daily Todo，打开开关")
                    .font(.system(size:16,weight:.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength:4)
                Button(action:close) {
                    Image(systemName:"xmark").font(.system(size:10,weight:.bold))
                        .frame(width:24,height:24).background(.white.opacity(0.14),in:Circle())
                }.buttonStyle(.plain).accessibilityLabel("关闭权限引导")
            }
            HStack(spacing:14) {
                AccessibilityAppDragIcon(size:44)
                Image(systemName:"arrow.right").font(.system(size:17,weight:.medium)).opacity(0.8)
                HStack(spacing:10) {
                    Image(systemName:"list.bullet.rectangle").font(.system(size:28))
                    Image(systemName:"switch.2").font(.system(size:24))
                }.frame(width:116,height:42)
                    .background(.white.opacity(0.10),in:RoundedRectangle(cornerRadius:9))
                    .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(.white.opacity(0.25),style:StrokeStyle(lineWidth:1,dash:[3])))
                    .accessibilityLabel("拖入上方辅助功能列表并开启")
                Spacer(minLength:4)
                RevealCurrentAppButton(action:locateApp)
            }
            HStack(spacing:8) {
                Button(showingRecovery ? "返回" : "未能成功？") {showingRecovery.toggle()}
                    .font(.system(size:11)).buttonStyle(.plain)
                Spacer(minLength:4)
                if permissions.status == .restartRequired {
                    guideButton("重启继续") {permissions.restart()}
                } else if !permissions.ready {
                    guideButton("重新检测") {Task {await permissions.refresh(userInitiated:true)}}
                        .disabled(permissions.isChecking)
                }
            }.frame(height:30)
        }
        .padding(14)
        .frame(width:AccessibilityGuide.panelSize.width,height:AccessibilityGuide.panelSize.height)
        .foregroundStyle(.white)
        .background {
            ZStack {
                if !reduceTransparency {AccessibilityGuideGlass()}
                LinearGradient(colors:[Color(red:0.10,green:0.41,blue:0.78),Color(red:0.04,green:0.24,blue:0.55)],startPoint:.topLeading,endPoint:.bottomTrailing)
                    .opacity(reduceTransparency ? 1 : 0.92)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius:15))
        .overlay(RoundedRectangle(cornerRadius:15).strokeBorder(.white.opacity(0.3)))
        .transaction {$0.animation=nil}
        .onAppear {showingRecovery=initialRecovery}
    }
    private func guideButton(_ title:String,action:@escaping ()->Void)->some View {
        Button(action:action) {
            Text(title).font(.system(size:12,weight:.semibold)).padding(.horizontal,12).frame(height:30)
                .background(.white.opacity(0.18),in:RoundedRectangle(cornerRadius:8))
        }.buttonStyle(.plain)
    }
}

struct RevealCurrentAppButton:View {
    let action:()->Void
    @State private var hovered=false
    private let ink=Color(red:0.04,green:0.25,blue:0.55)
    var body:some View {
        Button(action:action) {
            Label("在访达中显示",systemImage:"folder")
                .font(.system(size:12,weight:.semibold)).foregroundStyle(ink)
                .padding(.horizontal,10).frame(height:32)
                .background(.white.opacity(hovered ? 1 : 0.93),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(.white.opacity(0.6)))
                .shadow(color:.black.opacity(0.10),radius:3,y:1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover {hovered=$0}
        .help("在访达中选中当前正在运行的 Daily Todo 应用")
    }
}

struct AccessibilityAppDragIcon:View {
    let size:CGFloat
    var body:some View {
        Image(nsImage:NSWorkspace.shared.icon(forFile:Bundle.main.bundlePath))
            .resizable().scaledToFit().frame(width:size,height:size)
            .onDrag {
                Runtime.event("accessibility-app-drag-started")
                return NSItemProvider(object:Bundle.main.bundleURL as NSURL)
            }
            .accessibilityLabel("拖拽当前 Daily Todo 应用图标")
            .help("把此图标拖入系统辅助功能列表")
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
