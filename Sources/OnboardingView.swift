import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var model:Model
    @ObservedObject var services:Services
    @ObservedObject var automation:FeishuAutomationController
    @ObservedObject private var permissions=AccessibilityPermission.shared
    @State private var step=CommandLine.arguments.contains("--resume-onboarding-forwarding") ? 2 : 0
    @State private var draft:ReminderTime = .defaultTime
    @State private var saving=false
    private let blue=Color(nsColor:.systemBlue)
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:9) {
                if let image=NSImage(named:"BrandLogo") { Image(nsImage:image).resizable().scaledToFit().frame(width:34,height:34).accessibilityHidden(true) }
                Text("Daily Todo").font(.system(size:17,weight:.semibold))
                Spacer()
                Button("跳过") { model.finishOnboarding(completed:false) }.buttonStyle(NavigationButtonStyle())
            }.padding(.horizontal,24).padding(.top,20)
            HStack(spacing:7) {
                ForEach(0..<4,id:\.self) { index in Circle().fill(index == step ? blue : Color.secondary.opacity(0.25)).frame(width:6,height:6) }
            }.accessibilityLabel("第\(step+1)页，共4页").padding(.top,14).padding(.bottom,20)
            ScrollView {
                VStack(spacing:20) {
                    Text(["几点提醒？","开启提醒","开启一键转发","设置完成"][step]).font(.system(size:26,weight:.semibold))
                        .accessibilityAddTraits(.isHeader)
                    switch step {
                    case 0: timePage
                    case 1: reminderPage
                    case 2: automationPage
                    default: donePage
                    }
                }.padding(.horizontal,28).padding(.bottom,18).frame(maxWidth:.infinity)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack {
                if step > 0 { Button { step -= 1 } label: { Label("上一步",systemImage:"chevron.left") }.buttonStyle(NavigationButtonStyle()) }
                Spacer()
                Button(step == 3 ? "开始使用" : saving ? "保存中…" : "下一步") { advance() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (step == 0 && (services.busy || !draft.isValid)))
            }.padding(.horizontal,24).padding(.vertical,18)
        }.frame(width:min(560,(NSScreen.main?.visibleFrame.width ?? 900)-60),height:min(510,(NSScreen.main?.visibleFrame.height ?? 900)-90))
            .background {
                ZStack {
                    Color(nsColor:.windowBackgroundColor)
                    LinearGradient(colors:[blue.opacity(0.11),Color.cyan.opacity(0.025),.clear],startPoint:.topLeading,endPoint:.bottomTrailing)
                }
            }.tint(blue)
            .onAppear { draft=services.config.time;permissions.startMonitoring();Task { await services.refresh() } }
            .onDisappear {permissions.stopMonitoring()}
            .onExitCommand { model.finishOnboarding(completed:false) }
    }
    var timePage:some View {
        VStack(spacing:15) {
            ReminderTimePicker(time:$draft,onEscape:{model.finishOnboarding(completed:false)})
            Text("工作日提醒，可随时修改").font(.system(size:12)).foregroundStyle(.secondary)
            if let error=services.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
    var reminderPage:some View {
        VStack(spacing:12) {
            VStack(spacing:0) {
                AlignedPreferenceToggle(title:"系统通知",icon:"bell",help:services.notificationHelp,isOn:Binding(get:{services.notificationsOn},set:{value in Task { await services.setNotificationsFromGuide(value) } }),disabled:services.busy)
                rowDivider
                AlignedPreferenceToggle(title:"自动弹窗",icon:"macwindow",help:services.popupHelp,isOn:Binding(get:{services.popupOn},set:{value in Task { await services.setPopupFromGuide(value) } }),disabled:services.busy)
                rowDivider
                AlignedPreferenceToggle(title:"开机启动",icon:"power",help:services.loginHelp,isOn:Binding(get:{services.login},set:{value in Task { await services.setLogin(value) } }),disabled:services.loginBusy)
            }.background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(blue.opacity(0.14)))
            if let error=services.error { Text(error).font(.system(size:12)).foregroundStyle(.orange).textSelection(.enabled) }
            if services.needsPermissionHelp { Button("打开系统设置") { services.openRelevantSettings() }.buttonStyle(.link) }
        }
    }
    var automationPage:some View {
        AutomationSettingsEntry(automation:automation,prominent:true,onConfigured:{step=3})
            .frame(maxWidth:300).padding(.top,7)
    }
    var donePage:some View {
        VStack(spacing:24) {
            Image(systemName:"checkmark.circle.fill").font(.system(size:76)).foregroundStyle(blue)
                .accessibilityHidden(true).padding(.top,4)
            VStack(spacing:0) {
                completionRow(title:"提醒时间",icon:"clock",value:services.config.time.text)
                rowDivider
                completionRow(title:"提醒方式",icon:"bell",value:reminderStatus)
                rowDivider
                completionRow(title:"一键转发 Todo",icon:"paperplane.fill",value:automation.configuration.summary)
            }
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(blue.opacity(0.12)))
        }
    }
    private var reminderStatus:String {
        switch (services.notificationsOn,services.popupOn) {
        case (true,true): return "通知、弹窗"
        case (true,false): return "系统通知"
        case (false,true): return "自动弹窗"
        default: return "未开启"
        }
    }
    private func completionRow(title:String,icon:String,value:String)->some View {
        HStack(spacing:12) {
            Image(systemName:icon).font(.system(size:15)).foregroundStyle(blue).frame(width:22)
            Text(title).font(.system(size:13,weight:.medium))
            Spacer(minLength:12)
            Text(value).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
        }.padding(.horizontal,16).frame(minHeight:44)
    }
    var rowDivider:some View { Divider().padding(.leading,50) }
    func advance() {
        if step == 0 {
            saving=true
            Task { let saved=await services.apply(time:draft);saving=false;if saved && step == 0 && model.showOnboarding { step=1 } }
        } else if step < 3 { step += 1 }
        else { model.finishOnboarding(completed:true) }
    }
}
