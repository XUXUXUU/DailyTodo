import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var model:Model
    @ObservedObject var services:Services
    @State private var step=0
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
                ForEach(0..<3,id:\.self) { index in Circle().fill(index == step ? blue : Color.secondary.opacity(0.25)).frame(width:6,height:6) }
            }.accessibilityLabel("第\(step+1)页，共3页").padding(.top,14).padding(.bottom,20)
            ScrollView {
                VStack(spacing:20) {
                    Text(["几点提醒？","开启提醒","设置完成"][step]).font(.system(size:26,weight:.semibold))
                    switch step {
                    case 0: timePage
                    case 1: reminderPage
                    default: donePage
                    }
                }.padding(.horizontal,28).padding(.bottom,18).frame(maxWidth:.infinity)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack {
                if step > 0 { Button { step -= 1 } label: { Label("上一步",systemImage:"chevron.left") }.buttonStyle(NavigationButtonStyle()) }
                Spacer()
                Button(step == 2 ? "开始使用" : saving ? "保存中…" : "下一步") { advance() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(saving || (step == 0 && (services.busy || !draft.isValid)))
            }.padding(.horizontal,24).padding(.vertical,18)
        }.frame(width:min(560,(NSScreen.main?.visibleFrame.width ?? 900)-60),height:min(510,(NSScreen.main?.visibleFrame.height ?? 900)-90))
            .background {
                ZStack {
                    Color(nsColor:.windowBackgroundColor)
                    LinearGradient(colors:[blue.opacity(0.11),Color.cyan.opacity(0.025),.clear],startPoint:.topLeading,endPoint:.bottomTrailing)
                }
            }.tint(blue)
            .onAppear { draft=services.config.time;Task { await services.refresh() } }
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
    var donePage:some View {
        VStack(spacing:18) {
            Image(systemName:"checkmark.circle.fill").font(.system(size:42)).foregroundStyle(blue).padding(.top,28)
            Text("以后可以在设置中修改").font(.system(size:14)).foregroundStyle(.secondary)
            if !services.notificationsOn && !services.popupOn { Text("提醒尚未开启").font(.system(size:12)).foregroundStyle(.secondary) }
        }
    }
    var rowDivider:some View { Divider().padding(.leading,50) }
    func advance() {
        if step == 0 {
            saving=true
            Task { let saved=await services.apply(time:draft);saving=false;if saved && step == 0 && model.showOnboarding { step=1 } }
        } else if step == 1 { step=2 }
        else { model.finishOnboarding(completed:true) }
    }
}
