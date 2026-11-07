import SwiftUI
import AppKit

struct AutomationSettingsCard:View {
    @ObservedObject var automation:FeishuAutomationController
    @ObservedObject private var permissions=AccessibilityPermission.shared
    let dismiss:()->Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft=FeishuAutomationConfiguration()
    @State private var error:String?
    @State private var saved=false
    private let blue=Color(nsColor:.systemBlue)
    private var visibleWidth:CGFloat {NSScreen.screens.map { $0.visibleFrame.width }.min() ?? 900}
    private var visibleHeight:CGFloat {NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 900}
    private var cardWidth:CGFloat {min(536,visibleWidth-48)}
    private var cardHeight:CGFloat {min(620,visibleHeight-64)}
    private var compact:Bool {cardHeight<600}
    private var tight:Bool {cardHeight<520}
    private var contentPadding:CGFloat {tight ? 10 : compact ? 16 : 20}
    private var sectionSpacing:CGFloat {tight ? 6 : compact ? 10 : 14}
    private var previewHeight:CGFloat {tight ? 80 : cardHeight<550 ? 84 : compact ? 96 : 108}

    var body:some View {
        Group {
            if saved { savedPage.transition(.opacity) }
            else { settingsPage.transition(.opacity) }
        }
        .frame(width:cardWidth,height:saved ? min(360,cardHeight) : cardHeight)
        .background {
            Color(nsColor:.windowBackgroundColor)
            LinearGradient(colors:[blue.opacity(0.10),.clear],startPoint:.topLeading,endPoint:.bottomTrailing)
        }
        .tint(blue)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:saved)
        .interactiveDismissDisabled(automation.busy)
        .onAppear {draft=automation.configuration;permissions.startMonitoring()}
        .onDisappear {permissions.stopMonitoring()}
    }

    private var settingsPage:some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:sectionSpacing) {
                HStack(spacing:12) {
                    AutomationPaperplaneIcon(size:40)
                    Text("一键转发 Todo").font(.system(size:22,weight:.semibold))
                        .accessibilityAddTraits(.isHeader)
                }.frame(maxWidth:.infinity,alignment:.leading)
                permissionSection
                modeSection
                VStack(spacing:compact ? 4 : 6) {
                    Button {testSelf()} label:{
                        Label("发给自己测试",systemImage:"paperplane.fill")
                            .font(.system(size:16,weight:.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth:.infinity).frame(height:50)
                            .background(blue.opacity(permissions.ready ? 1 : 0.45),in:RoundedRectangle(cornerRadius:11))
                    }
                    .buttonStyle(.plain)
                    .disabled(automation.busy || !permissions.ready)
                    .accessibilityHint("测试会实际发送示例消息至飞书本人会话，与所选转发方式无关")
                    Text("测试会向你的飞书本人会话发送示例消息。")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
            }
            .padding(contentPadding)
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            Divider()
            VStack(alignment:.leading,spacing:compact ? 6 : 8) {
                feedback.frame(height:tight ? 26 : compact ? 28 : 32,alignment:.leading)
                HStack {
                    Button(automation.busy ? "取消操作" : "取消") {
                        if automation.busy {automation.cancel()}
                        else {dismiss()}
                    }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Text("保存后生效").font(.system(size:11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存",action:save)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(automation.busy || (draft.enabled && !permissions.ready))
                }.frame(minHeight:28)
            }
            .padding(.horizontal,contentPadding).padding(.vertical,tight ? 8 : compact ? 10 : 12)
        }
    }

    private var permissionSection:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:9) {
                stageHeading(1,title:"开启辅助功能",available:true)
                Spacer(minLength:8)
                permissionDetails
            }.frame(minHeight:28)
            if permissions.status == .notGranted {
                Button("开关已开但无效？") {automation.requestPermission(repair:true)}
                    .font(.system(size:11)).buttonStyle(.link)
                    .disabled(automation.busy)
                    .padding(.leading,32)
            }
        }
        .padding(tight ? 8 : compact ? 10 : 12)
        .frame(maxWidth:.infinity,minHeight:tight ? 64 : compact ? 68 : 76,alignment:.leading)
        .background(blue.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
        .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(blue.opacity(0.20)))
    }

    @ViewBuilder private var permissionDetails:some View {
        switch permissions.status {
        case .checking:
            ProgressView().controlSize(.small)
            Text("检测中…").font(.system(size:12)).foregroundStyle(.secondary)
        case .notGranted:
            HStack(spacing:8) {
                Text("未开启").font(.system(size:11)).foregroundStyle(.secondary)
                Button("前往设置") {automation.requestPermission()}
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("重检测") {Task {await permissions.refresh()}}
                    .buttonStyle(.link).font(.system(size:12))
            }.disabled(automation.busy)
        case .restartRequired:
            HStack(spacing:8) {
                Text("重启后生效").font(.system(size:11)).foregroundStyle(.secondary)
                Button("重启继续") {permissions.restart()}
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("授权已保存，重启后将回到此处继续设置")
                Button("重检测") {Task {await permissions.refresh()}}
                    .buttonStyle(.link).font(.system(size:12))
            }.disabled(automation.busy)
        case .allowed:
            Label("已开启",systemImage:"checkmark.circle.fill")
                .font(.system(size:12,weight:.medium)).foregroundStyle(blue)
        }
    }

    private var modeSection:some View {
        VStack(alignment:.leading,spacing:compact ? 8 : 10) {
            HStack {
                stageHeading(2,title:"选择转发方式",available:permissions.ready)
                Spacer()
                Button("仅复制") {draft.enabled=false;error=nil}
                    .buttonStyle(.link).disabled(automation.busy)
                    .accessibilityHint("关闭转发，主按钮恢复复制全部；保存后生效")
            }
            HStack(alignment:.top,spacing:10) {
                deliveryCard(.draft)
                deliveryCard(.send)
            }
            .disabled(automation.busy || !permissions.ready)
        }
    }

    private func deliveryCard(_ mode:FeishuDeliveryMode)->some View {
        let selected=draft.enabled && draft.mode == mode
        let explanation=mode == .draft ? "打开聊天并填入 Todo，由你在飞书点击发送。" : "打开聊天、填入 Todo，并自动发送。"
        return Button {
            guard permissions.ready,automation.trusted,!automation.busy else{return}
            draft.mode=mode;draft.enabled=true;error=nil
        } label:{
            VStack(alignment:.leading,spacing:compact ? 6 : 8) {
                HStack(spacing:7) {
                    Image(systemName:selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? blue : .secondary)
                    Text(mode.title).font(.system(size:14,weight:.semibold))
                }
                AutomationChatPreview(mode:mode,height:previewHeight)
                Text(explanation).font(.system(size:compact ? 11 : 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,minHeight:compact ? 30 : 36,alignment:.topLeading)
            }
            .padding(compact ? 8 : 10).frame(maxWidth:.infinity,alignment:.topLeading)
            .background(selected ? blue.opacity(0.055) : Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(selected ? blue : Color.secondary.opacity(0.20),lineWidth:selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius:14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(mode.title)，\(explanation)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stageHeading(_ number:Int,title:String,available:Bool)->some View {
        HStack(spacing:9) {
            Text("\(number)").font(.system(size:11,weight:.semibold))
                .foregroundStyle(available ? blue : .secondary)
                .frame(width:24,height:24)
                .background(available ? blue.opacity(0.12) : Color.secondary.opacity(0.10),in:Circle())
            Text(title).font(.system(size:14,weight:.semibold))
        }.accessibilityElement(children:.combine).accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var feedback:some View {
        if let message=feedbackMessage {
            HStack(alignment:.top,spacing:8) {
                if automation.busy {ProgressView().controlSize(.small)}
                Text(message).font(.system(size:compact ? 11 : 12))
                    .foregroundStyle(!automation.busy && (error ?? permissions.error) != nil ? Color.orange : .secondary)
                    .lineLimit(2).truncationMode(.tail).textSelection(.enabled)
                    .help(message).accessibilityLabel(message)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }

    private var feedbackMessage:String? {
        if automation.busy {
            return automation.progress+(automation.detectedSelfName.map {"\n测试对象：\($0)"} ?? "")
        }
        return error ?? permissions.error ?? automation.testResult ?? automation.lastResult
    }

    private var savedPage:some View {
        VStack(spacing:22) {
            Image(systemName:"checkmark.circle.fill")
                .font(.system(size:76,weight:.regular)).foregroundStyle(blue)
                .accessibilityHidden(true)
            Text("设置已保存").font(.system(size:25,weight:.semibold))
                .accessibilityAddTraits(.isHeader)
            Button("返回",action:dismiss)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(24)
    }

    private func testSelf() {
        guard permissions.ready,automation.trusted,!automation.busy else {return}
        error=nil
        automation.testSelf()
    }

    private func save() {
        guard !automation.busy, !draft.enabled || (permissions.ready && automation.trusted) else {return}
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
                    Text("聊天记录").font(.system(size:8)).foregroundStyle(.tertiary)
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
    @State private var presented=false
    @State private var hovered=false

    private var enabled:Bool {automation.configuration.enabled && permissions.ready && automation.trusted}
    var body:some View {
        Group {
            if prominent {entryButton.buttonStyle(.plain)}
            else {entryButton.buttonStyle(ReminderTimeRowStyle())}
        }
        .disabled(automation.busy)
        .accessibilityLabel("一键转发 Todo")
        .accessibilityValue(enabled ? "开启" : "未开启")
        .onAppear {
            permissions.startMonitoring()
            if prominent,Runtime.consumeForwardingResume() {presented=true}
        }
        .onDisappear {permissions.stopMonitoring()}
        .onReceive(NotificationCenter.default.publisher(for:AccessibilityPermission.prepareRestartNotification)) {_ in presented=false}
        .sheet(isPresented:$presented) {AutomationSettingsCard(automation:automation) {presented=false}}
    }

    private var entryButton:some View {
        Button {presented=true} label:{
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
            Text(enabled ? "开启" : "未开启")
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
