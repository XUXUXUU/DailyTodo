import SwiftUI
import AppKit
import UserNotifications
@MainActor final class Model: ObservableObject {
    @Published var entry = Entry(day: ReminderRules.day(Date()))
    @Published var saveStatus = "加载中…"
    @Published var problem: String?
    @Published var page = "today"
    @Published var path = ["today"]
    @Published var showOnboarding = false
    private var onboardingExitRecorded = false
    func beginOnboarding() {
        guard !showOnboarding else { return }; flush()
        onboardingExitRecorded = false; Runtime.defaults.set(true,forKey:"onboardingSeen")
        showOnboarding = true
    }
    func finishOnboarding(completed: Bool) {
        onboardingExitRecorded = true
        Runtime.defaults.set(15,forKey:"onboardingFlowVersion")
        Runtime.defaults.set(completed,forKey:"onboardingCompleted")
        Runtime.defaults.set(!completed,forKey:"onboardingSkipped")
        Runtime.defaults.set(true,forKey:"onboarded")
        showOnboarding = false; home()
    }
    func onboardingSheetClosed() { if !onboardingExitRecorded { finishOnboarding(completed:false) } }
    func go(_ destination: String) {
        flush(); if path.last != destination { path.append(destination) }; page = destination
    }
    func back() { if path.count > 1 { path.removeLast() }; page = path.last ?? "today"; if page == "today" { activate() } }
    func home() { path = ["today"]; page = "today"; activate() }
    @Published var revision = 0
    var versions=DraftVersions()
    var dayClock:()->Date = {Date()}
    private(set) var deferredDays=[String:Entry]()
    var store: Store?
    var pending: DispatchWorkItem?
    let directory = Runtime.dataDirectory
    init() {
        do { store = try Store(directory: directory); problem = store?.warning; try loadToday() }
        catch { problem = "无法读取数据，已停止覆盖文件：\(error.localizedDescription)"; saveStatus = "加载失败" }
    }
    func loadToday() throws {
        guard let store else { return }
        let day = ReminderRules.day(dayClock())
        if entry.day != day || saveStatus == "加载中…" {
            guard flush() else { throw CocoaError(.fileWriteUnknown) }
            entry = try store.entry(day: day); revision += 1
            saveStatus = "已自动保存"
        }
    }
    func reloadAfterCleanStart() throws {
        pending?.cancel(); pending = nil
        store = try Store(directory:directory)
        versions=DraftVersions();entry = Entry(day:ReminderRules.day(Date())); problem = nil; saveStatus = "已自动保存"; revision += 1
        home()
    }
    func activate() { do { try loadToday() } catch { problem = error.localizedDescription; saveStatus = "保存失败" } }
    func edit(_ key: WritableKeyPath<Entry,String>, _ value: String) {
        if entry.day != ReminderRules.day(dayClock()) {
            // 本次变化属于新日；先落盘昨日已提交草稿，再继承今日，不把新字符写进昨日。
            do {try loadToday()}catch {let oldDay=entry.day;deferredDays[oldDay]=entry;entry.day=ReminderRules.day(dayClock());entry.id=UUID();entry.inheritedFromDate=oldDay;problem="跨日保存失败，最新草稿仍保留，需重试：\(error.localizedDescription)";saveStatus="保存失败";entry[keyPath:key]=value;versions.changed();return}
        }
        guard entry[keyPath:key] != value else {return}
        entry[keyPath:key] = value; entry.updatedAt = Date(); versions.changed()
        if saveStatus != "待保存" {saveStatus = "待保存"}
        pending?.cancel()
        let scheduledRevision=versions.current
        let work=DispatchWorkItem { [weak self] in
            guard let self, self.versions.current == scheduledRevision else {return}
            self.flush()
        };pending=work
        DispatchQueue.main.asyncAfter(deadline:.now()+3,execute:work)
    }
    @discardableResult func flush() -> Bool {
        pending?.cancel();pending=nil
        guard let store else {return false}
        guard versions.dirty || saveStatus == "保存失败" else {return true}
        let snapshot=entry, writingRevision=versions.current
        // MainActor无await：写入严格串行；只记录确认版本，不把快照回写正文。
        do {
            for day in deferredDays.keys.sorted() {
                if let unsaved=deferredDays[day] {try store.save(unsaved);deferredDays.removeValue(forKey:day)}
            }
            try store.save(snapshot);versions.didSave(writingRevision)
            saveStatus="已自动保存";problem=nil;revision += 1
            EditorDiagnostics.record("saved",["revision":writingRevision,"day":snapshot.day])
            return true
        } catch {
            saveStatus="保存失败";problem="保存失败，最新输入仍保留在内存：\(error.localizedDescription)"
            EditorDiagnostics.record("save-failed",["revision":writingRevision]);return false
        }
    }

}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    let model = Model()
    let services = Services()
    let updater = AppUpdater()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var observers: [NSObjectProtocol] = []
    var cleanStartWaiting = false
    private var terminationWaiting=false
    private var requiredContentMin=NSSize(width:540,height:620)
    func windowWillResize(_ sender:NSWindow,to frameSize:NSSize)->NSSize {
        let minimum=sender.frameRect(forContentRect:NSRect(origin:.zero,size:requiredContentMin)).size
        return NSSize(width:max(frameSize.width,minimum.width),height:max(frameSize.height,minimum.height))
    }
    func windowDidResize(_ notification:Notification) {recordWindowMetrics()}
    func recordWindowMetrics() {
        guard let window else{return}
        Runtime.report("window-metrics",payload:["frameWidth":window.frame.width,"frameHeight":window.frame.height,"contentWidth":window.contentRect(forFrameRect:window.frame).width,"contentHeight":window.contentRect(forFrameRect:window.frame).height,"minimumWidth":requiredContentMin.width,"minimumHeight":requiredContentMin.height,"page":model.page])
    }
    func constrainWindow(page:String) {
        guard let window else{return}
        let minimum=NSSize(width:page == "today" ? 540 : 600,height:620)
        requiredContentMin=minimum;window.contentMinSize=minimum
        window.minSize=window.frameRect(forContentRect:NSRect(origin:.zero,size:minimum)).size
        var frame=window.frame
        let minimumFrame=window.frameRect(forContentRect:NSRect(origin:.zero,size:minimum)).size
        frame.size.width=max(frame.width,minimumFrame.width);frame.size.height=max(frame.height,minimumFrame.height)
        if let screen=(window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x=min(max(frame.origin.x,screen.minX),max(screen.minX,screen.maxX-frame.width))
            frame.origin.y=min(max(frame.origin.y,screen.minY),max(screen.minY,screen.maxY-frame.height))
        }
        window.setFrame(frame,display:true);recordWindowMetrics()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
#if INTEGRATION_TESTING
        if Runtime.sessionID != nil, CommandLine.arguments.contains("--integration-cleanup") {
            Task {
                let requests = await services.center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(services.prefix) }
                services.center.removePendingNotificationRequests(withIdentifiers:requests.map(\.identifier))
                let delivered = await services.center.deliveredNotifications().filter { $0.request.identifier.hasPrefix(services.prefix) }
                Runtime.report("cleanup-notifications",payload:["removedPending":requests.map(\.identifier),"delivered":delivered.map { ["id":$0.request.identifier,"date":ISO8601DateFormatter().string(from:$0.date),"title":$0.request.content.title,"body":$0.request.content.body] }])
                services.center.removeDeliveredNotifications(withIdentifiers:delivered.map { $0.request.identifier })
                try? await services.scheduler.apply(ReminderConfiguration(reminderEnabled:false,time:services.config.time))
                Runtime.event("cleanup-complete"); NSApp.terminate(nil)
            }
            return
        }
#endif
        let preferences = Runtime.defaults.persistentDomain(forName:Runtime.preferencesDomain) ?? [:]
        let notificationProbe = Runtime.sessionID != nil && CommandLine.arguments.contains("--integration-test-notification")
        let automatedInstallTest = Runtime.sessionID != nil && (CommandLine.arguments.contains("--integration-install") || CommandLine.arguments.contains("--integration-v17-scenarios") || notificationProbe)
        let isNewUser = !automatedInstallTest && OnboardingPolicy.shouldPresent(preferences:preferences,hasRecords:model.store?.entries.isEmpty == false || FileManager.default.fileExists(atPath:model.directory.appendingPathComponent("entries.json").path))
        if isNewUser || notificationProbe { services.initializeFreshUser() }
        if let iconURL = Bundle.main.url(forResource:"AppIcon",withExtension:"icns"), let icon = NSImage(contentsOf:iconURL) {
            NSApp.applicationIconImage = icon; NSApp.dockTile.display()
#if INTEGRATION_TESTING
            if Runtime.sessionID != nil, let tiff=NSApp.applicationIconImage.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) {
                try? png.write(to:Runtime.dataDirectory.appendingPathComponent("dock-icon.png"),options:.atomic)
            }
#endif
        }
        Runtime.event("app-launched")
        if Runtime.sessionID != nil, CommandLine.arguments.contains("--integration-light") { NSApp.appearance = NSAppearance(named:.aqua) }
        UNUserNotificationCenter.current().delegate = self
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:760), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title = Runtime.sessionID == nil ? "Daily Todo" : "Daily Todo · 集成测试"; window.contentMinSize = NSSize(width:540,height:620); window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: RootView(model:model, services:services, updater:updater, show:{ [weak self] in self?.show() },pageChanged:{ [weak self] page in self?.constrainWindow(page:page) }))
        window.center(); window.setFrameAutosaveName(Runtime.sessionID.map{"DailyTodoTest."+$0} ?? "DailyTodoMain");constrainWindow(page:model.page)
        services.onOfficialPopup={ [weak self] in self?.model.home();self?.show() }
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        if let button = statusItem.button {
            let base = NSFont.systemFont(ofSize:13,weight:.heavy)
            let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor:$0,size:13) } ?? base
            button.attributedTitle = NSAttributedString(string:"Todo",attributes:[.font:rounded])
            button.setAccessibilityLabel("Todo")
            button.toolTip = "Daily Todo"
        }
        let menu = NSMenu()
        for (title, selector) in [("打开 Daily Todo",#selector(openToday)),("历史记录",#selector(history)),("偏好设置",#selector(settings)),("退出",#selector(quit))] {
            let item = NSMenuItem(title:title, action:selector, keyEquivalent: title == "退出" ? "q" : ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
#if INTEGRATION_TESTING
        if let button = statusItem.button, Runtime.sessionID != nil {
            Runtime.report("status-wordmark",payload:[
                "title":button.attributedTitle.string,"hasImage":button.image != nil,
                "menu":menu.items.map(\.title),"width":button.frame.width
            ])
        }
#endif
        DispatchQueue.main.async {
            if let menu=NSApp.mainMenu { MenuLocalization.localize(menu) }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName:NSMenu.didBeginTrackingNotification,object:nil,queue:.main) { note in
                if let menu=note.object as? NSMenu { MenuLocalization.localize(menu) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName:name, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in self?.checkAutomatic(source:"wake") } })
        }
        observers.append(NotificationCenter.default.addObserver(forName:.NSSystemTimeZoneDidChange, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in await self?.services.refresh(); await self?.services.synchronizeNotifications(); self?.checkAutomatic(source:"wake") } })
        observers.append(NotificationCenter.default.addObserver(forName:NSNotification.Name.NSSystemClockDidChange, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in await self?.services.refresh(); self?.checkAutomatic(source:"wake") } })
        NotificationCenter.default.addObserver(self,selector:#selector(cleanStart),name:.dailyTodoCleanStart,object:nil)
        if isNewUser || !Runtime.defaults.bool(forKey:"onboarded") { model.home(); show() }
        else if !CommandLine.arguments.contains("--background") { show() }
        Task {
            await services.refresh()
#if INTEGRATION_TESTING
            if CommandLine.arguments.contains("--integration-v17-scenarios"),Runtime.sessionID != nil {await runV17Scenarios();return}
            if notificationProbe {
                let background=CommandLine.arguments.contains("--integration-background-test")
                if background {window.orderOut(nil);NSApp.hide(nil)} else {show()}
                for _ in 0..<20 {
                    if NSApp.isActive != background {break}
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
                if CommandLine.arguments.contains("--integration-test-preserve-plan") {
                    _ = await services.apply(time:ReminderTime(hour:9,minute:10),enabled:true,notifications:true,popup:true)
                }
                let beforeConfig=services.config
                let beforeNext=services.nextText
                let beforeDay=Runtime.defaults.string(forKey:"lastAutomaticPopupDay")
                let beforeHistory=model.store?.entries.count ?? 0
                let beforeRequests=await services.center.pendingNotificationRequests().filter {services.identifiers.contains($0.identifier)}
                let active=NSApp.isActive
                await services.test()
                let firstSubmitted=services.testWasSubmitted
                await services.test();await services.test()
                try? await Task.sleep(nanoseconds:1_500_000_000)
                let delivered=await services.center.deliveredNotifications().filter {$0.request.identifier == services.prefix+"test"}
                let afterRequests=await services.center.pendingNotificationRequests().filter {services.identifiers.contains($0.identifier)}
                Runtime.report("notification-probe",payload:["background":background,"activeAtSubmission":active,"submitted":firstSubmitted,"feedback":services.testFeedback ?? "", "delivered":delivered.map { ["id":$0.request.identifier,"title":$0.request.content.title,"body":$0.request.content.body] },"formalPlanUnchanged":Set(beforeRequests.map(\.identifier)) == Set(afterRequests.map(\.identifier)),"settingsUnchanged":beforeConfig == services.config,"dedupUnchanged":beforeDay == Runtime.defaults.string(forKey:"lastAutomaticPopupDay"),"historyUnchanged":beforeHistory == (model.store?.entries.count ?? 0),"nextReminderUnchanged":beforeNext == services.nextText,"beforeFormalCount":beforeRequests.count,"afterFormalCount":afterRequests.count])
                Runtime.event("notification-probe-finished");return
            }
            if Runtime.sessionID != nil, let i = CommandLine.arguments.firstIndex(of:"--integration-install"), CommandLine.arguments.indices.contains(i+1) {
                let parts = CommandLine.arguments[i+1].split(separator:":").compactMap { Int($0) }
                if parts.count == 2 { _ = await services.apply(time:ReminderTime(hour:parts[0],minute:parts[1]),enabled:true,requestPermission:true) }
                if CommandLine.arguments.contains("--integration-channel-check") && services.error == nil {
                    var checks: [String:Bool] = [:]
                    await services.setNotifications(false)
                    let afterNotificationsOff = await services.center.pendingNotificationRequests()
                    checks["notificationsOffCancelsFiveRequests"] = !services.notificationsOn && afterNotificationsOff.filter { services.identifiers.contains($0.identifier) }.isEmpty
                    checks["notificationsOffKeepsPopup"] = services.popupOn
                    await services.setNotifications(true)
                    checks["notificationsOnRestoresFiveRequests"] = services.notificationsOn
                    await services.setPopup(false)
                    let afterPopupOff = await services.scheduler.command(["print",services.scheduler.service])
                    checks["popupOffRemovesRealJob"] = !services.popupOn && afterPopupOff.code != 0
                    checks["popupOffKeepsNotifications"] = services.notificationsOn
                    await services.setPopup(true)
                    checks["popupOnRegistersRealJob"] = services.popupOn
                    await services.setNotifications(false)
                    checks["popupOnlyMode"] = services.popupOn && !services.notificationsOn
                    await services.setPopup(false)
                    checks["bothOffMode"] = !services.popupOn && !services.notificationsOn
                    await services.setNotifications(true)
                    checks["notificationOnlyMode"] = services.notificationsOn && !services.popupOn
                    await services.setPopup(true)
                    var externallyStopped = services.config; externallyStopped.reminderEnabled = false
                    try? await services.scheduler.apply(externallyStopped); await services.refresh()
                    await services.setNotifications(false)
                    let afterIndependentToggle = await services.scheduler.command(["print",services.scheduler.service])
                    checks["notificationToggleDoesNotRestartOtherService"] = afterIndependentToggle.code != 0
                    await services.setNotifications(true); await services.setPopup(true)
                    checks["bothOnMode"] = services.notificationsOn && services.popupOn
                    let savedReminderTime = services.config.time
                    _ = await services.apply(enabled:false)
                    let afterMasterOff = await services.center.pendingNotificationRequests()
                    let jobAfterMasterOff = await services.scheduler.command(["print",services.scheduler.service])
                    checks["masterOffCancelsBothChannels"] = !services.notificationsOn && !services.popupOn && jobAfterMasterOff.code != 0 && afterMasterOff.filter { services.identifiers.contains($0.identifier) }.isEmpty
                    _ = await services.apply(enabled:true)
                    checks["masterOnKeepsSavedTime"] = services.config.time == savedReminderTime && services.popupOn && services.notificationsOn
                    checks["channelPreferencesPersist"] = ReminderConfiguration.load(Runtime.defaults) == services.config
                    Runtime.report("channel-checks",payload:checks)
                    if checks.values.contains(false) { Runtime.event("integration-failed"); return }
                }
                if CommandLine.arguments.contains("--integration-complete-before-exit") {services.recordCopiedToday();await services.completionTask?.value}
                Runtime.event(services.error == nil ? "integration-ready" : "integration-failed")
                return
            }
#endif
            await services.ensureSchedule()
            if CommandLine.arguments.contains("--clean-start") && Runtime.sessionID == nil { cleanStart() }
            else if isNewUser { model.beginOnboarding() }
            else if CommandLine.arguments.contains("--official-agent") {checkAutomatic(source:"agent")}
        }
    }
    func show() { model.activate(); window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    @objc func openToday() { model.home(); show() }
    @objc func history() { model.go("history"); show() }
    @objc func settings() { model.go("settings"); show() }
    @objc func cleanStart() {
        guard !services.busy else { return }
        let alert=NSAlert();alert.messageText="清空 Todo 数据"
        alert.informativeText="将清空本应用全部草稿、历史及内部数据备份。无法自动区分测试记录与正式记录，清空后不会自动恢复。\n\n范围：\(model.directory.path)\n\n提醒时间、通知/弹窗偏好、系统权限及开机启动保持不变；其他应用不受影响。未选备份时将旧数据移入废纸篓。"
        let backupOption=NSButton(checkboxWithTitle:"先备份当前数据（推荐）",target:nil,action:nil);backupOption.state = .on
        alert.accessoryView=backupOption;alert.addButton(withTitle:"取消");alert.addButton(withTitle:"清空数据")
        guard alert.runModal() == .alertSecondButtonReturn else {return}
        guard model.flush() else {model.problem="当前编辑尚未保存，已取消清理，请先重试保存。";return}
        model.pending?.cancel();model.pending=nil
        do {
            var backup:URL?
            if backupOption.state == .on {
                let preferences=Runtime.defaults.persistentDomain(forName:Runtime.preferencesDomain) ?? [:]
                let data=try PropertyListSerialization.data(fromPropertyList:preferences,format:.xml,options:0)
                let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                let root=Runtime.sessionID == nil ? support.appendingPathComponent("DailyTodo-Backups") : model.directory.deletingLastPathComponent().appendingPathComponent("Test-Backups")
                backup=try CleanReset.backupAndClear(directory:model.directory,backupRoot:root,preferences:data)
            } else {try CleanReset.trashAndClear(directory:model.directory)}
            try model.reloadAfterCleanStart();show()
            let done=NSAlert();done.messageText="Todo 数据已清空"
            done.informativeText=backup.map {"备份：\($0.path)\n提醒设置与系统权限保持不变。之后填写的内容仍会自动保存。"} ?? "旧数据已移入废纸篓。提醒设置与系统权限保持不变。之后填写的内容仍会自动保存。"
            done.addButton(withTitle:"完成");if let backup {done.addButton(withTitle:"查看备份");if done.runModal() == .alertSecondButtonReturn {NSWorkspace.shared.open(backup)}}else{done.runModal()}
        } catch {model.problem="清空未完成：\(error.localizedDescription)。请先检查原文件与备份。"}
    }
    @objc func quit() { NSApp.terminate(nil) }
    func checkAutomatic(source:String) {Task {await services.deliverOfficial(source:source)}}
    func application(_ application:NSApplication, open urls:[URL]) {
        if urls.contains(where:{ ReminderRules.validURL($0,scheme:Runtime.reminderScheme) }) {checkAutomatic(source:"agent")}
    }
    func applicationShouldHandleReopen(_ sender:NSApplication, hasVisibleWindows:Bool) -> Bool { if hasVisibleWindows { show() } else { openToday() }; return true }
    func applicationDidResignActive(_ notification:Notification) { model.flush() }
    func applicationDidBecomeActive(_ notification:Notification) { model.activate(); Task { await services.reconcileOnActivation() } }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if model.showOnboarding { model.finishOnboarding(completed:false) }; return model.flush() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if terminationWaiting { return .terminateLater }
        if services.completionTask != nil || services.isSavingReminderTime {
            terminationWaiting=true
            Task { @MainActor in
                let waitsForTime = services.isSavingReminderTime
                while services.isSavingReminderTime {
                    try? await Task.sleep(nanoseconds:25_000_000)
                }
                if waitsForTime, services.error != nil {
                    terminationWaiting=false
                    NSApp.reply(toApplicationShouldTerminate:false)
                    return
                }
                await services.completionTask?.value
                services.completionTask=nil;terminationWaiting=false
                if let error=services.completionError {
                    let alert=NSAlert();alert.messageText="免提醒状态尚未保存";alert.informativeText=error
                    alert.addButton(withTitle:"取消退出并重试");alert.addButton(withTitle:"仍然退出")
                    let proceed=alert.runModal() == .alertSecondButtonReturn
                    if !proceed {services.retryPendingCopies()}
                    NSApp.reply(toApplicationShouldTerminate:proceed && model.flush())
                }else {NSApp.reply(toApplicationShouldTerminate:model.flush())}
            }
            return .terminateLater
        }
        if model.showOnboarding { model.finishOnboarding(completed:false) }
        if model.flush() { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "内容尚未保存"; alert.informativeText = "退出会丢失尚未落盘的修改。可取消退出并重试保存。"; alert.addButton(withTitle:"取消退出"); alert.addButton(withTitle:"仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter, willPresent notification:UNNotification, withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void) { Runtime.event("notification-delivered"); Runtime.report("foreground-notification",payload:["id":notification.request.identifier,"title":notification.request.content.title,"body":notification.request.content.body,"presentation":["banner","list","sound"]]); completionHandler([.banner,.list,.sound]) }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter, didReceive response:UNNotificationResponse, withCompletionHandler completionHandler:@escaping ()->Void) {
        Task { @MainActor in self.openToday(); completionHandler() }
    }
}
@main struct DailyTodoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings {EmptyView()}.commands {
            CommandGroup(after:.appInfo) { CheckForUpdatesCommand(updater:delegate.updater) }
            CommandGroup(replacing:.appSettings) {
                Button("设置…") {delegate.settings()}.keyboardShortcut(",",modifiers:.command)
            }
        }
    }
}
