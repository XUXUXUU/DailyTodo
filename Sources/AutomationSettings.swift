import SwiftUI
import AppKit

struct AutomationSettingsCard:View {
    @ObservedObject var automation:FeishuAutomationController
    let dismiss:()->Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft=FeishuAutomationConfiguration()
    @State private var error:String?
    @State private var trusted=false
    @State private var saved=false
    private let blue=Color(nsColor:.systemBlue)
    private let permissionPoll=Timer.publish(every:0.5,on:.main,in:.common).autoconnect()

    var body:some View {
        Group {
            if saved { savedPage.transition(.opacity) }
            else { settingsPage.transition(.opacity) }
        }
        .padding(24).frame(width:440).fixedSize(horizontal:false,vertical:true)
        .background {
            Color(nsColor:.windowBackgroundColor)
            LinearGradient(colors:[blue.opacity(0.10),.clear],startPoint:.topLeading,endPoint:.bottomTrailing)
        }
        .tint(blue)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:saved)
        .interactiveDismissDisabled(automation.busy)
        .onAppear {draft=automation.configuration;refreshPermission()}
        .onReceive(permissionPoll) {_ in refreshPermission()}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in refreshPermission()}
    }

    private var settingsPage:some View {
        VStack(spacing:16) {
            HStack(spacing:16) {
                AutomationPaperplaneIcon(size:64)
                Text("一键转发 Todo").font(.system(size:23,weight:.semibold))
                    .accessibilityAddTraits(.isHeader)
            }.frame(maxWidth:.infinity,alignment:.leading)
            VStack(spacing:0) {
                AlignedPreferenceToggle(title:"开启一键转发",icon:"paperplane.fill",isOn:Binding(
                    get:{draft.enabled},
                    set:{value in
                        refreshPermission()
                        if !value || trusted {draft.enabled=value;error=nil}
                    }
                ),disabled:automation.busy || (!trusted && !draft.enabled))
                Divider().padding(.leading,50)
                PreferenceRow(title:"收件人",icon:"person",controlWidth:100) {
                    Text("何雪瑶").font(.system(size:14,weight:.medium))
                }
            }
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(blue.opacity(0.12)))

            Picker("发送方式",selection:$draft.mode) {
                ForEach(FeishuDeliveryMode.allCases,id:\.self) {Text($0.title).tag($0)}
            }
            .pickerStyle(.segmented).disabled(automation.busy)

            HStack(spacing:9) {
                Image(systemName:trusted ? "checkmark.shield.fill" : "lock.shield")
                    .foregroundStyle(trusted ? blue : .secondary)
                Text("辅助功能").font(.system(size:13))
                Spacer()
                if trusted {
                    Text("已开启").font(.system(size:13,weight:.medium)).foregroundStyle(blue)
                } else {
                    Button("开启辅助功能") {automation.requestPermission();refreshPermission()}
                        .buttonStyle(.bordered).disabled(automation.busy)
                }
            }

            Button {testSelf()} label:{
                Label("发给自己测试",systemImage:"paperplane")
                    .frame(maxWidth:.infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(automation.busy || !trusted)

            feedback

            HStack {
                Button(automation.busy ? "取消操作" : "取消") {
                    if automation.busy {automation.cancel()}
                    else {dismiss()}
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存",action:save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(automation.busy || (draft.enabled && !trusted))
            }
        }
    }

    @ViewBuilder private var feedback:some View {
        if automation.busy {
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:9) {
                    ProgressView().controlSize(.small)
                    Text(automation.progress).font(.system(size:12))
                }
                if let name=automation.detectedSelfName {
                    Text("测试对象：\(name)").font(.system(size:12)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        } else if let error {
            Text(error).font(.system(size:12)).foregroundStyle(.orange)
                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                .textSelection(.enabled)
        } else if let result=automation.testResult ?? automation.lastResult {
            Text(result).font(.system(size:12)).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                .textSelection(.enabled)
        }
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
        }.frame(maxWidth:.infinity).padding(.vertical,32)
    }

    private func refreshPermission() {trusted=automation.trusted}

    private func testSelf() {
        refreshPermission()
        guard trusted,!automation.busy else {return}
        error=nil
        automation.testSelf()
    }

    private func save() {
        refreshPermission()
        guard !automation.busy, !draft.enabled || trusted else {return}
        do {try automation.save(draft);error=nil;saved=true}
        catch {self.error=error.localizedDescription}
    }
}

struct AutomationSettingsEntry:View {
    @ObservedObject var automation:FeishuAutomationController
    var prominent=false
    @State private var presented=false
    @State private var hovered=false
    @State private var trusted=false
    private let permissionPoll=Timer.publish(every:0.5,on:.main,in:.common).autoconnect()

    private var enabled:Bool {automation.configuration.enabled && trusted}
    var body:some View {
        Button {presented=true} label:{
            Group {
                if prominent {
                    VStack(spacing:20) {
                        AutomationPaperplaneIcon(size:112,hovered:hovered)
                        status
                    }.frame(maxWidth:.infinity).padding(.vertical,20)
                } else {
                    HStack(spacing:14) {
                        AutomationPaperplaneIcon(size:44,hovered:hovered)
                        Text("一键转发 Todo").font(.system(size:14,weight:.medium))
                        Spacer(minLength:12)
                        status
                    }.padding(.horizontal,16).padding(.vertical,10).frame(maxWidth:.infinity)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(ReminderTimeRowStyle()).disabled(automation.busy)
        .onHover {hovered=$0}
        .accessibilityLabel("一键转发 Todo")
        .accessibilityValue(enabled ? "开启" : "未开启")
        .onAppear {trusted=automation.trusted}
        .onReceive(permissionPoll) {_ in trusted=automation.trusted}
        .sheet(isPresented:$presented) {AutomationSettingsCard(automation:automation) {presented=false}}
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
