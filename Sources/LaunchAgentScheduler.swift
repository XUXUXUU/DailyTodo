import Foundation
import Darwin

struct AgentSnapshot: Sendable {
    var data: Data?
    var loaded: Bool
}
struct CommandResult: Sendable { var code: Int32; var output: String }
enum LaunchAgentFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
/// 用户级 launchd 任务；不修改签名包，不需要管理员权限。
struct LaunchAgentScheduler: Sendable {
    static let productionLabel = "com.personal.dailytodo.userreminder"
    let label: String
    let plist: URL
    let helper: URL
    let sessionID: String?
    var domain: String { "gui/\(getuid())" }
    var service: String { "\(domain)/\(label)" }
    init(bundle: URL = Bundle.main.bundleURL, sessionID: String? = nil) {
        self.sessionID = sessionID
        label = sessionID.map { "com.personal.dailytodo.integration.\($0)" } ?? Self.productionLabel
        plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        helper = bundle.appendingPathComponent("Contents/Resources/DailyTodoReminderAgent")
    }
    static func command(_ args: [String]) -> CommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/bin/launchctl"); process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline:.now()+12,execute:timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            return CommandResult(code:process.terminationStatus,output:String(decoding:data,as:UTF8.self))
        } catch { return CommandResult(code:-1,output:error.localizedDescription) }
    }
    func command(_ args: [String]) async -> CommandResult {
        await Task.detached { Self.command(args) }.value
    }
    func snapshot() async -> AgentSnapshot {
        let result = await command(["print",service])
        return AgentSnapshot(data:try? Data(contentsOf:plist),loaded:result.code == 0)
    }
    func status(expected: ReminderConfiguration) async -> String {
        let result = await command(["print",service])
        guard result.code == 0 else { return expected.reminderEnabled ? "未启用 · 需修复" : "已关闭" }
        let disabled = await command(["print-disabled",domain])
        if disabled.output.contains("\"\(label)\" => true") { return "需授权 · 后台项目被停用" }
        guard expected.reminderEnabled else { return "异常 · 服务尚未停止" }
        guard let data = try? Data(contentsOf:plist), let dict = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              let intervals = dict["StartCalendarInterval"] as? [[String:Int]], intervals == expected.time.launchdIntervals,
              let args = dict["ProgramArguments"] as? [String], args.first == helper.path,
              FileManager.default.isExecutableFile(atPath:helper.path) else { return "异常 · 计划需修复" }
        func values(_ key: String) -> [Int] {
            let pattern = "\"" + key + "\" => ([0-9]+)"
            guard let regex = try? NSRegularExpression(pattern:pattern) else { return [] }
            let source = result.output as NSString
            return regex.matches(in:result.output,range:NSRange(location:0,length:source.length)).compactMap { Int(source.substring(with:$0.range(at:1))) }
        }
        guard values("Hour") == Array(repeating:expected.time.hour,count:5),
              values("Minute") == Array(repeating:expected.time.minute,count:5),
              values("Weekday").sorted() == [1,2,3,4,5] else { return "异常 · 系统计划与设置不一致" }
        return "已启用 · \(expected.time.text)"
    }
    func removeLoaded() async throws {
        guard (await command(["print",service])).code == 0 else { return }
        let result = await command(["bootout",service])
        guard result.code == 0 else { throw LaunchAgentFailure.message("停止后台计划失败：\(result.output)") }
    }
    func restore(_ previous: AgentSnapshot) async throws {
        try await removeLoaded()
        if let data = previous.data {
            try data.write(to:plist,options:.atomic)
            if previous.loaded {
                let result = await command(["bootstrap",domain,plist.path])
                guard result.code == 0 else { throw LaunchAgentFailure.message("恢复旧计划失败：\(result.output)") }
            }
        } else if FileManager.default.fileExists(atPath:plist.path) { try FileManager.default.removeItem(at:plist) }
    }
    func apply(_ config: ReminderConfiguration) async throws {
        guard config.time.isValid else { throw LaunchAgentFailure.message("时间必须在00:00至23:59之间") }
        let previous = await snapshot()
        do {
            try await removeLoaded()
            if !config.reminderEnabled {
                if FileManager.default.fileExists(atPath:plist.path) { try FileManager.default.removeItem(at:plist) }
                return
            }
            guard FileManager.default.isExecutableFile(atPath:helper.path) else { throw LaunchAgentFailure.message("辅助程序未找到，请从完整的 DailyTodo.app 运行") }
            try FileManager.default.createDirectory(at:plist.deletingLastPathComponent(),withIntermediateDirectories:true)
            var arguments = [helper.path]
            if let sessionID { arguments += ["--integration-session",sessionID] }
            let dictionary: [String:Any] = ["Label":label,"ProgramArguments":arguments,
                "StartCalendarInterval":config.time.launchdIntervals,"RunAtLoad":false,
                "LimitLoadToSessionType":"Aqua","ProcessType":"Interactive"]
            let data = try PropertyListSerialization.data(fromPropertyList:dictionary,format:.xml,options:0)
            try data.write(to:plist,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:plist.path)
            let result = await command(["bootstrap",domain,plist.path])
            guard result.code == 0 else { throw LaunchAgentFailure.message("后台计划加载失败（\(result.code)）：\(result.output)") }
            let status = await status(expected:config)
            guard status.hasPrefix("已启用") else { throw LaunchAgentFailure.message(status) }
        } catch {
            let original = error.localizedDescription
            do { try await restore(previous) }
            catch { throw LaunchAgentFailure.message("\(original)；且回滚失败：\(error.localizedDescription)。请修复后台项目。") }
            throw LaunchAgentFailure.message("\(original)；已恢复旧计划。")
        }
    }
}
