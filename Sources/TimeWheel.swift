import SwiftUI
import AppKit

struct TimeWheel: NSViewRepresentable {
    @Binding var value: Int
    let maximum: Int
    let label: String
    var onEscape: (() -> Void)? = nil
    var allowsPreciseInput = true
    let presetRevision: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context:Context) -> WheelControl {
        let view = WheelControl(); view.maximum = maximum; view.setAccessibilityLabel(label); view.input.setAccessibilityLabel(label + "精确输入")
        view.allowsPreciseInput = allowsPreciseInput
        if !allowsPreciseInput {
            view.input.isEditable = false
            view.input.isSelectable = false
            view.input.refusesFirstResponder = true
            view.input.setAccessibilityElement(false)
            view.setAccessibilityRole(.incrementor)
            view.toolTip = "滚动或使用上下方向键调整"
        }
        view.changed = { value = $0 }; view.escape = onEscape; return view
    }
    func updateNSView(_ view:WheelControl,context:Context) {
        view.maximum = maximum
        view.reduceMotion = reduceMotion || Runtime.reduceMotionOverride
        view.updateFromBinding(value, presetRevision:presetRevision)
        view.changed = { value = $0 }; view.escape = onEscape
    }
}
final class WheelControl: NSView, NSTextFieldDelegate {
    let input = NSTextField()
    var value = 0
    var maximum = 59
    var changed: ((Int)->Void)?
    var escape: (() ->Void)?
    var allowsPreciseInput = true
    private var motion = WheelMotion()
    private var visualOffset: CGFloat = 0
    private var settleTask: Task<Void,Never>?
    private var ignoreMomentum = false
    private var lastPresetRevision: Int?
    var reduceMotion = false {
        didSet {
            if reduceMotion && !oldValue { settleImmediately() }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { settleImmediately() }
    }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width:125,height:172) }
    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        toolTip = "滚动或使用上下方向键调整，点击选中数字直接输入"
        input.isBezeled=false;input.drawsBackground=false;input.alignment = .center
        input.font = .monospacedDigitSystemFont(ofSize:50,weight:.semibold)
        input.textColor = .labelColor;input.delegate=self;input.usesSingleLineMode=true
        addSubview(input);syncInput()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func becomeFirstResponder() -> Bool { needsDisplay=true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay=true; return true }
    override func layout() {
        super.layout(); input.frame=NSRect(x:3,y:bounds.midY-31,width:bounds.width-6,height:62)
    }
    func syncInput() {
        let formatted = String(format:"%02d",value)
        if let editor = input.currentEditor() as? NSTextView {
            guard editor.string != formatted else { return }
            editor.string = formatted
            editor.selectAll(nil)
        } else if input.stringValue != formatted {
            input.stringValue = formatted
        }
    }
    func updateFromBinding(_ number:Int, presetRevision:Int) {
        let initial = lastPresetRevision == nil
        let selectedPreset = lastPresetRevision != presetRevision && !initial
        lastPresetRevision = presetRevision
        guard value != number || selectedPreset else { return }
        let old = value
        settleImmediately()
        value = number
        syncInput()
        if !initial, old != number, input.currentEditor() == nil {
            // Align the new value in one short transition even for distant presets.
            animateSnap(from:number > old ? -0.38 : 0.38)
        }
    }
    func controlTextDidChange(_ notification:Notification) {
        if let number=Int(input.stringValue),(0...maximum).contains(number) { settleImmediately();value=number;changed?(number);needsDisplay=true }
    }
    func controlTextDidEndEditing(_ notification:Notification) { input.stringValue=String(format:"%02d",value) }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector) -> Bool {
        if selector == #selector(NSResponder.moveUp(_:)) { change(-1);input.stringValue=String(format:"%02d",value);return true }
        if selector == #selector(NSResponder.moveDown(_:)) { change(1);input.stringValue=String(format:"%02d",value);return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { escape?();return true }
        return false
    }
    override func draw(_ dirtyRect:NSRect) {
        let highlight = NSRect(x:3,y:bounds.midY-31,width:bounds.width-6,height:62)
        NSColor.systemBlue.withAlphaComponent(0.13).setFill()
        let card = NSBezierPath(roundedRect:highlight,xRadius:15,yRadius:15); card.fill()
        NSColor.systemBlue.withAlphaComponent(window?.firstResponder === self ? 0.8 : 0.25).setStroke(); card.lineWidth = 1; card.stroke()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect:bounds).addClip()
        for row in -2...2 {
            if row == 0 && !input.isHidden { continue }
            let position = CGFloat(row) - visualOffset
            let proximity = max(0, 1 - abs(position))
            let visibility = max(0, 1 - max(0, abs(position) - 1) * 1.5)
            let number = WheelMotion.wrap(value + row,maximum:maximum)
            let color = NSColor.labelColor.withAlphaComponent((0.58 + 0.42 * proximity) * visibility)
            let text = String(format:"%02d",number) as NSString
            let font = NSFont.monospacedDigitSystemFont(ofSize:24 + 26 * proximity,weight:proximity > 0.5 ? .semibold : .regular)
            let attributes:[NSAttributedString.Key:Any] = [.font:font,.foregroundColor:color]
            let measured = text.size(withAttributes:attributes)
            text.draw(at:NSPoint(x:(bounds.width-measured.width)/2,y:bounds.midY-position*48-measured.height/2),
                      withAttributes:attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func setValue(_ number:Int) {
        guard number != value else { return }
        value = number
        syncInput()
        changed?(value)
        needsDisplay = true
        NSAccessibility.post(element:self,notification:.valueChanged)
    }
    private func change(_ difference:Int) {
        settleImmediately()
        guard difference != 0 else { return }
        setValue(WheelMotion.wrap(value + difference,maximum:maximum))
        if input.currentEditor() == nil { animateSnap(from:difference > 0 ? -0.65 : 0.65) }
    }
    private func display(_ offset:CGFloat) {
        visualOffset = offset
        input.isHidden = abs(offset) > 0.001
        needsDisplay = true
    }
    private func settleImmediately() {
        settleTask?.cancel()
        settleTask = nil
        motion.reset()
        ignoreMomentum = true
        display(0)
    }
    private func animateSnap(from offset:CGFloat, delay:UInt64 = 0, resetOnFinish:Bool = false) {
        settleTask?.cancel()
        if reduceMotion {
            display(0)
            return
        }
        display(offset)
        guard abs(offset) > 0.001 else {
            if resetOnFinish { motion.reset() }
            return
        }
        settleTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds:delay) }
            for frame in 1...7 {
                guard !Task.isCancelled, let self else { return }
                let remaining = 1 - CGFloat(frame) / 7
                self.display(offset * remaining * remaining)
                try? await Task.sleep(nanoseconds:16_000_000)
            }
            if resetOnFinish && !Task.isCancelled { self?.motion.reset() }
        }
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        guard let hit=super.hitTest(point) else { return nil }
        return allowsPreciseInput ? hit : self
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow,from:nil)
        if point.y > bounds.midY+28 { change(-1) }
        else if point.y < bounds.midY-28 { change(1) }
        needsDisplay = true
    }
    override func scrollWheel(with event:NSEvent) {
        let delta = -event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            guard delta != 0 else { return }
            let steps = WheelMotion.mouseSteps(for:delta)
            if input.currentEditor() != nil { window?.makeFirstResponder(self) }
            change(steps)
            return
        }

        let coasting = !event.momentumPhase.isEmpty
        if event.phase == .began || event.phase == .mayBegin {
            motion.reset()
            ignoreMomentum = false
        }
        if coasting && (reduceMotion || ignoreMomentum) { return }
        if !coasting && delta != 0 { ignoreMomentum = false }
        if delta != 0 {
            if input.currentEditor() != nil { window?.makeFirstResponder(self) }
            let rows = min(3,max(-3,delta / 34)) * (coasting ? 0.55 : 1)
            let steps = motion.advance(rows,momentum:coasting)
            setValue(WheelMotion.wrap(value + steps,maximum:maximum))
        }
        let ended = event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended
        let unphased = event.phase.isEmpty && !coasting
        if ended || unphased {
            animateSnap(from:CGFloat(motion.offset),delay:ended ? 32_000_000 : 70_000_000,
                        resetOnFinish:unphased)
        } else {
            // Keep the visual offset under the finger until the gesture ends.
            settleTask?.cancel()
            display(reduceMotion ? 0 : CGFloat(motion.offset))
        }
        if event.momentumPhase == .ended || event.phase == .cancelled {
            motion.reset()
        }
    }
    override func keyDown(with event:NSEvent) {
        switch event.keyCode {
        case 53: escape?()
        case 126: change(-1)
        case 125: change(1)
        case 115: change(-value)
        case 119: change(maximum-value)
        default: super.keyDown(with:event)
        }
    }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { maximum }
    override func accessibilityPerformIncrement() -> Bool { change(1); return true }
    override func accessibilityPerformDecrement() -> Bool { change(-1); return true }
}

/// The onboarding sheet and Settings sheet share the controls, not their save flow.
struct ReminderTimePicker: View {
    @Binding var time: ReminderTime
    let onEscape: () -> Void
    var allowsPreciseInput = true
    @State private var presetRevision = 0
    private let blue = Color(nsColor: .systemBlue)

    var body: some View {
        VStack(spacing:15) {
            HStack(spacing:8) {
                TimeWheel(value:$time.hour,maximum:23,label:"提醒小时",onEscape:onEscape,allowsPreciseInput:allowsPreciseInput,presetRevision:presetRevision).frame(width:125,height:172)
                Text(":").font(.system(size:44,weight:.medium,design:.rounded))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                TimeWheel(value:$time.minute,maximum:59,label:"提醒分钟",onEscape:onEscape,allowsPreciseInput:allowsPreciseInput,presetRevision:presetRevision).frame(width:125,height:172)
            }
            HStack(spacing:10) {
                ForEach(OnboardingPolicy.presets,id:\.text) { preset in
                    Button { time=preset; presetRevision += 1 } label: {
                        Text(preset.text).font(.system(size:13,weight:.semibold)).monospacedDigit()
                            .padding(.horizontal,13).padding(.vertical,8)
                            .background(blue.opacity(preset == time ? 0.22 : 0.07),in:Capsule())
                            .overlay(Capsule().strokeBorder(blue.opacity(preset == time ? 0.6 : 0.16)))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("快捷选择 \(preset.text)")
                        .accessibilityAddTraits(preset == time ? .isSelected : [])
                }
            }
        }
    }
}

struct ReminderTimeRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(content:configuration.label,pressed:configuration.isPressed)
    }

    private struct Label<Content: View>: View {
        let content: Content
        let pressed: Bool
        @State private var hovered = false
        @Environment(\.isFocused) private var focused
        var body: some View {
            content
                .background(Color.accentColor.opacity(pressed ? 0.14 : hovered ? 0.08 : 0),in:RoundedRectangle(cornerRadius:9))
                .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(Color.accentColor.opacity(focused ? 0.85 : 0),lineWidth:2))
                .onHover { hovered = $0 }
        }
    }
}

struct ReminderTimeCard: View {
    @ObservedObject var services: Services
    let dismiss: () -> Void
    @State private var draft: ReminderTime
    @State private var saving = false
    @State private var failure: String?

    init(services: Services, dismiss: @escaping () -> Void) {
        self.services = services
        self.dismiss = dismiss
        _draft = State(initialValue:services.config.time)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("几点提醒？").font(.system(size:22,weight:.semibold))
                .accessibilityAddTraits(.isHeader)
            ReminderTimePicker(time:$draft,onEscape:cancel,allowsPreciseInput:false)
                .frame(maxWidth:.infinity)
                .disabled(saving)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing:10) {
                Spacer()
                Button("取消",action:cancel).keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "保存中…" : "完成",action:save)
                    .buttonStyle(ReminderTimeDoneStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || services.busy || !draft.isValid)
            }
        }
        .padding(20)
        .frame(width:364)
        .background {
            Color(nsColor:.windowBackgroundColor)
            LinearGradient(colors:[.blue.opacity(0.12),.cyan.opacity(0.025),.clear],
                           startPoint:.topLeading,endPoint:.bottomTrailing)
        }
        .interactiveDismissDisabled(saving)
        .onExitCommand(perform:cancel)
    }

    private func cancel() {
        guard !saving else { return }
        dismiss()
    }

    private func save() {
        guard !saving, !services.busy, draft.isValid else { return }
        guard draft != services.config.time else { dismiss(); return }
        saving = true
        failure = nil
        let time = draft
        Task { @MainActor in
            let success = await services.apply(time:time)
            saving = false
            if success { dismiss() }
            else { failure = services.error.map { "提醒时间未保存：\($0)" } ?? "暂时无法更新提醒时间，请重试。" }
        }
    }
}

/// Use the app's blue in either appearance, including when the sheet loses focus.
private struct ReminderTimeDoneStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:.semibold))
            .foregroundStyle(enabled ? .white : Color.secondary)
            .padding(.horizontal,13).frame(height:29)
            .background(
                enabled ? Color(red:0.04,green:0.36,blue:0.79).opacity(configuration.isPressed ? 0.78 : 1) : Color.primary.opacity(0.07),
                in:RoundedRectangle(cornerRadius:8)
            )
            .overlay(RoundedRectangle(cornerRadius:8)
                .strokeBorder(focused ? Color.accentColor : .clear,lineWidth:2))
    }
}
