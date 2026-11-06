import SwiftUI
import AppKit

struct AutomationSettingsCard:View {
    @ObservedObject var automation:FeishuAutomationController
    let dismiss:()->Void
    @State private var draft=FeishuAutomationConfiguration()
    @State private var error:String?
    @State private var trusted=false
    private let blue=Color(nsColor:.systemBlue)
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Label("飞书自动化",systemImage:"paperplane.fill").font(.system(size:22,weight:.semibold)).foregroundStyle(blue)
            AlignedPreferenceToggle(title:"启用一键转发",icon:"paperplane.fill",isOn:$draft.enabled)
                .background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
            VStack(alignment:.leading,spacing:8) {
                Text("收件人").font(.headline)
                TextField("飞书联系人姓名",text:$draft.recipient).textFieldStyle(.roundedBorder).disabled(Runtime.sessionID != nil)
                if Runtime.sessionID != nil {Text("测试版本固定发给安龙，不会发给正式联系人。").font(.caption).foregroundStyle(.secondary)}
            }
            VStack(alignment:.leading,spacing:8) {
                Text("点击后的操作").font(.headline)
                Picker("发送方式",selection:$draft.mode) {
                    ForEach(FeishuDeliveryMode.allCases,id:\.self) {Text($0.title).tag($0)}
                }.pickerStyle(.segmented)
                Text(draft.mode == .send ? "核对联系人和正文后直接发送，同一份内容不会重复发送。" : "打开指定聊天并填入内容，由你检查后发送。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Text("⌘⇧C 始终只复制，不会自动发送。").font(.caption).foregroundStyle(.secondary)
            Toggle("收件人是我自己",isOn:$draft.recipientIsSelf).font(.system(size:12)).disabled(Runtime.sessionID != nil)
            HStack {
                Image(systemName:trusted ? "checkmark.shield.fill" : "lock.shield").foregroundStyle(trusted ? blue : .secondary)
                Text(trusted ? "辅助功能已允许" : "辅助功能未允许").font(.system(size:13))
                Spacer()
                Button(trusted ? "系统设置" : "前往授权") {automation.requestPermission();trusted=automation.trusted}.buttonStyle(.bordered)
            }
            if !trusted {Text("如果系统列表已开启但这里仍未允许，请移除本应用后重新添加，再重启应用。").font(.caption).foregroundStyle(.secondary)}
            Text("转发会使用剪贴板，请勿同时复制或切换聊天。未登录、对象不明确或已有草稿时会停止，Todo 仍会复制到剪贴板。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let error {Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
            HStack {
                Button("取消",action:dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("完成") {
                    do {try automation.save(draft);dismiss()}
                    catch {self.error=error.localizedDescription}
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:470).fixedSize(horizontal:false,vertical:true)
            .background(Color(nsColor:.windowBackgroundColor)).tint(blue)
            .onAppear {draft=automation.effectiveConfiguration;trusted=automation.trusted}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in trusted=automation.trusted}
    }
}

struct AutomationSettingsEntry:View {
    @ObservedObject var automation:FeishuAutomationController
    @State private var presented=false
    var body:some View {
        Button {presented=true} label:{
            PreferenceRow(title:"一键转发瑶总",icon:"paperplane.fill",controlWidth:140) {
                HStack(spacing:6) {
                    Text(automation.configuration.enabled ? automation.configuration.mode.title : "未开启")
                    Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold))
                }.font(.system(size:12,weight:.medium)).foregroundStyle(.white)
                    .padding(.horizontal,10).frame(height:30)
                    .background(Color(white:0.17),in:RoundedRectangle(cornerRadius:8))
            }.contentShape(Rectangle())
        }.buttonStyle(ReminderTimeRowStyle()).disabled(automation.busy).accessibilityLabel("配置飞书自动化")
            .accessibilityValue(automation.configuration.enabled ? automation.configuration.mode.title : "未开启")
            .sheet(isPresented:$presented) {AutomationSettingsCard(automation:automation) {presented=false}}
    }
}
