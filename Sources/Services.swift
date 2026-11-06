import AppKit
import UserNotifications
import ServiceManagement
@MainActor final class Services: ObservableObject {
    @Published var notificationStatus = "检查中"
    @Published var agentStatus = "检查中"
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var config = ReminderConfiguration.load(Runtime.defaults)
    @Published var notificationPresentationEnabled=true
    @Published var notificationAuthorization:UNAuthorizationStatus = .notDetermined
    @Published var loginStatus = "已关闭"
    @Published var loginBusy=false
    @Published var testFeedback:String?
    @Published var testSubmitting=false
    @Published private(set) var testWasSubmitted=false
    private var lastTestTick:TimeInterval = -.infinity
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published private(set) var busy = false
    private(set) var isSavingReminderTime = false
    @Published private(set) var notificationsOn = false
    @Published private(set) var popupOn = false
    @Published var nextText = "检查中"
    var enabled: Bool { config.reminderEnabled }
    let center = UNUserNotificationCenter.current()
    let legacy = SMAppService.agent(plistName:"com.personal.dailytodo.reminderagent.plist")
    let scheduler = LaunchAgentScheduler(sessionID:Runtime.sessionID)
    var identifiers: [String] { (2...6).map { prefix + "weekday.\($0)" } }
    var prefix: String { Runtime.sessionID.map { "dailytodo.integration.\($0)." } ?? "dailytodo." }
    var healthy: Bool { (!config.effectivePopup || popupOn) && (!config.effectiveNotifications || notificationsOn) }
    func initializeFreshUser() {
        config = ReminderConfiguration(reminderEnabled:true,time:.defaultTime,notificationsEnabled:false,popupEnabled:false)
        config.persist(Runtime.defaults)
    }
    let ledger=ReminderLedger(directory:ReminderLedger.directory(sessionID:Runtime.sessionID))
    var clock:()->Date = {Date()}
    var completionTask:Task<Void,Never>?
    @Published var completionError:String?
    private var copiedInMemory=Set<String>()
    private var pendingCopies=[String:Date]()
    private var delivering=false
    var onOfficialPopup:(()->Void)?
    var agentConfiguration:ReminderConfiguration { agentConfiguration(for:config) }
    private func agentConfiguration(for configuration:ReminderConfiguration) -> ReminderConfiguration {
        var value=configuration
        value.reminderEnabled=configuration.reminderEnabled && (configuration.notificationsEnabled || configuration.popupEnabled)
        return value
    }
    func stateLock() async throws -> ReminderFileLock {
        let lock=try ledger.makeLock()
        for _ in 0..<300 {
            if lock.tryAcquire(){return lock}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw LaunchAgentFailure.message("提醒状态正被另一进程使用，请重试")
    }
    func updateNext() {
        do {
            var state=try ledger.readLocked()
            for key in copiedInMemory {state.days[key,default:ReminderDayState()].completedByCopy=true}
            if state.days[ReminderRules.day(clock())]?.completedByCopy == true {nextText="今天已复制完成 · 下个工作日恢复"}
            else if let next=OfficialPolicy.next(now:clock(),config:config,days:state.days) {
                let f=DateFormatter();f.locale=Locale(identifier:"zh_CN");f.dateFormat="M月d日 EEEE HH:mm";nextText=f.string(from:next)
            } else {nextText="提醒已关闭"}
            if enabled && !notificationsOn && !popupOn {nextText="尚未启用有效提醒"}
        }catch {nextText="完成状态读取失败，正式提醒已暂停";self.error=error.localizedDescription}
    }
    func refresh() async {
        let settings=await center.notificationSettings()
        notificationAuthorization=settings.authorizationStatus
        notificationPresentationEnabled=settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled
        let allowed=settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        agentStatus=await scheduler.status(expected:agentConfiguration)
        let ready=agentStatus.hasPrefix("已启用")
        notificationsOn=config.effectiveNotifications && allowed && notificationPresentationEnabled && ready
        popupOn=config.effectivePopup && ready
        if !config.effectiveNotifications {notificationStatus="应用内已关闭"}
        else if !allowed {notificationStatus="系统未允许通知"}
        else if !notificationPresentationEnabled {notificationStatus="系统通知样式已关闭"}
        else {notificationStatus=ready ? "已启用 · 到点统一校验" : "后台调度尚未就绪"}
        updateLoginStatus();updateNext()
        if Runtime.sessionID != nil {
            let requests=await center.pendingNotificationRequests()
            Runtime.report("system-status",payload:["notificationStatus":notificationStatus,"agentStatus":agentStatus,"notificationsOn":notificationsOn,"popupOn":popupOn,"time":config.time.text,"pending":requests.filter{owns($0.identifier)}.map{["id":$0.identifier,"trigger":String(describing:$0.trigger)]}])
        }
    }
    func owns(_ id:String)->Bool {
        if Runtime.sessionID != nil {return id.hasPrefix(prefix)}
        // UserNotifications already scopes this query to the current application.
        // Production also owns abandoned test requests from older shared-ID builds.
        return true
    }
    func isCurrentOfficialID(_ id:String)->Bool {
        Runtime.sessionID == nil ? id.hasPrefix("daily.todo.reminder.") : id.hasPrefix(prefix+"official.")
    }
    func migrateLegacy(configuration target: ReminderConfiguration, replacingSchedule: Bool = false) async throws {
        if Runtime.sessionID == nil {
            if legacy.status == .enabled || legacy.status == .requiresApproval {try await legacy.unregister()}
            let old="gui/\(getuid())/com.personal.dailytodo.reminderagent"
            if (await scheduler.command(["print",old])).code == 0 {
                let result=await scheduler.command(["bootout",old]);guard result.code==0 else {throw LaunchAgentFailure.message("无法停止旧提醒任务：\(result.output)")}
            }
            let oldFile=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.personal.dailytodo.reminderagent.plist")
            if FileManager.default.fileExists(atPath:oldFile.path) {
                let dict=try NSDictionary(contentsOf:oldFile,error:())
                if dict["Label"] as? String == "com.personal.dailytodo.reminderagent" {try FileManager.default.removeItem(at:oldFile)}
            }
        }
        let pending=await center.pendingNotificationRequests().filter{owns($0.identifier) && ($0.trigger != nil || !isCurrentOfficialID($0.identifier))}
        let delivered=await center.deliveredNotifications().filter{owns($0.request.identifier) && !isCurrentOfficialID($0.request.identifier)}
        let lock=try await stateLock();defer{lock.release()}
        var state=try ledger.readLocked()
        let before=state
        if let oldDay=Runtime.defaults.string(forKey:"lastAutomaticPopupDay") {state.days[oldDay,default:ReminderDayState()].popupClaimed=true}
        for item in delivered where item.request.identifier != prefix+"test" && !item.request.identifier.contains(".test") {
            state.days[ReminderRules.day(item.date),default:ReminderDayState()].notificationClaimed=true
        }
        state.configuration=target
        center.removePendingNotificationRequests(withIdentifiers:pending.map(\.identifier))
        if replacingSchedule {
            // Helper and official delivery share this lock. Neither can read a
            // candidate time before launchd has accepted the replacement.
            let previousAgent=await scheduler.snapshot()
            try await scheduler.apply(agentConfiguration(for:target))
            do { try ledger.writeLocked(state) }
            catch {
                var failures=[error.localizedDescription]
                do { try ledger.writeLocked(before) }
                catch { failures.append("恢复提醒配置失败：\(error.localizedDescription)") }
                do { try await scheduler.restore(previousAgent) }
                catch { failures.append("恢复后台任务失败：\(error.localizedDescription)") }
                throw LaunchAgentFailure.message(failures.joined(separator:"；"))
            }
            target.persist(Runtime.defaults)
            Runtime.defaults.set(true,forKey:"onboarded")
            Runtime.defaults.synchronize()
        } else {
            try ledger.writeLocked(state)
        }
        center.removeDeliveredNotifications(withIdentifiers:delivered.map{$0.request.identifier})
        ledger.appendLog(["eventSource":"migration","removedPending":pending.map(\.identifier),"removedDelivered":delivered.map{$0.request.identifier},"newPlan":"single-launchd","setting":target.time.text,"bundle":Bundle.main.bundleIdentifier ?? "unknown","version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"])
    }
    @discardableResult func apply(time:ReminderTime?=nil,enabled:Bool?=nil,notifications:Bool?=nil,popup:Bool?=nil,requestPermission:Bool=false) async -> Bool {
        guard !busy else{return false}
        busy=true;isSavingReminderTime=time != nil
        defer{busy=false;isSavingReminderTime=false}
        error=nil;notice=nil
        var candidate=config;candidate.time=time ?? config.time;candidate.reminderEnabled=enabled ?? config.reminderEnabled
        candidate.notificationsEnabled=notifications ?? config.notificationsEnabled;candidate.popupEnabled=popup ?? config.popupEnabled
        guard candidate.time.isValid else{error="请输入有效的24小时时间";return false}
        do {
            if requestPermission && candidate.effectiveNotifications {
                let status=await center.notificationSettings().authorizationStatus
                if status == .notDetermined {_ = try await center.requestAuthorization(options:[.alert,.sound])}
            }
            try await migrateLegacy(configuration:candidate,replacingSchedule:true)
            config=candidate
            Runtime.defaults.set(true,forKey:"onboarded")
            notice="设置已保存 · \(candidate.time.text) · 周一至周五"
            Runtime.event("schedule-applied");await refresh();return true
        }catch {
            self.error=error.localizedDescription
            let failure=self.error
            await refresh()
            self.error=failure
            return false
        }
    }
    func ensureSchedule() async {
        guard !busy else{return};busy=true;defer{busy=false}
        do {
            try await migrateLegacy(configuration:config)
            let status=await scheduler.status(expected:agentConfiguration)
            if agentConfiguration.reminderEnabled ? !status.hasPrefix("已启用") : status != "已关闭" {try await scheduler.apply(agentConfiguration)}
        }catch {self.error="提醒迁移/调度失败：\(error.localizedDescription)"}
        await refresh()
    }
    func recordCopiedToday(at now:Date = Date()) {
        let key=ReminderRules.day(now)
        copiedInMemory.insert(key);pendingCopies[key]=now
        retryPendingCopies()
    }
    func retryPendingCopies() {
        let previous=completionTask
        completionTask=Task { @MainActor in
            await previous?.value
            // 重试原始日期和时间，绝不把昨天的失败复制重标为今天完成。
            for key in pendingCopies.keys.sorted() {
                guard let copiedAt=pendingCopies[key] else{continue}
                for attempt in 0..<3 {
                    do {
                        let lock=try await stateLock()
                        do {
                            var state=try ledger.readLocked();state.days[key,default:ReminderDayState()].completedByCopy=true;state.days[key,default:ReminderDayState()].copiedAt=copiedAt
                            try ledger.writeLocked(state)
                        }catch {lock.release();throw error};lock.release()
                        let id=officialID(key)
                        center.removePendingNotificationRequests(withIdentifiers:[id]);center.removeDeliveredNotifications(withIdentifiers:[id])
                        if pendingCopies[key] == copiedAt {pendingCopies.removeValue(forKey:key)}
                        if pendingCopies.isEmpty {completionError=nil};updateNext()
                        ledger.log(source:"copy",requestID:id,now:copiedAt,config:config,state:ReminderDayState(completedByCopy:true,copiedAt:copiedAt),decision:"skip",reason:"alreadyCopied")
                        Runtime.event("copy-completion-persisted");break
                    }catch {
                        completionError="已复制，但\(key)免提醒状态尚未保存，正在重试：\(error.localizedDescription)"
                        if attempt<2 {try? await Task.sleep(nanoseconds:500_000_000)}
                        else {completionError="已复制，但\(key)免提醒状态保存失败；请重试，当前不能保证退出后停止提醒。"}
                    }
                }
            }
        }
    }
    func officialID(_ key:String)->String {Runtime.sessionID == nil ? "daily.todo.reminder."+key : prefix+"official."+key}
    func deliverOfficial(source:String) async {
        guard !delivering else{return};delivering=true;defer{delivering=false}
        do {
            let lock=try await stateLock();defer{lock.release()}
            var state=try ledger.readLocked()
            guard let setting=state.configuration else{return}
            let now=clock(),key=ReminderRules.day(now),id=officialID(key)
            var day=state.days[key] ?? ReminderDayState()
            if copiedInMemory.contains(key) {day.completedByCopy=true}
            var reason=OfficialPolicy.reason(now:now,config:setting,state:day)
            if source != "agent" && source != "wake" {reason="notScheduledEntry"}
            guard reason == "eligible" else {ledger.log(source:source,requestID:id,now:now,config:setting,state:day,decision:"skip",reason:reason);return}
            let settings=await center.notificationSettings()
            // 在所有异步系统查询之后重新检查时刻/完成状态，锁仍串行协调跨进程复制。
            if copiedInMemory.contains(key) {day.completedByCopy=true}
            reason=OfficialPolicy.reason(now:clock(),config:setting,state:day)
            guard reason == "eligible" else{ledger.log(source:source,requestID:id,now:clock(),config:setting,state:day,decision:"skip",reason:reason);return}
            let notify=setting.effectiveNotifications && !day.notificationClaimed && (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) && (settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled)
            let session=CGSessionCopyCurrentDictionary() as? [String:Any]
            let popup=setting.effectivePopup && !day.popupClaimed && session?["CGSSessionScreenIsLocked"] as? Bool != true && session?["kCGSessionOnConsoleKey"] as? Bool != false
            if !notify && !popup {ledger.log(source:source,requestID:id,now:now,config:setting,state:day,decision:"skip",reason:"alreadyClaimedOrUnavailable");return}
            // 先持久化通道预留；崩溃时宁可本次漏发，也不能重复发送。
            if notify{day.notificationClaimed=true};if popup{day.popupClaimed=true}
            state.days[key]=day;try ledger.writeLocked(state)
            if notify {
                let content=UNMutableNotificationContent();content.title=NotificationCopy.title;content.body=NotificationCopy.body;content.sound = .default
                do {
                    try await center.add(UNNotificationRequest(identifier:id,content:content,trigger:nil))
                    Runtime.event("official-notification-submitted")
                }catch {self.error="系统通知提交失败：\(error.localizedDescription)";ledger.appendLog(["eventSource":source,"requestId":id,"decision":"notification-failed","reason":error.localizedDescription])}
            }
            if popup {onOfficialPopup?();Runtime.event("automatic-popup")}
            ledger.log(source:source,requestID:id,now:now,config:setting,state:day,decision:"send",reason:"notification=\(notify),popup=\(popup)")
        }catch {self.error="正式提醒未完成：\(error.localizedDescription)";ledger.appendLog(["eventSource":source,"decision":"skip","reason":"stateOrDeliveryFailure","error":error.localizedDescription])}
    }
    func setNotifications(_ value: Bool) async {
        _ = await apply(notifications:value,requestPermission:value)
        if value && !notificationPresentationEnabled && notificationAuthorization != .denied { openNotificationSettings() }
    }
    func setPopup(_ value: Bool) async {
        let success = await apply(popup:value)
        if value && (!success || !popupOn) {
            let disabled = await scheduler.command(["print-disabled",scheduler.domain])
            let reason = error ?? ""
            let permissionBlocked = disabled.output.contains("\"\(scheduler.label)\" => true") || reason.contains("需授权") || reason.localizedCaseInsensitiveContains("not permitted") || reason.localizedCaseInsensitiveContains("permission denied") || reason.localizedCaseInsensitiveContains("not authorized")
            if permissionBlocked {
                notice = "自动弹窗尚未就绪。请在系统设置的登录项与扩展中允许 Daily Todo 后台项目；若受管理策略限制，请联系管理员。"
                SMAppService.openSystemSettingsLoginItems()
            } else {
                notice = "自动弹窗尚未就绪，请根据错误检查完整应用的安装位置、辅助程序或文件权限后重试；没有修改系统权限。"
            }
        }
    }
    func openNotificationSettings() {
        // 不依赖未承诺兼容的通知子页URL；用公开的App启动入口并给出明确路径。
        notice = "请在“系统设置 → 通知 → Daily Todo”中打开“允许通知”。打开设置不代表授权成功。"
        let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.systempreferences") ?? URL(fileURLWithPath:"/System/Applications/System Settings.app")
        if !NSWorkspace.shared.open(settings) { error = "无法自动打开系统设置，请手动进入“通知 → Daily Todo”开启权限。" }
    }
    func synchronizeNotifications() async {await ensureSchedule()}
    func reconcileOnActivation() async {await refresh()}
    func repair() async { _ = await apply(requestPermission:true) }
    var notificationHelp:String? {
        guard enabled else { return nil }
        if notificationAuthorization == .notDetermined { return "未授权，点击开启" }
        if notificationAuthorization == .denied { return "系统未允许通知" }
        if !notificationPresentationEnabled {return "系统通知样式已关闭"}
        return config.effectiveNotifications && !notificationsOn ? "统一后台调度尚未就绪" : nil
    }
    var popupHelp:String? {
        guard enabled, config.effectivePopup else { return nil }
        return agentStatus == "已关闭" || popupOn ? nil : agentStatus
    }
    var loginHelp:String? { loginStatus == "等待系统批准" || loginStatus == "暂不可用" ? loginStatus : nil }
    var needsPermissionHelp:Bool { notificationAuthorization == .denied || !notificationPresentationEnabled || agentStatus.contains("授权") || loginStatus == "等待系统批准" || error?.contains("授权") == true }
    func openRelevantSettings() {
        if notificationAuthorization == .denied || !notificationPresentationEnabled { openNotificationSettings() }
        else { SMAppService.openSystemSettingsLoginItems() }
    }
    func updateLoginStatus() {
        let status=SMAppService.mainApp.status
        login = status == .enabled
        switch status {
        case .enabled: loginStatus="已开启"
        case .requiresApproval: loginStatus="等待系统批准"
        case .notRegistered: loginStatus="已关闭"
        case .notFound: loginStatus="暂不可用"
        @unknown default: loginStatus="状态未知"
        }
    }
    func setLogin(_ value: Bool) async {
        guard !loginBusy else { return };loginBusy=true;defer {loginBusy=false}
        error=nil
        do { if value { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() } }
        catch { self.error = "开机启动设置失败：\(error.localizedDescription)" }
        updateLoginStatus()
        if value && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    func setNotificationsFromGuide(_ value:Bool) async {
        if value && !enabled { _ = await apply(enabled:true,notifications:true,popup:false,requestPermission:true) }
        else { await setNotifications(value) }
    }
    func setPopupFromGuide(_ value:Bool) async {
        if value && !enabled { _ = await apply(enabled:true,notifications:false,popup:true) }
        else { await setPopup(value) }
    }
    func test() async {
        testWasSubmitted=false
        guard !testSubmitting else { return }
        let tick=ProcessInfo.processInfo.systemUptime
        guard tick-lastTestTick >= 1.5 else { testFeedback="刚刚已提交测试通知，请稍候再试";return }
        testSubmitting=true;defer {testSubmitting=false}
        var settings=await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options:[.alert,.sound]);settings=await center.notificationSettings() }
            catch { testFeedback="发送失败：\(error.localizedDescription)";return }
        }
        notificationAuthorization=settings.authorizationStatus
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            testFeedback="通知权限未开启，请在系统设置中允许 Daily Todo 通知";return
        }
        let identifier=prefix+"test"
        center.removePendingNotificationRequests(withIdentifiers:[identifier])
        center.removeDeliveredNotifications(withIdentifiers:[identifier])
        let content=UNMutableNotificationContent()
        content.title="测试提醒 · "+NotificationCopy.title;content.body=NotificationCopy.testBody;content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier:identifier,content:content,trigger:nil))
            lastTestTick=ProcessInfo.processInfo.systemUptime;testWasSubmitted=true
            let stylesOff=settings.alertSetting == .disabled || settings.alertStyle == .none
            testFeedback=stylesOff ? "已提交测试通知；系统当前可能不显示横幅" : "已提交测试通知"
            Runtime.report("test-notification-submitted",payload:["id":identifier,"title":content.title,"body":content.body,"activeAtSubmission":NSApp.isActive,"feedback":testFeedback ?? ""])
        } catch { testFeedback="发送失败：\(error.localizedDescription)" }
    }
}
