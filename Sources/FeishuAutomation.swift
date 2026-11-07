import AppKit
import ApplicationServices
import Combine

struct FeishuAutomationOutcome {
    let title:String
    let detail:String?
    let successful:Bool
}
@MainActor final class FeishuAutomationController:ObservableObject {
    @Published private(set) var configuration=FeishuAutomationConfiguration.load(from:Runtime.defaults).productionSafe
    @Published private(set) var busy=false
    @Published private(set) var progress=""
    @Published private(set) var lastResult:String?
    @Published private(set) var testResult:String?
    @Published private(set) var detectedSelfName:String?
    private var task:Task<Void,Never>?
    var effectiveConfiguration:FeishuAutomationConfiguration {configuration.productionSafe}
    var trusted:Bool {AccessibilityPermission.shared.ready}
    func save(_ value:FeishuAutomationConfiguration)throws {
        guard !busy else {throw FeishuAutomationError.message("正在转发，请先取消当前操作再修改。")};guard !value.enabled || trusted else {throw FeishuAutomationError.message("请先开启辅助功能。")};try value.productionSafe.save(to:Runtime.defaults);configuration=FeishuAutomationConfiguration.load(from:Runtime.defaults).productionSafe
    }
    func requestPermission(repair:Bool=false) {
        AccessibilityPermission.shared.hasOpenedSettings=true
        openPermissions();AccessibilityGuide.shared.show(repair:repair)
    }
    func openPermissions() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {NSWorkspace.shared.open(url)}
    }
    func cancel() {task?.cancel()}
    func clearFeedback() {guard !busy else{return};lastResult=nil;testResult=nil}
    func testSelf(mode:FeishuDeliveryMode) {
        let text="Daily Todo 转发测试\n这是一条发给自己的测试消息。\n测试时间："+Date().formatted(date:.abbreviated,time:.standard)
        begin(text:text,day:ReminderRules.day(Date()),selfTest:true,testMode:mode) {_ in}
    }
    func forward(text:String,day:String,completion:@escaping (FeishuAutomationOutcome)->Void) {
        begin(text:text,day:day,selfTest:false,completion:completion)
    }
    private func begin(text:String,day:String,selfTest:Bool,testMode:FeishuDeliveryMode?=nil,completion:@escaping (FeishuAutomationOutcome)->Void) {
        guard !busy else{return}
        let testingSelf=selfTest || Runtime.sessionID != nil
        let original=effectiveConfiguration
        guard original.canDispatch(selfTest:selfTest) else {
            completion(FeishuAutomationOutcome(title:"请先开启一键转发",detail:nil,successful:false));return
        }
        var config=original
        config.mode=original.deliveryMode(selfTest:selfTest,testMode:testMode)
        if testingSelf {config.recipient="";config.recipientIsSelf=true;testResult=nil;detectedSelfName=nil}
        let deliveryConfiguration=config
        let clipboardGeneration=NSPasteboard.general.changeCount
        busy=true;progress="正在连接飞书…";lastResult=nil
        task=Task {
            let outcome:FeishuAutomationOutcome
            do {
                await AccessibilityPermission.shared.refresh()
                guard trusted else {throw FeishuAutomationError.message("请先在一键转发设置中开启辅助功能。")}
                guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.electron.lark") else {throw FeishuAutomationError.message("未找到飞书，请先安装飞书。")}
                let app=try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<NSRunningApplication,Error>) in
                    let options=NSWorkspace.OpenConfiguration();options.activates=true
                    NSWorkspace.shared.openApplication(at:url,configuration:options) {app,error in
                        if let app,error == nil {continuation.resume(returning:app)}
                        else {continuation.resume(throwing:error ?? FeishuAutomationError.message("无法启动飞书。"))}
                    }
                }
                let startupDeadline=ProcessInfo.processInfo.systemUptime+15
                while !app.isFinishedLaunching && ProcessInfo.processInfo.systemUptime < startupDeadline {
                    try Task.checkCancellation();try await Task.sleep(nanoseconds:100_000_000)
                }
                _ = app.activate(options:.activateIgnoringOtherApps)
                var activeSamples=0
                while activeSamples < 3 && ProcessInfo.processInfo.systemUptime < startupDeadline {
                    try Task.checkCancellation()
                    activeSamples=app.isActive ? activeSamples+1 : 0
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                guard activeSamples==3 else {throw FeishuAutomationError.message("飞书未能进入前台，请确认已登录后重试。")}
                try Task.checkCancellation()
                let worker=Task.detached(priority:.userInitiated) {
                    let session=FeishuAXSession(pid:app.processIdentifier)
                    var delivery=deliveryConfiguration
                    if testingSelf {
                        await MainActor.run {self.progress="正在识别本人账号…"}
                        let name=try await session.discoverSelf()
                        delivery.recipient=name;delivery.recipientIsSelf=true
                        await MainActor.run {self.detectedSelfName=name}
                    }
                    return try await session.deliver(text:text,day:day,config:delivery,clipboardGeneration:clipboardGeneration,ledger:FeishuDeliveryLedger(directory:Runtime.dataDirectory)) { stage in
                        Task { @MainActor in self.progress=stage }
                    }
                }
                outcome=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
            } catch {
                outcome=FeishuAutomationOutcome(title:testingSelf ? "测试未完成" : "转发未完成",detail:error is CancellationError ? "操作已取消，请检查飞书草稿。不会自动重发。" : error.localizedDescription,successful:false)
            }
            busy=false;lastResult=outcome.detail ?? outcome.title
            if testingSelf {testResult=outcome.successful && config.mode == .draft ? "已填入自己的聊天框，尚未发送" : outcome.successful ? "已向\(detectedSelfName ?? "自己")执行测试发送" : (outcome.detail ?? outcome.title)}
            Runtime.report("feishu-automation",payload:["successful":outcome.successful,"title":outcome.title,"detail":outcome.detail ?? "","recipient":detectedSelfName ?? config.recipient,"mode":config.mode.rawValue])
            completion(outcome)
        }
    }
}

private final class FeishuAXNode {
    let element:AXUIElement
    let role:String
    let label:String
    let labels:[String]
    let value:String
    let valueReadable:Bool
    let url:String
    var children:[FeishuAXNode]=[]
    init(_ element:AXUIElement) {
        self.element=element
        func string(_ key:String)->String {
            var value:CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else {return ""}
            if let value=value as? String {return value}
            if let value=value as? URL {return value.absoluteString}
            return ""
        }
        role=string(kAXRoleAttribute)
        var rawValue:CFTypeRef?
        let valueError=AXUIElementCopyAttributeValue(element,kAXValueAttribute as CFString,&rawValue)
        valueReadable=valueError == .success && rawValue is String
        value=(rawValue as? String) ?? ""
        labels=[string(kAXTitleAttribute),string(kAXDescriptionAttribute),string(kAXHelpAttribute),string("AXPlaceholderValue")].filter{!$0.isEmpty}
        label=labels.first ?? ""
        url=string(kAXURLAttribute)
    }
    var text:String {value.isEmpty ? label : value}
    var all:[FeishuAXNode] {[self]+children.flatMap(\.all)}
    var isEditor:Bool {role==kAXTextAreaRole || role==kAXTextFieldRole}
    var outsideEditors:[FeishuAXNode] {isEditor ? [] : [self]+children.flatMap(\.outsideEditors)}
    var staticTexts:[String] {isEditor ? [] : (role==kAXStaticTextRole ? [text] : children.flatMap(\.staticTexts))}
}
private final class FeishuAXSession:@unchecked Sendable {
    let app:AXUIElement
    let pid:pid_t
    init(pid:pid_t) {
        self.pid=pid;app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.4)
        _ = AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
    }
    private func fail(_ message:String)throws ->Never {throw FeishuAutomationError.message(message)}
    private func check()throws {
        try Task.checkCancellation()
        let access=AccessibilityLiveAccess.read(pid:pid)
        guard access == .allowed || (access == .unknown && AXIsProcessTrusted()) else {try fail("辅助功能权限已失效，已停止操作。") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {try fail("飞书已不在前台，操作已暂停。请回到飞书检查后重试。")}
    }
    private func attribute(_ element:AXUIElement,_ key:String)->CFTypeRef? {
        var value:CFTypeRef?
        return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
    }
    private func tree()throws ->FeishuAXNode {
        try check()
        let window:AXUIElement
        if let value=attribute(app,kAXFocusedWindowAttribute),CFGetTypeID(value)==AXUIElementGetTypeID() {window=unsafeBitCast(value,to:AXUIElement.self)}
        else if let windows=attribute(app,kAXWindowsAttribute) as? [AXUIElement],let first=windows.first {window=first}
        else {return FeishuAXNode(app)}
        var budget=1200
        func read(_ element:AXUIElement,_ depth:Int)->FeishuAXNode {
            let node=FeishuAXNode(element);budget -= 1
            if depth < 35,budget > 0,let children=attribute(element,kAXChildrenAttribute) as? [AXUIElement] {
                for child in children where budget > 0 {node.children.append(read(child,depth+1))}
            }
            return node
        }
        return read(window,0)
    }
    private func wait<T>(_ message:String,seconds:Double=15,find:(FeishuAXNode)throws ->T?) async throws ->T {
        let end=ProcessInfo.processInfo.systemUptime+seconds
        repeat {
            try check()
            if let result=try find(tree()) {return result}
            try await Task.sleep(nanoseconds:200_000_000)
        } while ProcessInfo.processInfo.systemUptime < end
        try fail(message)
    }
    private func click(_ node:FeishuAXNode,forceMouse:Bool=false)throws {
        try check()
        if !forceMouse && AXUIElementPerformAction(node.element,kAXPressAction as CFString) == .success {return}
        guard let position=attribute(node.element,kAXPositionAttribute),let size=attribute(node.element,kAXSizeAttribute),
              CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID() else {try fail("飞书控件暂不支持自动操作，请手动选择会话。")}
        var point=CGPoint.zero;var bounds=CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position,to:AXValue.self),.cgPoint,&point),AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&bounds),bounds.width>0,bounds.height>0 else {try fail("无法定位飞书控件。")}
        point.x += bounds.width/2;point.y += bounds.height/2
        var hit:AXUIElement?;var hitPID:pid_t=0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,
              let hit,AXUIElementGetPid(hit,&hitPID) == .success,hitPID==pid else {try fail("飞书控件被其他窗口遮挡，已停止操作。")}
        for type in [CGEventType.leftMouseDown,.leftMouseUp] {
            guard let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left) else {try fail("无法操作飞书控件。")}
            event.post(tap:.cghidEventTap)
        }
    }
    private func key(_ code:CGKeyCode,flags:CGEventFlags=[])throws {
        try check()
        for down in [true,false] {
            guard let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down) else {try fail("无法操作飞书输入区。")}
            event.flags=flags;event.postToPid(pid)
        }
    }
    private func focus(_ node:FeishuAXNode) async throws {
        try check();try click(node,forceMouse:true)
        _ = AXUIElementSetAttributeValue(node.element,kAXFocusedAttribute as CFString,kCFBooleanTrue)
        let end=ProcessInfo.processInfo.systemUptime+2
        repeat {
            try check()
            if let focused=attribute(app,kAXFocusedUIElementAttribute),CFGetTypeID(focused)==AXUIElementGetTypeID(),CFEqual(focused,node.element) {return}
            try await Task.sleep(nanoseconds:50_000_000)
        } while ProcessInfo.processInfo.systemUptime < end
        try fail("飞书输入焦点发生变化，已停止操作。")
    }
    private func typeSearchName(_ name:String,in node:FeishuAXNode,restoring body:String) async throws {
        try await focus(node)
        let live=FeishuAXNode(node.element)
        guard live.valueReadable else {try fail("无法读取搜索框，已停止查找。")}
        if FeishuAutomationRules.normalized(live.value)==name {return}
        if !FeishuAutomationRules.normalized(live.value).isEmpty {
            let clear=searchWeb(try tree())?.all.filter {$0.role==kAXButtonRole && $0.label=="清除"} ?? []
            guard clear.count==1 else {try fail("无法安全清除旧搜索，请手动清空飞书搜索后重试。")}
            try click(clear[0],forceMouse:true)
            let _:Bool=try await wait("飞书未能清空旧搜索，已停止查找。",seconds:3) {root in
                self.searchWeb(root)?.all.contains(where:{$0.isEditor && CFEqual($0.element,node.element) && $0.valueReadable && FeishuAutomationRules.normalized($0.value).isEmpty}) == true ? true:nil
            }
            try await focus(node)
        }
        let generation=try await MainActor.run { () throws ->Int in
            try self.check()
            guard let focused=self.attribute(self.app,kAXFocusedUIElementAttribute),CFEqual(focused,node.element),
                  FeishuAXNode(node.element).valueReadable,FeishuAutomationRules.normalized(FeishuAXNode(node.element).value).isEmpty else {
                try self.fail("搜索焦点或文字已改变，已停止查找。")
            }
            let board=NSPasteboard.general;board.clearContents()
            guard board.setString(name,forType:.string) else {try self.fail("无法准备联系人搜索文字。")}
            return board.changeCount
        }
        func restoreBody() async ->Bool {
            await MainActor.run {
                let board=NSPasteboard.general
                guard board.changeCount==generation,board.string(forType:.string)==name else {return false}
                board.clearContents();return board.setString(body,forType:.string)
            }
        }
        do {
            try await MainActor.run {
                let board=NSPasteboard.general
                guard board.changeCount==generation,board.string(forType:.string)==name else {try self.fail("剪贴板已变化，已暂停操作，请重新转发。")}
                guard let focused=self.attribute(self.app,kAXFocusedUIElementAttribute),CFEqual(focused,node.element) else {try self.fail("搜索焦点已改变，已停止查找。")}
                try self.key(9,flags:.maskCommand)
            }
            let _:Bool=try await wait("飞书未能接收联系人姓名，已停止查找。",seconds:5) {root in
                self.searchWeb(root)?.all.contains(where:{$0.isEditor && CFEqual($0.element,node.element) && FeishuAutomationRules.normalized($0.value)==name}) == true ? true:nil
            }
        } catch {_ = await restoreBody();throw error}
        guard await restoreBody() else {try fail("剪贴板已变化，已暂停操作，请重新转发。")}
    }
    private func searchWeb(_ root:FeishuAXNode)->FeishuAXNode? {root.all.first{$0.role=="AXWebArea" && ($0.url.contains("/search/search-command-bar/") || $0.label=="search-command-bar")}}
    private func chatWeb(_ root:FeishuAXNode)->FeishuAXNode? {root.all.first{$0.role=="AXWebArea" && ($0.url.contains("/messenger/messenger-chat/") || $0.label=="messenger-chat")}}
    private func hasEditableText(_ node:FeishuAXNode)->Bool {
        for child in node.children.flatMap(\.all) where child.role==kAXStaticTextRole {
            if FeishuAutomationRules.normalized(child.text).isEmpty {if !child.valueReadable {return true};continue}
            var editable=DarwinBoolean(false)
            let result=AXUIElementIsAttributeSettable(child.element,kAXValueAttribute as CFString,&editable)
            Runtime.report("feishu-text-editability",payload:["error":result.rawValue,"editable":editable.boolValue,"meaningfulLength":FeishuAutomationRules.normalized(child.text).count])
            if result == .attributeUnsupported {continue}
            if result != .success || editable.boolValue {return true}
        }
        return false
    }
    private func emptyComposer(_ node:FeishuAXNode,config:FeishuAutomationConfiguration)->Bool {
        guard !node.children.flatMap(\.all).contains(where:{[kAXImageRole,kAXButtonRole,"AXLink"].contains($0.role)}) else {return false}
        return FeishuAutomationRules.isEmptyComposer(node.value,name:config.recipient,isSelf:config.recipientIsSelf,readable:node.valueReadable,editableText:hasEditableText(node))
    }
    private func composer(_ chat:FeishuAXNode,config:FeishuAutomationConfiguration)->FeishuAXNode? {
        let editors=chat.all.filter{$0.isEditor}
        Runtime.report("feishu-composer-diagnostic",payload:[
            "firstStatic":Array(chat.staticTexts.prefix(4)),
            "editors":editors.map{["labels":$0.labels,"role":$0.role,"readable":$0.valueReadable,"editableText":hasEditableText($0),"empty":emptyComposer($0,config:config)] as [String:Any]}
        ])
        guard chat.staticTexts.first.map({FeishuAutomationRules.normalized($0)})==config.recipient,editors.count==1 else {return nil}
        return editors[0]
    }
    private func layoutSignature(_ chat:FeishuAXNode,editor:FeishuAXNode)->String {
        guard let parent=chat.all.first(where:{$0.children.contains(where:{CFEqual($0.element,editor.element)})}) else {return "missing"}
        func layout(_ node:FeishuAXNode)->String {
            if CFEqual(node.element,editor.element) {return "editor"}
            let own=node.children.isEmpty ? [node.role,node.label,node.value].joined(separator:"\u{1f}") : node.role
            return own+"["+node.children.map(layout).joined(separator:"\u{1e}")+"]"
        }
        return FeishuDeliveryLedger.fingerprint(recipient:"layout",day:"",text:layout(parent))
    }
    private func containsAttachments(_ chat:FeishuAXNode,editor:FeishuAXNode)->Bool {
        if editor.children.flatMap(\.all).contains(where:{[kAXImageRole,kAXButtonRole,"AXLink"].contains($0.role)}) {return true}
        let parent=chat.all.first(where:{$0.children.contains(where:{CFEqual($0.element,editor.element)})})
        return parent?.all.contains(where:{$0.role==kAXButtonRole && ["移除附件","删除附件","取消上传"].contains($0.label)}) == true
    }
    private func liveEditor(_ expected:FeishuAXNode,config:FeishuAutomationConfiguration,expectedText:String?,expectedLayout:String)throws ->FeishuAXNode {
        let root=try tree()
        guard searchWeb(root)==nil,let chat=chatWeb(root),let editor=composer(chat,config:config),CFEqual(editor.element,expected.element),
              let focused=attribute(app,kAXFocusedUIElementAttribute),CFEqual(focused,editor.element) else {try fail("聊天对象或输入焦点已改变，已停止操作。")}
        guard !containsAttachments(chat,editor:editor),layoutSignature(chat,editor:editor)==expectedLayout else {try fail("聊天或待发送附件发生变化，已停止操作并保留草稿。")}
        // This read is deliberately after tree traversal and all waiting/locking.
        let live=FeishuAXNode(editor.element)
        guard live.valueReadable else {try fail("无法读取飞书草稿，已停止操作并保留原文。场景暂不支持自动化。") }
        if let expectedText {
            guard FeishuAutomationRules.normalized(live.value)==FeishuAutomationRules.normalized(expectedText) else {try fail("正文已被修改，已停止发送并保留草稿。")}
        } else {
            guard FeishuAutomationRules.mayFill(header:chat.staticTexts.first ?? "",description:live.labels.first(where:{FeishuAutomationRules.recipientMatches($0,name:config.recipient,isSelf:config.recipientIsSelf)}) ?? "",name:config.recipient,isSelf:config.recipientIsSelf,draft:live.value,focused:true,editableText:hasEditableText(editor)) else {try fail("输入区出现了新草稿，已保留原文。")}
        }
        return live
    }
    func discoverSelf() async throws ->String {
        func accountCard(_ root:FeishuAXNode)->Bool {
            root.all.contains{$0.role=="AXWebArea" && ($0.label=="ternantCardModal" || $0.url.contains("/main-window/ternantCardModal/"))}
        }
        let initial=try tree()
        if searchWeb(initial) != nil || accountCard(initial) {
            try key(53)
            let _:Bool=try await wait("请先关闭飞书搜索或账号卡片后重试。") {root in
                self.searchWeb(root)==nil && !accountCard(root) ? true:nil
            }
        }
        let root:FeishuAXNode=try await wait("请先登录飞书后重试。",seconds:25) {root in
            root.all.contains(where:{$0.role==kAXButtonRole && $0.label=="我的头像"}) ? root : nil
        }
        let buttons=root.all.filter{$0.role==kAXButtonRole && $0.label=="我的头像"}
        guard buttons.count==1 else {try fail("无法确认当前飞书账号，请先检查登录状态。")}
        try click(buttons[0])
        let name:String
        var readiness=FeishuProfileReadiness()
        do {
            name=try await wait("没有读到明确的飞书本人姓名，测试已停止。",seconds:10) {root in
                guard let profile=root.all.first(where:{$0.role=="AXWebArea" && ($0.label=="ternantCardModal" || $0.url.contains("/main-window/ternantCardModal/"))}) else {
                    return readiness.sample(texts:[],nodeCount:0,at:ProcessInfo.processInfo.systemUptime)
                }
                // Electron exposes the WebArea before its account content is loaded.
                // Wait for verified account content, not merely an empty WebArea.
                Runtime.report("feishu-profile-readiness",payload:["nodes":profile.all.count,"texts":profile.staticTexts.count,"verified":FeishuAutomationRules.selfName(profileTexts:profile.staticTexts) != nil])
                return readiness.sample(texts:profile.staticTexts,nodeCount:profile.all.count,at:ProcessInfo.processInfo.systemUptime)
            }
        } catch {try? key(53);throw error}
        try key(53)
        let _:Bool=try await wait("请先关闭飞书账号卡片后重试。") {root in
            root.all.contains(where:{$0.role=="AXWebArea" && $0.label=="ternantCardModal"}) ? nil : true
        }
        return name
    }
    func deliver(text:String,day:String,config:FeishuAutomationConfiguration,clipboardGeneration:Int,ledger:FeishuDeliveryLedger,progress:@escaping @Sendable(String)->Void) async throws ->FeishuAutomationOutcome {
        let target=config.recipient
        let fingerprint=FeishuDeliveryLedger.fingerprint(recipient:target,day:day,text:text)
        if config.mode == .send,try ledger.hasAttempt(fingerprint) {try fail("这份内容已发送或发送结果未确认。请先检查飞书，系统不会重复发送。")}
        let _:FeishuAXNode=try await wait("飞书未就绪，请先登录并重试。",seconds:25) {root in
            (self.searchWeb(root) != nil || root.all.contains(where:{$0.role==kAXButtonRole && $0.label.contains("搜索")})) ? root : nil
        }
        if searchWeb(try tree()) != nil {
            try key(53)
            let _:Bool=try await wait("请先关闭飞书搜索后重试。") {self.searchWeb($0)==nil ? true : nil}
        }
        progress("正在查找 \(config.recipient)…")
        let search=try tree().all.filter{$0.role==kAXButtonRole && ($0.label.hasPrefix("搜索（") || $0.label.hasPrefix("搜索("))}
        guard search.count==1 else {try fail("无法识别飞书搜索入口，请确认已登录。")}
        try click(search[0])
        let input:FeishuAXNode=try await wait("无法定位联系人搜索框。") {self.searchWeb($0)?.all.first(where:{$0.isEditor})}
        try await typeSearchName(config.recipient,in:input,restoring:text)
        let _:Bool=try await wait("飞书未能接收联系人姓名，请手动查找。",seconds:5) {root in
            self.searchWeb(root)?.all.contains(where:{$0.isEditor && FeishuAutomationRules.normalized($0.value)==config.recipient}) == true ? true : nil
        }
        if searchWeb(try tree())?.staticTexts.first != "联系人" {
            let filter:FeishuAXNode=try await wait("无法识别联系人筛选，请手动选择。") {root in
                self.searchWeb(root)?.all.first{$0.role==kAXButtonRole && $0.label=="联系人"}
            }
            try click(filter)
        }
        let person:FeishuAXNode=try await wait("未找到唯一联系人，请核对姓名后重试。") {root in
            guard let web=self.searchWeb(root),web.staticTexts.first=="联系人",!web.all.contains(where:{$0.text=="加载中"}) else {return nil}
            let people=web.outsideEditors.filter{$0.role==kAXStaticTextRole && FeishuAutomationRules.normalized($0.text)==config.recipient}
            if people.count>1 {try self.fail("发现多个同名联系人，已停止操作。请在飞书中手动确认并发送。")}
            return people.count==1 ? people[0] : nil
        }
        try click(person)
        progress("正在核对聊天对象…")
        let pair:(FeishuAXNode,FeishuAXNode)=try await wait("聊天对象或输入框未能确认，已停止操作。") {root in
            guard self.searchWeb(root)==nil,let chat=self.chatWeb(root),let editor=self.composer(chat,config:config) else {return nil}
            return (chat,editor)
        }
        if config.recipientIsSelf {
            guard FeishuAutomationRules.isVerifiedSelfComposer(pair.1.value,editableText:hasEditableText(pair.1)) else {
                try fail("未能确认这是本人空聊天，测试已停止；已有内容保持不变。")
            }
        }
        guard emptyComposer(pair.1,config:config) else {try fail("这个聊天已有草稿，已保留原文；请处理草稿后再转发。Todo 仍在剪贴板中。")}
        // Composer sibling attachments also belong to an existing draft.
        let draftArea=pair.0.all.first(where:{$0.children.contains(where:{$0 === pair.1})})
        if let draftArea,draftArea.all.contains(where:{$0.role==kAXButtonRole && ["移除附件","删除附件","取消上传"].contains($0.label)}) {try fail("聊天中已有待发送附件，请先处理后重试。")}
        let expectedLayout=layoutSignature(pair.0,editor:pair.1)
        progress("正在填写消息…")
        try await focus(pair.1)
        try await MainActor.run {
            let board=NSPasteboard.general
            _ = try self.liveEditor(pair.1,config:config,expectedText:nil,expectedLayout:expectedLayout)
            // The click owns this immutable Todo snapshot. Refresh only at the
            // final paste step, after all navigation and blocking AX reads.
            board.clearContents()
            guard board.setString(text,forType:.string) else {try self.fail("无法将本次 Todo 写入剪贴板，已停止填写。")}
            let pasteGeneration=board.changeCount
            Runtime.report("feishu-clipboard-state",payload:["generationChanged":pasteGeneration != clipboardGeneration,"textMatches":board.string(forType:.string)==text])
            try self.check()
            guard let focused=self.attribute(self.app,kAXFocusedUIElementAttribute),CFEqual(focused,pair.1.element),
                  let value=self.attribute(pair.1.element,kAXValueAttribute) as? String,
                  FeishuAutomationRules.isEmptyComposer(value,name:config.recipient,isSelf:config.recipientIsSelf,readable:true,editableText:self.hasEditableText(pair.1)) else {try self.fail("输入焦点或草稿已改变，已取消填写。")}
            guard board.changeCount==pasteGeneration,board.string(forType:.string)==text else {try self.fail("粘贴前剪贴板已改变，已停止操作。")}
            try self.key(9,flags:.maskCommand)
        }

        let filled:(FeishuAXNode,FeishuAXNode)=try await wait("飞书未能确认完整正文，请检查草稿并手动粘贴。",seconds:5) {root in
            guard let chat=self.chatWeb(root),let editor=self.composer(chat,config:config),FeishuAutomationRules.normalized(editor.value)==FeishuAutomationRules.normalized(text) else {return nil}
            return (chat,editor)
        }
        if config.mode == .draft {
            return FeishuAutomationOutcome(title:"已填入聊天框",detail:"尚未发送，请在飞书检查后发送。",successful:true)
        }
        guard filled.0.staticTexts.contains(where:{FeishuAutomationRules.canSendUsingReturn(hint:$0)}) else {try fail("无法确认飞书发送键，已保留草稿，请在飞书中手动发送。")}
        try await focus(filled.1)
        guard FeishuAutomationRules.normalized(FeishuAXNode(filled.1.element).value)==FeishuAutomationRules.normalized(text) else {try fail("草稿已被修改，已取消自动发送。")}
        guard try ledger.claim(fingerprint) else {try fail("这份内容已发送或上次发送结果未确认。请先检查飞书，系统不会重复发送。")}
        progress("正在发送并核对结果…")
        var dispatched=false
        do {
            _ = try liveEditor(filled.1,config:config,expectedText:text,expectedLayout:expectedLayout)
            try key(36);dispatched=true
            let _:Bool=try await wait("发送结果未确认，请检查飞书聊天。系统不会自动重发。",seconds:8) {root in
                guard let chat=self.chatWeb(root),let editor=self.composer(chat,config:config),self.emptyComposer(editor,config:config) else {return nil}
                return true
            }
            // A cleared composer confirms the UI action, not server delivery.
            try ledger.finish(fingerprint,sent:false)
        } catch {
            try? ledger.finish(fingerprint,sent:false)
            if dispatched {return FeishuAutomationOutcome(title:"已执行发送操作",detail:"最终状态未确认，请检查飞书聊天；系统不会自动重发。",successful:false)}
            throw error
        }
        return FeishuAutomationOutcome(title:"已执行发送操作",detail:"收件人：\(config.recipient)。请以飞书中的最终发送状态为准；系统不会自动重发。",successful:true)
    }
}
