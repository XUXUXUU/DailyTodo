import SwiftUI
import AppKit

struct AutomationSettingsCard:View {
    @ObservedObject var automation:FeishuAutomationController
    @ObservedObject private var permissions=AccessibilityPermission.shared
    var onSaved:()->Void = {}
    let dismiss:()->Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft=FeishuAutomationConfiguration()
    @State private var error:String?
    @State private var saved=false
    @State private var showsRecovery=false
    private let blue=Color(nsColor:.systemBlue)
    private var cardWidth:CGFloat {min(536,(NSScreen.screens.map {$0.visibleFrame.width}.min() ?? 900)-48)}
    private var cardHeight:CGFloat {min(feedbackMessage == nil ? 400 : 440,(NSScreen.screens.map {$0.visibleFrame.height}.min() ?? 900)-64)}
    private var compact:Bool {cardHeight<390}
    private var canSave:Bool {!automation.busy && (!draft.enabled || permissions.ready)}

    var body:some View {
        Group {
            if saved {savedPage.transition(.opacity)}
            else {settingsPage.transition(.opacity)}
        }
        .frame(width:cardWidth,height:saved ? min(230,cardHeight) : cardHeight)
        .background {
            Color(nsColor:.windowBackgroundColor)
            LinearGradient(colors:[blue.opacity(0.10),.clear],startPoint:.topLeading,endPoint:.bottomTrailing)
        }
        .tint(blue)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:saved)
        .interactiveDismissDisabled(automation.busy || saved)
        .onAppear {draft=automation.configuration;automation.clearFeedback();permissions.startMonitoring()}
        .onDisappear {permissions.stopMonitoring()}
        .task(id:saved) {
            guard saved else{return}
            do {try await Task.sleep(nanoseconds:750_000_000)} catch {return}
            guard !Task.isCancelled else{return}
            onSaved();dismiss()
        }
    }
    private var settingsPage:some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:compact ? 8 : 10) {
                HStack(spacing:12) {
                    AutomationPaperplaneIcon(size:36)
                    Text("一键转发 Todo").font(.system(size:22,weight:.semibold)).accessibilityAddTraits(.isHeader)
                }.frame(maxWidth:.infinity,alignment:.leading)
                permissionSection
                VStack(alignment:.leading,spacing:8) {
                    Text("选择转发方式").font(.system(size:14,weight:.semibold)).accessibilityAddTraits(.isHeader)
                    HStack(alignment:.top,spacing:10) {deliveryCard(.draft);deliveryCard(.send)}
                        .disabled(automation.busy || !permissions.ready)
                }
                Button {
                    guard permissions.ready,draft.enabled,!automation.busy else{return}
                    error=nil;automation.testSelf(mode:draft.mode)
                } label:{
                    Label("发给自己测试",systemImage:"paperplane.fill")
                        .font(.system(size:16,weight:.semibold)).foregroundStyle(.white)
                        .frame(maxWidth:.infinity).frame(height:48)
                        .background(blue.opacity(permissions.ready && draft.enabled ? 1 : 0.35),in:RoundedRectangle(cornerRadius:11))
                }
                .buttonStyle(.plain).disabled(automation.busy || !permissions.ready || !draft.enabled)
                .help(draft.mode == .draft ? "把示例填入飞书本人聊天框，不发送" : "自动发送示例至飞书本人会话")
                if let message=feedbackMessage {
                    HStack(alignment:.top,spacing:8) {
                        if automation.busy {ProgressView().controlSize(.small)}
                        Text(message).font(.system(size:12))
                            .foregroundStyle(error != nil ? Color.orange : Color.primary)
                            .lineLimit(2).help(message).accessibilityLabel(message)
                    }.frame(maxWidth:.infinity,minHeight:28,alignment:.leading)
                }
            }
            .padding(compact ? 12 : 16)
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            Divider()
            HStack {
                Button {
                    if automation.busy {automation.cancel()} else {dismiss()}
                } label:{footerLabel(automation.busy ? "取消操作" : "取消",primary:false)}
                .keyboardShortcut(.cancelAction).buttonStyle(.plain)
                Spacer(minLength:16)
                Button(action:save) {footerLabel("保存",primary:true)}
                    .keyboardShortcut(.defaultAction).buttonStyle(.plain).disabled(!canSave)
            }.padding(.horizontal,16).padding(.vertical,12)
        }
    }
    private func footerLabel(_ title:String,primary:Bool)->some View {
        Text(title).font(.system(size:14,weight:.semibold))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .frame(width:132,height:40)
            .background(primary ? blue.opacity(canSave ? 1 : 0.35) : Color.secondary.opacity(0.12),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(primary ? Color.clear : Color.secondary.opacity(0.16)))
            .contentShape(Rectangle())
    }
    private var permissionSection:some View {
        HStack(spacing:10) {
            Image(systemName:"hand.raised.fill").foregroundStyle(blue).frame(width:20)
            Text("辅助功能").font(.system(size:14,weight:.semibold))
            Spacer(minLength:8)
            switch permissions.status {
            case .checking:
                Text("检测中…").font(.system(size:12)).foregroundStyle(.secondary)
            case .allowed:
                Label("已开启",systemImage:"checkmark.circle.fill").font(.system(size:12,weight:.medium)).foregroundStyle(blue)
            case .restartRequired:
                Button("重启继续") {permissions.restart()}.buttonStyle(.borderedProminent).controlSize(.small)
            case .notGranted:
                if permissions.hasOpenedSettings {
                    Button("未能成功？") {showsRecovery=true}
                        .font(.system(size:12)).buttonStyle(.link)
                        .popover(isPresented:$showsRecovery) {
                            VStack(spacing:14) {
                                Text("移除旧项，再拖入图标并开启")
                                    .font(.system(size:14,weight:.semibold))
                                HStack(spacing:18) {
                                    AccessibilityAppDragIcon(size:48)
                                    Image(systemName:"arrow.right").foregroundStyle(blue)
                                    Image(systemName:"list.bullet.rectangle").font(.system(size:34)).foregroundStyle(blue)
                                }
                                RevealCurrentAppButton {NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
                            }.padding(20).frame(width:280)
                        }
                }
                Button("前往设置") {automation.requestPermission()}.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.horizontal,12).frame(height:44)
        .background(blue.opacity(0.06),in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(blue.opacity(0.20)))
        .disabled(automation.busy)
    }
    private func deliveryCard(_ mode:FeishuDeliveryMode)->some View {
        let selected=draft.enabled && draft.mode == mode
        let explanation=mode == .draft ? "仅填入聊天框，由你点击发送" : "填入聊天后自动发送"
        return Button {
            guard permissions.ready,!automation.busy else{return}
            draft.mode=mode;draft.enabled=true;error=nil;automation.clearFeedback()
        } label:{
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:7) {
                    Image(systemName:selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? blue : .secondary)
                    Text(mode.title).font(.system(size:14,weight:.semibold))
                }
                AutomationChatPreview(mode:mode,height:compact ? 64 : 76)
            }
            .padding(8).frame(maxWidth:.infinity,alignment:.topLeading)
            .background(selected ? blue.opacity(0.055) : Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:13))
            .overlay(RoundedRectangle(cornerRadius:13).strokeBorder(selected ? blue : Color.secondary.opacity(0.20),lineWidth:selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius:13))
        }
        .buttonStyle(.plain).accessibilityElement(children:.ignore)
        .accessibilityLabel("\(mode.title)，\(explanation)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var feedbackMessage:String? {
        if automation.busy {return automation.progress}
        return error ?? permissions.error ?? automation.testResult
    }
    private var savedPage:some View {
        VStack(spacing:16) {
            Image(systemName:"checkmark.circle.fill").font(.system(size:58)).foregroundStyle(blue).accessibilityHidden(true)
            Text("设置已保存").font(.system(size:22,weight:.semibold)).accessibilityAddTraits(.isHeader)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func save() {
        guard canSave else{return}
        do {try automation.save(draft);error=nil;saved=true}
        catch {self.error=error.localizedDescription}
    }
}

private struct AutomationChatPreview:View {
    let mode:FeishuDeliveryMode
    let height:CGFloat
    private let blue=Color(nsColor:.systemBlue)
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:6) {
                Image(systemName:"person.crop.circle.fill").font(.system(size:11)).foregroundStyle(.secondary)
                Text("何雪瑶").font(.system(size:9,weight:.medium))
                Spacer(minLength:0)
                Image(systemName:"ellipsis").font(.system(size:9)).foregroundStyle(.secondary)
            }.padding(.horizontal,7).frame(height:22)
            Divider()
            VStack(alignment:.trailing,spacing:1) {
                if mode == .send {
                    Text("Todo · 示例")
                        .font(.system(size:8))
                        .padding(.horizontal,6).padding(.vertical,3)
                        .background(blue.opacity(0.13),in:RoundedRectangle(cornerRadius:5))
                    Label("已自动发送",systemImage:"checkmark")
                        .font(.system(size:7)).foregroundStyle(.secondary)
                } else {
                    Text("等待你发送").font(.system(size:9,weight:.medium)).foregroundStyle(blue)
                        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.center)
                }
            }
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.trailing)
            .padding(.horizontal,6).padding(.vertical,2)
            Divider()
            HStack(spacing:3) {
                Text(mode == .draft ? "Todo · 示例" : "输入消息…")
                    .font(.system(size:9))
                    .foregroundStyle(mode == .draft ? Color.primary : .secondary)
                if mode == .draft {Rectangle().fill(blue).frame(width:1,height:11)}
                Spacer(minLength:0)
                if mode == .draft {
                    Image(systemName:"hand.tap").font(.system(size:8)).foregroundStyle(blue)
                }
                Text("发送").font(.system(size:8,weight:.medium))
                    .foregroundStyle(mode == .draft ? blue : .secondary)
                    .padding(.horizontal,5).padding(.vertical,3)
                    .background(mode == .draft ? blue.opacity(0.10) : Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:4))
            }
            .padding(.horizontal,7).frame(height:mode == .draft ? 28 : 24)
            .background(Color(nsColor:.textBackgroundColor))
        }
        .frame(height:height)
        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:9))
        .clipShape(RoundedRectangle(cornerRadius:9))
        .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(Color.secondary.opacity(0.17)))
        .accessibilityHidden(true)
    }
}

struct AutomationSettingsEntry:View {
    @ObservedObject var automation:FeishuAutomationController
    @ObservedObject private var permissions=AccessibilityPermission.shared
    var prominent=false
    var onConfigured:()->Void = {}
    @State private var savedPending=false
    @State private var presented=false
    @State private var hovered=false

    private var enabled:Bool {automation.configuration.enabled}
    var body:some View {
        Group {
            if prominent {entryButton.buttonStyle(.plain)}
            else {entryButton.buttonStyle(ReminderTimeRowStyle())}
        }
        .disabled(automation.busy)
        .accessibilityLabel("一键转发 Todo")
        .accessibilityValue(automation.configuration.summary)
        .onAppear {
            permissions.startMonitoring()
            if prominent,Runtime.consumeForwardingResume() {presented=true}
        }
        .onDisappear {permissions.stopMonitoring()}
        .onReceive(NotificationCenter.default.publisher(for:AccessibilityPermission.prepareRestartNotification)) {_ in presented=false}
        .sheet(isPresented:$presented,onDismiss:{
            if savedPending {savedPending=false;onConfigured()}
        }) {AutomationSettingsCard(automation:automation,onSaved:{savedPending=true}) {presented=false}}
        .contextMenu {
            if automation.configuration.enabled {
                Button("关闭一键转发") {
                    var value=automation.configuration;value.enabled=false
                    do {try automation.save(value)} catch {permissions.error=error.localizedDescription}
                }.disabled(automation.busy)
            }
        }
    }

    private var entryButton:some View {
        Button {savedPending=false;presented=true} label:{
            Group {
                if prominent {
                    VStack(spacing:20) {
                        AutomationPaperplaneIcon(size:112,hovered:hovered)
                            .onHover {hovered=$0}
                        status
                    }.frame(maxWidth:.infinity).padding(.vertical,20)
                } else {
                    HStack(spacing:14) {
                        AutomationPaperplaneIcon(size:44,hovered:hovered)
                            .onHover {hovered=$0}
                        Text("一键转发 Todo").font(.system(size:14,weight:.medium))
                        Spacer(minLength:12)
                        status
                    }.padding(.horizontal,16).padding(.vertical,10).frame(maxWidth:.infinity)
                }
            }.contentShape(Rectangle())
        }
    }

    private var status:some View {
        HStack(spacing:7) {
            Text(automation.configuration.summary)
            Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold))
        }.font(.system(size:12,weight:.medium))
            .foregroundStyle(enabled ? Color(nsColor:.systemBlue) : .secondary)
            .padding(.horizontal,11).frame(height:30)
            .background(Color(nsColor:.systemBlue).opacity(enabled ? 0.12 : 0.06),in:Capsule())
    }
}

struct AutomationPaperplaneIcon:View {
    var size:CGFloat=80
    var hovered=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blue=Color(nsColor:.systemBlue)
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:size*0.26,style:.continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius:size*0.26,style:.continuous)
                        .fill(LinearGradient(colors:[Color(red:0.34,green:0.77,blue:1).opacity(0.84),blue.opacity(0.93)],startPoint:.topLeading,endPoint:.bottomTrailing))
                }
                .overlay {
                    RoundedRectangle(cornerRadius:size*0.26,style:.continuous)
                        .strokeBorder(LinearGradient(colors:[.white.opacity(0.75),.white.opacity(0.10),blue.opacity(0.3)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1)
                }
            Image(systemName:"paperplane.fill")
                .font(.system(size:size*0.43,weight:.medium)).foregroundStyle(.white)
                .rotationEffect(.degrees(-8))
                .shadow(color:blue.opacity(0.3),radius:2,y:2)
        }
        .frame(width:size,height:size)
        .shadow(color:blue.opacity(hovered ? 0.24 : 0.11),radius:hovered ? 13 : 7,y:4)
        .scaleEffect(hovered && !reduceMotion ? 1.025 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration:0.18),value:hovered)
        .accessibilityHidden(true)
    }
}
