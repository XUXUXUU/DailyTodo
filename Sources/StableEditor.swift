import SwiftUI
import AppKit

extension EditorKey {
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: EditorModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(code: event.keyCode, modifiers: modifiers)
    }
}

/// 仅隔离测试构建写入非正文诊断，不记录用户输入。
enum EditorDiagnostics {
    static func record(_ event:String,_ values:[String:Any]=[:]) {
#if INTEGRATION_TESTING
        guard Runtime.sessionID != nil else {return}
        var data=values;data["event"]=event;data["timestamp"]=Date().timeIntervalSince1970
        guard let bytes=try? JSONSerialization.data(withJSONObject:data,options:.sortedKeys) else {return}
        let file=Runtime.dataDirectory.appendingPathComponent("editor-events.jsonl")
        if !FileManager.default.fileExists(atPath:file.path) {FileManager.default.createFile(atPath:file.path,contents:nil)}
        if let handle=try? FileHandle(forWritingTo:file) {defer {try? handle.close()};do {try handle.seekToEnd();try handle.write(contentsOf:bytes+Data([10]))}catch{}}
#endif
    }
}
@MainActor final class EditorFocus:ObservableObject {
    @Published var focused:Int?=0
    var last=0
    var views=[Int:DraftTextView]()
    func focus(_ index:Int) {
        guard let view=views[index] else {return}
        last=index;focused=index
        view.window?.makeFirstResponder(view)
    }
    func blur() {
        if let i=focused {last=i;views[i]?.window?.makeFirstResponder(nil)}
        focused=nil
    }
    weak var copyButton:NSButton?
    func next(_ index: Int) {
        if index < 2 { focus(index + 1) }
        else { blur(); views[index]?.window?.makeFirstResponder(copyButton) }
    }

    func previous(_ index: Int) {
        if index > 0 { focus(index - 1) }
        else if let view = views[index] { view.window?.selectPreviousKeyView(view) }
    }
    func commitComposition() {
        for view in views.values where view.hasMarkedText() {view.unmarkText();view.didChangeText()}
    }
}
final class DraftTextView:NSTextView {
    var onFocus:(()->Void)?
    var onNext:(()->Void)?
    var onPrevious:(()->Void)?
    var placeholder=""
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty { (placeholder as NSString).draw(at:NSPoint(x:textContainerInset.width+5,y:textContainerInset.height),withAttributes:[.font:font ?? NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.secondaryLabelColor]) }
    }
    var shortcuts: EditorShortcuts = .standard
    var editingActive = true
    override var acceptsFirstResponder: Bool { editingActive && super.acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
    override func keyDown(with event:NSEvent) {
        // 组合态和未绑定键交给 NSTextInputClient，保留原生选词、编辑和撤销。
        guard editingActive else { return }
        let marked = hasMarkedText()
        if marked && [36, 48, 76].contains(event.keyCode) {
            EditorDiagnostics.record("ime-navigation-deferred", ["keyCode": event.keyCode])
        }
        guard window?.firstResponder === self, window?.isKeyWindow == true,
              !marked, let action = shortcuts.action(for: EditorKey(event)) else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        switch action {
        case .newline: insertNewline(nil)
        case .next: onNext?()
        case .previous: onPrevious?()
        }
    }
}
struct StableEditor:NSViewRepresentable {
    let index:Int
    let day:String
    let text:String
    let placeholder:String
    let shortcuts: EditorShortcuts
    let visible: Bool
    let editingActive: Bool
    let focus:EditorFocus
    let onChange:(String)->Void
    @Binding var height:CGFloat
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=false;scroll.hasHorizontalScroller=false;scroll.isHidden = !visible
        let view=DraftTextView(frame:NSRect(x:0,y:0,width:500,height:90));view.isRichText=false;view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false
        view.font = .systemFont(ofSize:15);view.textColor = .labelColor;view.backgroundColor = .clear;view.drawsBackground=false
        view.textContainerInset=NSSize(width:2,height:7);view.isVerticallyResizable=true;view.isHorizontallyResizable=false
        view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true;view.textContainer?.containerSize=NSSize(width:500,height:CGFloat.greatestFiniteMagnitude)
        view.minSize=NSSize(width:0,height:80);view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.allowsUndo=true;view.delegate=context.coordinator;view.string=text
        view.setAccessibilityLabel(["今日任务","当前进度","卡点"][index]);scroll.documentView=view
        context.coordinator.loadedDay=day;context.coordinator.view=view;focus.views[index]=view
        bind(view,context.coordinator);EditorDiagnostics.record("editor-created",["card":index,"identity":String(describing:ObjectIdentifier(view))]);return scroll
    }
    private func bind(_ view:DraftTextView,_ coordinator:Coordinator) {
        view.shortcuts=shortcuts;view.editingActive=editingActive;view.placeholder=placeholder;view.needsDisplay=true
        view.onFocus={ [weak focus] in guard let focus else{return};focus.last=index;if focus.focused != index {focus.focused=index}}
        view.onNext={ [weak focus] in focus?.next(index)}
        view.onPrevious={ [weak focus] in focus?.previous(index)}
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        let c=context.coordinator;c.parent=self
        guard let view=scroll.documentView as? DraftTextView else{return}
        bind(view,c)
        // SwiftUI opacity does not remove the NSTextView's native cursor rectangles.
        if scroll.isHidden == visible {
            scroll.isHidden = !visible
            view.window?.invalidateCursorRects(for:view)
        }
        // 同日刷新（保存/hover/焦点/toast）绝不赋值string或触碰selection/undo。
        if c.loadedDay != day && !view.hasMarkedText() {
            view.string=text;view.undoManager?.removeAllActions();view.setSelectedRange(NSRange(location:0,length:0));c.loadedDay=day
            EditorDiagnostics.record("editor-loaded",["card":index,"day":day])
        }
        DispatchQueue.main.async {c.measure()}
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:StableEditor
        weak var view:DraftTextView?
        var loadedDay=""
        init(_ parent:StableEditor){self.parent=parent}
        func textDidChange(_ notification:Notification) {
            guard let view else{return}
            if !view.hasMarkedText() {parent.onChange(view.string)}
            measure()
        }
        func textDidEndEditing(_ notification:Notification) {guard let view,!view.hasMarkedText() else{return};parent.onChange(view.string)}
        func measure() {
            guard let view,let container=view.textContainer,let manager=view.layoutManager else{return}
            manager.ensureLayout(for:container)
            let h=max(86,ceil(manager.usedRect(for:container).height+view.textContainerInset.height*2+8))
            if abs(parent.height-h)>1 {parent.height=h}
        }
    }
}

struct DraftCard:View {
    let index:Int
    let day:String
    let text:String
    let placeholder:String
    let shortcuts: EditorShortcuts
    let visible: Bool
    let editingActive: Bool
    @ObservedObject var focus:EditorFocus
    let hover:Bool
    let flash:Bool
    let onChange:(String)->Void
    @State private var height:CGFloat=86
    private var active:Bool {focus.focused == index}
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Label(["今日任务","当前进度","卡点"][index],systemImage:["film","slider.horizontal.3","flag"][index]).font(.system(size:15,weight:.semibold))
                Spacer()
                Text(active ? "正在编辑" : text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "待填写" : "已填写 ✓").font(.system(size:11)).foregroundStyle(.secondary)
            }.contentShape(Rectangle()).onTapGesture {focus.focus(index)}
            ZStack(alignment:.topLeading) {
                StableEditor(index:index,day:day,text:text,placeholder:placeholder,shortcuts:shortcuts,visible:visible,editingActive:editingActive,focus:focus,onChange:onChange,height:$height).frame(height:height)

            }
        }.padding(17).frame(maxWidth:.infinity,alignment:.leading)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).fill(Color.blue.opacity(flash ? 0.09 : 0)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.blue.opacity(flash ? 0.8 : hover ? 0.6 : active ? 0.5 : 0.19),lineWidth:active || hover || flash ? 1.5 : 1).allowsHitTesting(false))
            .shadow(color:Color.blue.opacity(flash ? 0.2 : hover ? 0.14 : active ? 0.07 : 0.02),radius:hover || flash ? 10 : 5,y:2)
    }
}

/// 原生可聚焦按钮：末项快捷键只移动焦点，不执行复制。
final class CopyActionButton:NSButton {
    var hoverChanged:((Bool)->Void)?
    var returnToEditor: (() -> Void)?
    var nextEditorKey: EditorKey?
    private var area:NSTrackingArea?
    override var acceptsFirstResponder:Bool {true}
    override func becomeFirstResponder()->Bool {needsDisplay=true;return true}
    override func resignFirstResponder()->Bool {needsDisplay=true;return true}
    override func keyDown(with event:NSEvent) {
        let key = EditorKey(event)
        if event.isARepeat && key == nextEditorKey { return }
        if key == .previous, let returnToEditor {
            if !event.isARepeat { returnToEditor() }
            return
        }
        if key.modifiers.isEmpty && (key.code == 36 || key.code == 49) {
            if !event.isARepeat { performClick(nil) }
            return
        }
        super.keyDown(with: event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let area{removeTrackingArea(area)}
        area=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(area!)
    }
    override func mouseEntered(with event:NSEvent){hoverChanged?(true)}
    override func mouseExited(with event:NSEvent){hoverChanged?(false)}
    override func draw(_ dirtyRect:NSRect) {
        let rect=bounds.insetBy(dx:1,dy:1),path=NSBezierPath(roundedRect:rect,xRadius:12,yRadius:12)
        NSGraphicsContext.saveGraphicsState();path.addClip()
        NSGradient(starting:NSColor.systemBlue.withAlphaComponent(isEnabled ? 1:0.4),ending:NSColor(calibratedRed:0,green:0.64,blue:0.9,alpha:isEnabled ? 1:0.4))?.draw(in:rect,angle:0)
        if isHighlighted {NSColor.black.withAlphaComponent(0.12).setFill();path.fill()};NSGraphicsContext.restoreGraphicsState()
        let focused=window?.firstResponder === self
        NSColor.white.withAlphaComponent(focused ? 0.95:0.3).setStroke();path.lineWidth=focused ? 2.5:1;path.stroke()
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:NSColor.white,.paragraphStyle:paragraph]
        let size=(title as NSString).size(withAttributes:attributes),total=min(size.width,bounds.width-48)+26,x=(bounds.width-total)/2
        let icon=NSImage(systemSymbolName:title == "已复制" ? "checkmark" : title.hasPrefix("发给") ? "paperplane.fill" : "doc.on.doc",accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[.white]))
        icon?.draw(in:NSRect(x:x,y:(bounds.height-18)/2,width:18,height:18))
        (title as NSString).draw(in:NSRect(x:x+26,y:(bounds.height-size.height)/2,width:bounds.width-x-34,height:size.height),withAttributes:attributes)
    }
}
struct NativeCopyButton:NSViewRepresentable {
    let copied:Bool
    var title="复制全部"
    let enabled:Bool
    let focus:EditorFocus
    let nextEditorKey: EditorKey?
    let action:()->Void
    let hover:(Bool)->Void
    func makeCoordinator()->Coordinator{Coordinator(self)}
    func makeNSView(context:Context)->CopyActionButton {
        let button=CopyActionButton();button.isBordered=false;button.focusRingType = .none
        button.target=context.coordinator;button.action=#selector(Coordinator.copyAction)
        focus.copyButton=button;return button
    }
    func updateNSView(_ button:CopyActionButton,context:Context) {
        context.coordinator.parent=self;button.title=copied ? "已复制":title;button.toolTip=title;button.isEnabled=enabled;button.hoverChanged=hover;button.needsDisplay=true
        button.nextEditorKey = nextEditorKey
        button.returnToEditor = nextEditorKey == nil ? nil : { [weak focus] in focus?.focus(2) }
    }
    final class Coordinator:NSObject {
        var parent:NativeCopyButton;init(_ parent:NativeCopyButton){self.parent=parent}
        @objc func copyAction(){parent.action()}
    }
}
