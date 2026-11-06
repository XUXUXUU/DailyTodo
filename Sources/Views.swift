import SwiftUI
import ServiceManagement
import AppKit

private enum Theme {
    static let blue = Color(nsColor:.systemBlue)
    static let gradient = LinearGradient(colors:[Color(red:0.03,green:0.44,blue:0.96),Color(red:0.0,green:0.65,blue:0.9)],startPoint:.topLeading,endPoint:.bottomTrailing)
}
struct NavigationButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) var scheme
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(content:configuration.label,pressed:configuration.isPressed)
    }
    private struct HoverLabel<Content:View>: View {
        let content:Content
        let pressed:Bool
        @State private var hovering = false
        var body: some View {
            content.font(.system(size:13,weight:.semibold)).foregroundStyle(Color.primary)
                .padding(.horizontal,13).frame(minHeight:36)
                .background(Theme.blue.opacity(pressed ? 0.25 : hovering ? 0.18 : 0.09),in:RoundedRectangle(cornerRadius:11))
                .overlay(RoundedRectangle(cornerRadius:11).stroke(Theme.blue.opacity(hovering ? 0.65 : 0.3)))
                .onHover { hovering = $0 }
        }
    }
}
private struct GlassCard<Content:View>: View {
    @ViewBuilder var content:Content
    var body: some View {
        VStack(alignment:.leading,spacing:17) { content }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).stroke(Color.primary.opacity(0.09)))
            .shadow(color:Color.black.opacity(0.04),radius:12,y:5)
    }
}
struct RootView: View {
    @ObservedObject var model: Model
    @ObservedObject var services: Services
    @ObservedObject var updater: AppUpdater
    let show: () -> Void
    let pageChanged:(String)->Void
    @StateObject private var editorFocus=EditorFocus()
    @StateObject private var automation=FeishuAutomationController()
    @State private var copyToastTitle="已复制到剪贴板"
    @State private var copyHovered=false
    @State private var copyFlash=false
    @State private var flashTask:Task<Void,Never>?
    @State private var shortcuts = EditorShortcuts.load(from: Runtime.defaults)
    @State private var showsShortcutSettings = false
    @State private var copied = false
    @State private var toastVisible = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void,Never>?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion:Bool { systemReduceMotion || Runtime.reduceMotionOverride }
    @AppStorage("copyMessagesEnabled",store:Runtime.defaults) private var copyMessagesEnabled = true
    @State private var messagePicker = CopyMessages(messages:(Bundle.main.url(forResource:"CopyMessages",withExtension:"json").flatMap { try? CopyMessages.load($0) } ?? []),previous:Runtime.defaults.string(forKey:"lastCopyMessage"))
    @State private var feishuFeedback:String?
    @State private var selected: String?
    @State private var showsTimeSettings = false
    let fields: [(String, WritableKeyPath<Entry,String>)] = [("今日任务",\.tasks),("当前进度",\.progress),("卡点",\.blockers)]
    let placeholders = ["片子名称 / 交付节点","当前完成情况 / 所处阶段","需要协调 / 素材 / 文案 / 审核 / 排期冲突"]
    var title:String { model.page == "settings" ? "设置" : model.page == "history" ? "历史记录" : model.page == "detail" ? "历史详情" : "Daily Todo" }
    var body: some View {
        VStack(spacing:0) {
            header
            if let error=services.completionError {
                HStack {Text(error).font(.caption);Button("重试免提醒保存") {services.retryPendingCopies()}}.padding(12).foregroundStyle(.orange)
            }
            if let problem = model.problem {
                HStack { Image(systemName:"exclamationmark.triangle.fill"); Group {
                    if model.page == "settings" { Text(problem) }
                    else { Text(problem).textSelection(.enabled) }
                }.font(.caption); Button("重试保存") { model.flush() } }.padding(12).background(Color.orange.opacity(0.13))
            }
            ZStack {
                editor.opacity(model.page == "today" ? 1 : 0).allowsHitTesting(model.page == "today").accessibilityHidden(model.page != "today")
                if model.page == "settings" {settings}
                else if model.page == "history" {historyList}
                else if model.page == "detail" {historyDetail}
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            if model.page != "settings" { footer }
        }
        .background {
            Button(action:copyOnly){EmptyView()}
                .keyboardShortcut("c",modifiers:[.command,.shift])
                .disabled(model.store == nil || showsShortcutSettings || automation.busy)
                .hidden().accessibilityHidden(true)
        }
        .frame(minWidth:model.page == "today" ? 540 : 600,minHeight:620)
        .background {
            ZStack(alignment:.topLeading) {
                Color(nsColor:.windowBackgroundColor)
                LinearGradient(colors:[Theme.blue.opacity(0.12),Color.cyan.opacity(0.03),.clear],startPoint:.topLeading,endPoint:.bottomTrailing)
            }
        }.tint(Theme.blue)
        .overlay {
            GeometryReader { geometry in
                if toastVisible {
                    copyToast.frame(width:min(420,geometry.size.width-48))
                        .position(x:geometry.size.width/2,y:geometry.size.height*0.45)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion:.opacity.combined(with:.scale(scale:0.97)).combined(with:.offset(y:8)),removal:.opacity))
                }
            }.allowsHitTesting(automation.busy)
        }
        .onChange(of:model.page) { page in
            copyHovered=false;copyFlash=false;flashTask?.cancel()
            pageChanged(page)
            if page != "today" {
                editorFocus.blur()
            } else {
                DispatchQueue.main.async {
                    if model.page == "today" && !model.showOnboarding { editorFocus.focus(editorFocus.last) }
                }
            }
        }
        .sheet(isPresented:$model.showOnboarding,onDismiss:{model.onboardingSheetClosed()}) {
            OnboardingView(model:model,services:services,automation:automation)
        }
    }
    var header: some View {
        HStack(spacing:12) {
            if model.page != "today" {
                Button { model.back() } label: { Label("返回",systemImage:"chevron.left") }.buttonStyle(NavigationButtonStyle())
            } else {
                if let image = NSImage(named:"BrandLogo") {
                    Image(nsImage:image).resizable().scaledToFit().frame(width:48,height:48).accessibilityHidden(true)
                }
            }
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.system(size:24,weight:.semibold)).lineLimit(1)
                if model.page != "settings" {
                    Text(model.page == "today" ? "让每日汇报更简单 · \(model.entry.day)" : "每日快照，保留每一步进展")
                        .font(.system(size:12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength:4)
            if model.page == "today" {
                Button { model.go("history") } label: { Label("历史",systemImage:"clock.arrow.circlepath").symbolRenderingMode(.hierarchical) }.buttonStyle(NavigationButtonStyle()).help("历史记录")
                Button { model.go("settings") } label: { Label("设置",systemImage:"gearshape.fill") }.buttonStyle(NavigationButtonStyle()).help("提醒与偏好")
            }
        }.padding(.horizontal,24).padding(.vertical,20)
    }
    var footer: some View {
        HStack(spacing:10) {
            Label(model.saveStatus,systemImage:model.saveStatus == "已自动保存" ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size:12)).foregroundStyle(model.saveStatus == "保存失败" || model.store == nil ? Color.orange : Color.secondary)
            Spacer()
            NativeCopyButton(copied:copied && !automation.busy,title:automation.busy ? "处理中…" : automation.configuration.enabled ? automation.effectiveConfiguration.buttonTitle : "复制全部",enabled:model.store != nil && !showsShortcutSettings && !automation.busy,focus:editorFocus,nextEditorKey:model.page == "today" ? shortcuts.next : nil,action:copy,hover:{value in
                withAnimation(.easeOut(duration:reduceMotion ? 0:0.21)){copyHovered=value && model.page == "today"}
            }).frame(width:130,height:40)
        }.padding(.horizontal,24).padding(.vertical,16).background(.bar)
    }
    var editor: some View {
        ScrollView {
            VStack(spacing:16) {
                ForEach(fields.indices,id:\.self) {i in
                    DraftCard(index:i,day:model.entry.day+model.entry.id.uuidString,text:model.entry[keyPath:fields[i].1],placeholder:placeholders[i],shortcuts:shortcuts,visible:model.page == "today",editingActive:model.page == "today" && !model.showOnboarding,focus:editorFocus,hover:copyHovered,flash:copyFlash) {value in model.edit(fields[i].1,value)}
                }
            }.padding(.horizontal,24).padding(.bottom,24).padding(.top,4)
        }
    }
    var historyList: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                ForEach((model.store?.entries ?? []).sorted {$0.day > $1.day}) { entry in
                    Button { selected = entry.day; model.go("detail") } label: {
                        HStack { Image(systemName:"doc.text").foregroundStyle(Theme.blue); Text(entry.day).font(.system(size:15,weight:.medium)); Spacer(); Text("只读快照").font(.caption).foregroundStyle(.secondary); Image(systemName:"chevron.right").foregroundStyle(.secondary) }.padding(16)
                    }.buttonStyle(.plain).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
                }
                if model.store?.entries.isEmpty != false { Text("暂无历史记录").foregroundStyle(.secondary) }
            }.padding(24)
        }
    }
    var historyDetail: some View {
        ScrollView {
            if let entry = model.store?.entries.first(where:{$0.day == selected}) {
                GlassCard {
                    Label("\(entry.day) · 只读历史",systemImage:"lock.doc").font(.headline)
                    ForEach(fields.indices,id:\.self) { i in
                        VStack(alignment:.leading,spacing:9) {
                            Text(fields[i].0).font(.system(size:15,weight:.semibold))
                            Text(entry[keyPath:fields[i].1].isEmpty ? "（空）" : entry[keyPath:fields[i].1]).font(.system(size:15)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }
                }.padding(24)
            }
        }
    }
    var settings: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                VStack(alignment:.leading,spacing:10) {
                    Text("提醒与偏好").font(.system(size:16,weight:.semibold))
                    VStack(spacing:0) {
                        AlignedPreferenceToggle(title:"启用提醒",icon:"bell.badge",isOn:Binding(get:{services.enabled},set:{value in Task { _ = await services.apply(enabled:value) } }),disabled:services.busy)
                        settingsDivider
                        Button {
                            showsTimeSettings = true
                        } label: {
                            PreferenceRow(title:"提醒时间",icon:"clock",controlWidth:110) {
                                HStack(spacing:8) {
                                    Text(services.config.time.text).monospacedDigit()
                                    Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold))
                                }.font(.system(size:13,weight:.medium)).foregroundStyle(.white)
                                    .padding(.horizontal,12).frame(height:32)
                                    .background(Color(white:0.17),in:RoundedRectangle(cornerRadius:8))
                                    .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(.white.opacity(0.16)))
                            }.contentShape(Rectangle())
                        }.buttonStyle(ReminderTimeRowStyle())
                            .accessibilityLabel("提醒时间")
                            .accessibilityValue(services.config.time.text)
                            .disabled(services.busy)
                            .sheet(isPresented:$showsTimeSettings) {
                                ReminderTimeCard(services:services) { showsTimeSettings = false }
                            }
                        settingsDivider
                        AlignedPreferenceToggle(title:"系统通知",icon:"bell",help:services.enabled ? services.notificationHelp : "请先开启「启用提醒」。",isOn:Binding(get:{services.enabled && services.notificationsOn},set:{value in Task { await services.setNotifications(value) } }),disabled:services.busy || !services.enabled)
                        settingsDivider
                        AlignedPreferenceToggle(title:"自动弹窗",icon:"macwindow",help:services.enabled ? services.popupHelp : "请先开启「启用提醒」。",isOn:Binding(get:{services.enabled && services.popupOn},set:{value in Task { await services.setPopup(value) } }),disabled:services.busy || !services.enabled)
                        settingsDivider
                        AlignedPreferenceToggle(title:"开机启动",icon:"power",help:services.loginHelp,isOn:Binding(get:{services.login},set:{value in Task { await services.setLogin(value) } }),disabled:services.loginBusy)
                        settingsDivider
                        AlignedPreferenceToggle(title:"复制后显示趣味文案",icon:"sparkles",isOn:$copyMessagesEnabled)
                        settingsDivider
                        AutomationSettingsEntry(automation:automation)
                        settingsDivider
                        PreferenceRow(title: "编辑快捷键", icon: "keyboard", controlWidth: 190) {
                            Button {
                                showsShortcutSettings = true
                            } label: {
                                Label("配置快捷键", systemImage: "chevron.right")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.16)))
                            }
                            .buttonStyle(ReminderTimeRowStyle())
                            .accessibilityValue("换行 \(shortcuts.newline.accessibleLabel)，下一栏 \(shortcuts.next.accessibleLabel)")
                            .sheet(isPresented: $showsShortcutSettings) {
                                ShortcutSettings(shortcuts: shortcuts) { updated in
                                    try updated.save(to: Runtime.defaults)
                                    shortcuts = updated
                                }
                            }
                        }

                    }.background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(Color.primary.opacity(0.08)))
                    if let error=services.error { Text(error).font(.system(size:12)).foregroundStyle(.orange) }
                    if services.needsPermissionHelp { Button("打开系统设置") { services.openRelevantSettings() }.buttonStyle(.link) }
                }
                VStack(alignment:.leading,spacing:10) {
                    Text("数据与工具").font(.system(size:16,weight:.semibold))
                    VStack(spacing:0) {
                        toolRow("检查更新…",icon:"arrow.triangle.2.circlepath",action:{updater.check()})
                            .disabled(!updater.canCheck)
                            .help("当前版本 \(updater.version)")
                        settingsDivider
                        toolRow(services.testSubmitting ? "提交中…" : "测试提醒",icon:"bell.badge",action:{
                            Task { await services.test();if services.testWasSubmitted && services.popupOn { show() } }
                        }).disabled(services.testSubmitting)
                        settingsDivider
                        toolRow("重新查看新手引导",icon:"arrow.counterclockwise",action:{model.beginOnboarding()})
                        settingsDivider
                        toolRow("在 Finder 中查看数据",icon:"folder",action:{
                            var directory:ObjCBool=false
                            if FileManager.default.fileExists(atPath:model.directory.path,isDirectory:&directory),directory.boolValue { NSWorkspace.shared.open(model.directory) }
                            else { model.problem="数据目录不存在：\(model.directory.path)" }
                        })
                        settingsDivider
                        toolRow("清空 Todo 数据",icon:"trash",danger:true,action:{NotificationCenter.default.post(name:.dailyTodoCleanStart,object:nil)})
                    }.background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(Color.primary.opacity(0.08)))
                    if let feedback=services.testFeedback {
                        VStack(alignment:.leading,spacing:5) {
                            Text(feedback).font(.system(size:12)).foregroundStyle(services.testWasSubmitted ? Theme.blue : Color.orange)
                            if services.testWasSubmitted { Text("横幅显示受系统通知样式与专注模式影响").font(.system(size:11)).foregroundStyle(.secondary) }
                            Button("打开通知设置") { services.openNotificationSettings() }.buttonStyle(.link).font(.system(size:12))
                        }
                    }
                }
            }.padding(.horizontal,24).padding(.bottom,24)
        }.onAppear { Task { await services.refresh() } }
    }
    var settingsDivider:some View { Divider().padding(.leading,50) }
    func toolRow(_ title:String,icon:String,danger:Bool=false,action:@escaping ()->Void) -> some View {
        Button(action:action) {
            HStack(spacing:12) {
                Image(systemName:icon).font(.system(size:16)).foregroundStyle(danger ? Color.orange : Theme.blue).frame(width:22)
                Text(title).font(.system(size:14,weight:.medium)).foregroundStyle(danger ? Color.orange : Color.primary)
                Spacer();Image(systemName:"chevron.right").font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
            }.padding(.horizontal,16).frame(minHeight:52).contentShape(Rectangle())
        }.buttonStyle(ReminderTimeRowStyle())
    }
    var copyToast: some View {
        VStack(spacing:12) {
            Image(systemName:"checkmark").font(.system(size:22,weight:.bold)).foregroundStyle(.white)
                .frame(width:43,height:43).background(Color.white.opacity(0.18),in:Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3)))
            Text(automation.busy ? automation.progress : copyToastTitle).font(.system(size:18,weight:.semibold)).foregroundStyle(.white)
            if automation.busy { Button("取消操作") {automation.cancel()}.buttonStyle(.bordered).tint(.white) }
            if let feedback=feishuFeedback {
                Text(feedback).font(.system(size:13)).foregroundStyle(.white).multilineTextAlignment(.center)
            }
            if let message = toastMessage {
                Rectangle().fill(Color.white.opacity(0.24)).frame(height:1).padding(.horizontal,14).padding(.vertical,3)
                Text(message).font(.system(size:15,weight:.medium)).foregroundStyle(Color.white.opacity(0.98))
                    .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
            }
        }.padding(24).frame(maxWidth:.infinity,minHeight:toastMessage == nil ? 144 : 165)
            .background {
                RoundedRectangle(cornerRadius:24).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius:24).fill(LinearGradient(colors:[Color(red:0.07,green:0.28,blue:0.76).opacity(0.96),Color(red:0.01,green:0.42,blue:0.68).opacity(0.94)],startPoint:.topLeading,endPoint:.bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius:24).stroke(LinearGradient(colors:[.white.opacity(0.65),.white.opacity(0.12)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1))
            .shadow(color:Color.blue.opacity(0.28),radius:24,y:12)
            .accessibilityElement(children:automation.busy ? .contain : .combine)
    }
    func copy() {performCopy(forward:true)}
    func copyOnly() {performCopy(forward:false)}
    func performCopy(forward:Bool) {
        let shouldForward=forward && automation.configuration.enabled
        guard !showsShortcutSettings && !automation.busy else { return }
        editorFocus.commitComposition()
        model.activate()
        guard model.entry.day == ReminderRules.day(Date()) else { model.problem = "当天记录尚未加载，复制已暂停，请先解决保存错误。"; return }
        let snapshot=model.entry
        if shouldForward && [snapshot.tasks,snapshot.progress,snapshot.blockers].allSatisfy({$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) {model.problem="请先填写 Todo，再转发。";return}
        guard model.flush() else {return}
        flashTask?.cancel()
        if model.page == "today" && !reduceMotion {
            copyFlash=true
            flashTask=Task { @MainActor in
                do {try await Task.sleep(nanoseconds:150_000_000)}catch{return}
                guard !Task.isCancelled else{return}
                withAnimation(.easeOut(duration:0.12)) {copyFlash=false}
            }
        }
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        if pasteboard.setString(CopyFormatter.text(snapshot),forType:.string) {
            services.recordCopiedToday()
            feishuFeedback=nil
            copyToastTitle="已复制到剪贴板"
            toastTask?.cancel(); copied = true
            toastMessage = copyMessagesEnabled ? messagePicker.next() : nil
            if let message = toastMessage { Runtime.defaults.set(message,forKey:"lastCopyMessage") }
            withAnimation(.easeOut(duration:reduceMotion ? CopyFeedbackTiming.reducedEnter : CopyFeedbackTiming.enter)) { toastVisible = true }
            if shouldForward {
                automation.forward(text:CopyFormatter.text(snapshot),day:snapshot.day) {outcome in
                    copyToastTitle=outcome.title;feishuFeedback=outcome.detail
                    dismissFeedbackLater()
                }
            } else {dismissFeedbackLater()}
        } else {
            toastTask?.cancel(); toastVisible = false; copied = false
            model.problem = "写入剪贴板失败，请重试。未复制成功。"
        }
    }
    func dismissFeedbackLater() {
        toastTask?.cancel()
        toastTask=Task { @MainActor in
            do {try await Task.sleep(nanoseconds:UInt64(CopyFeedbackTiming.dismissDelay(reduceMotion:reduceMotion)*1_000_000_000))}catch{return}
            guard !Task.isCancelled else{return}
            withAnimation(.easeInOut(duration:CopyFeedbackTiming.fade)) {toastVisible=false;copied=false}
        }
    }

}
