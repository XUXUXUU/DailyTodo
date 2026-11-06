import AppKit
import SwiftUI

struct ShortcutSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EditorShortcuts
    @State private var recording: EditorAction?
    @State private var issue: String?
    @State private var confirmReset = false
    let apply: (EditorShortcuts) throws -> Void

    init(shortcuts: EditorShortcuts, apply: @escaping (EditorShortcuts) throws -> Void) {
        _draft = State(initialValue: shortcuts)
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑快捷键").font(.title2.weight(.semibold))
            VStack(spacing: 0) {
                row(.newline, key: draft.newline)
                Divider()
                row(.next, key: draft.next)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            Text("Shift + Tab 返回上一栏。字母和数字按 ANSI 物理键位显示。macOS 处理 ⌘Tab 等系统组合。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("恢复默认") {
                    cancelRecording()
                    confirmReset = true
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("完成") {
                    do { try apply(draft); dismiss() }
                    catch { issue = "快捷键保存失败，请重试。" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recording != nil || !draft.isValid)
            }
            if recording == nil, let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }
        .padding(22)
        .frame(width: 470)
        .background(alignment: .topLeading) {
            ShortcutRecorder(active: recording != nil, receive: receive, cancel: cancelRecording)
                .frame(width: 1, height: 1)
        }
        .alert("恢复默认快捷键？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认") { draft = .standard; cancelRecording() }
        } message: {
            Text("换行恢复为 Enter，下一栏恢复为 Tab。点「完成」后应用。")
        }
    }

    private func row(_ action: EditorAction, key: EditorKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(action.title).fontWeight(.medium)
                Spacer()
                Text(key.label).font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("\(action.title)，\(key.accessibleLabel)")
                Button(recording == action ? "停止录制" : "修改") {
                    if recording == action { cancelRecording() }
                    else { issue = nil; recording = action }
                }
                .accessibilityLabel(recording == action ? "停止录制\(action.title)" : "修改\(action.title)")
            }
            if recording == action {
                Text("请按下新快捷键 · Esc 取消").font(.caption).foregroundStyle(Color.accentColor)
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(12)
        .background(recording == action ? Color.accentColor.opacity(0.10) : .clear)
    }

    private func receive(_ event: NSEvent) {
        guard let recording else { return }
        if event.keyCode == 53 { cancelRecording(); return }
        guard !event.isARepeat else { return }
        let key = EditorKey(event)
        if let problem = draft.issue(with: key, for: recording) { issue = problem; return }
        if recording == .newline { draft.newline = key } else { draft.next = key }
        cancelRecording()
    }

    private func cancelRecording() {
        recording = nil
        issue = nil
    }
}

/// A local monitor exists only while this sheet is recording in the key window.
/// It receives app key equivalents before menu dispatch. System keys that macOS
/// consumes outside the app remain in the system's control.
private struct ShortcutRecorder: NSViewRepresentable {
    var active: Bool
    var receive: (NSEvent) -> Void
    var cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CaptureView { CaptureView() }
    func updateNSView(_ view: CaptureView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if active {
            DispatchQueue.main.async { [weak view, weak coordinator] in
                if let view, let coordinator, coordinator.parent.active { coordinator.start(view) }
            }
        } else {
            coordinator.stop(restoreFocus: true)
        }
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: Coordinator) { coordinator.stop() }

    final class CaptureView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    final class Coordinator {
        var parent: ShortcutRecorder
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private weak var capture: CaptureView?
        private weak var oldResponder: NSResponder?

        init(_ parent: ShortcutRecorder) { self.parent = parent }

        func start(_ view: CaptureView) {
            guard monitor == nil, let window = view.window, window.isKeyWindow else { return }
            oldResponder = window.firstResponder
            guard window.makeFirstResponder(view) else { parent.cancel(); return }
            capture = view
            let cancelOnDeactivation: (Notification) -> Void = { [weak self] _ in
                self?.stop(restoreFocus: true)
                self?.parent.cancel()
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: cancelOnDeactivation),
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: cancelOnDeactivation),
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak window] notification in
                    if (notification.object as? NSWindow) !== window { cancelOnDeactivation(notification) }
                }
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, let window, window.isKeyWindow, self.parent.active else { return event }
                guard event.window == nil || event.window === window else { return event }
                self.parent.receive(event)
                return nil
            }
        }

        func stop(restoreFocus: Bool = false) {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            if restoreFocus, let capture, let window = capture.window, window.firstResponder === capture {
                window.makeFirstResponder(oldResponder)
            }
            capture = nil
            oldResponder = nil
        }
    }
}
