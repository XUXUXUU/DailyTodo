import Foundation

@main struct SchedulerTests {
    static func main() async throws {
        let session = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DailyTodo-Scheduler-\(session).app")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        let helper = resources.appendingPathComponent("DailyTodoReminderAgent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:helper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let scheduler = LaunchAgentScheduler(bundle:root,sessionID:session)
        var checks = 0
        func check(_ condition: Bool,_ label: String) throws {
            guard condition else { throw LaunchAgentFailure.message("FAIL: \(label)") }
            checks += 1; print("PASS: \(label)")
        }
        do {
            let initial = ReminderConfiguration(time:ReminderTime(hour:8,minute:50))
            try await scheduler.apply(initial)
            try check((await scheduler.status(expected:initial)).hasPrefix("已启用"),"真实launchctl初次bootstrap")
            let updated = ReminderConfiguration(time:ReminderTime(hour:9,minute:10))
            try await scheduler.apply(updated)
            let printJob = await scheduler.command(["print",scheduler.service])
            try check(printJob.code == 0 && printJob.output.contains("\"Hour\" => 9") && printJob.output.contains("\"Minute\" => 10") && !printJob.output.contains("\"Hour\" => 8"),"重载后真实系统计划只有09:10，旧08:50消失")
            let defaults = UserDefaults(suiteName:"com.personal.dailytodo.scheduler-test.\(session)")!
            defer { defaults.removePersistentDomain(forName:"com.personal.dailytodo.scheduler-test.\(session)") }
            defaults.set("preserve",forKey:"unknownLegacyField"); defaults.set("2026-10-29",forKey:"lastAutomaticPopupDay")
            updated.persist(defaults)
            try check(ReminderConfiguration.load(defaults) == updated && defaults.string(forKey:"unknownLegacyField") == "preserve" && defaults.string(forKey:"lastAutomaticPopupDay") == "2026-10-29","持久化时间且保留旧设置和当天去重")
            var disabled = updated; disabled.reminderEnabled = false
            try await scheduler.apply(disabled)
            try check((await scheduler.command(["print",scheduler.service])).code != 0 && !FileManager.default.fileExists(atPath:scheduler.plist.path),"关闭后真实服务和用户plist均移除")
            try await scheduler.apply(updated)
            try check((await scheduler.status(expected:updated)).hasPrefix("已启用"),"重新启用保留新时间")
            let before = try Data(contentsOf:scheduler.plist)
            let brokenScheduler = LaunchAgentScheduler(bundle:root.appendingPathComponent("missing.app"),sessionID:session)
            do { try await brokenScheduler.apply(ReminderConfiguration(time:ReminderTime(hour:10,minute:20))); throw LaunchAgentFailure.message("缺失helper应失败") }
            catch {
                try check((try? Data(contentsOf:scheduler.plist)) == before,"更新失败回滚原plist")
                try check((await scheduler.command(["print",scheduler.service])).code == 0,"更新失败旧系统任务仍已加载")
            }
            try await scheduler.apply(disabled)
            try FileManager.default.removeItem(at:root)
            print("SCHEDULER TOTAL: \(checks) checks passed")
        } catch {
            _ = await scheduler.command(["bootout",scheduler.service])
            try? FileManager.default.removeItem(at:scheduler.plist); try? FileManager.default.removeItem(at:root)
            throw error
        }
    }
}
