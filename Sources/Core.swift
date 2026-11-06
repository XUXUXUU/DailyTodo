import Foundation
struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var day: String
    var tasks = ""
    var progress = ""
    var blockers = ""
    var createdAt = Date()
    var updatedAt = Date()
    var inheritedFromDate: String?
}
enum CopyFormatter {
    static func text(_ entry: Entry) -> String {
        zip(["• 今日任务：", "• 当前进度：", "• 卡点："], [entry.tasks, entry.progress, entry.blockers]).map { title, body in
            var lines = body.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy: .newlines)
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            return lines.isEmpty ? title : title + "\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
struct Archive: Codable { var schemaVersion = 1; var entries: [Entry] }
final class Store {
    let directory: URL
    private(set) var entries: [Entry] = []
    private(set) var warning: String?
    private var recovered = false
    var file: URL { directory.appendingPathComponent("entries.json") }
    var backup: URL { directory.appendingPathComponent("entries.bak") }
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { entries = try Self.read(file) }
        catch {
            entries = try Self.read(backup)
            let preserved = directory.appendingPathComponent("entries-damaged-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: file, to: preserved)
            recovered = true
            warning = "数据文件损坏，已恢复备份。损坏原件已保留：\(preserved.lastPathComponent)"
        }
    }
    static func read(_ url: URL) throws -> [Entry] {
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.schemaVersion == 1, Set(archive.entries.map(\.day)).count == archive.entries.count else { throw CocoaError(.fileReadCorruptFile) }
        return archive.entries
    }
    func entry(day: String) throws -> Entry {
        if let existing = entries.first(where: {$0.day == day}) { return existing }
        let latest = entries.filter {$0.day < day}.max(by: {$0.day < $1.day})
        var next = Entry(day: day)
        if let latest { next.tasks = latest.tasks; next.progress = latest.progress; next.blockers = latest.blockers; next.inheritedFromDate = latest.day }
        if latest != nil { try save(next) }; return next
    }
    func save(_ entry: Entry) throws {
        var next = entries.filter {$0.day != entry.day}; next.append(entry)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Archive(entries: next))
        if !recovered, FileManager.default.fileExists(atPath: file.path) {
            _ = try Self.read(file)
            try Data(contentsOf: file).write(to: backup, options: .atomic)
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = next; recovered = false
    }
}
enum ReminderRules {
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year,.month,.day], from: date)
        return String(format:"%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func eligible(_ date: Date, time: ReminderTime = .defaultTime, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday,.hour,.minute], from: date)
        let minutes = c.hour! * 60 + c.minute!
        return time.isValid && (2...6).contains(c.weekday!) && minutes >= time.minutes && minutes < time.minutes + 5
    }
    static func shouldPopup(_ date: Date, lastDay: String?, time: ReminderTime = .defaultTime, calendar: Calendar = .current) -> Bool {
        eligible(date, time: time, calendar: calendar) && lastDay != day(date, calendar: calendar)
    }
    static func validURL(_ url: URL, scheme:String = "dailytodo-reminder") -> Bool {
        url.scheme == scheme && url.host == "open" && url.path.isEmpty && url.query == nil && url.fragment == nil && url.user == nil && url.port == nil
    }
}


struct ReminderTime: Codable, Equatable, Sendable {
    var hour: Int
    var minute: Int
    static let defaultTime = ReminderTime(hour: 8, minute: 50)
    var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }
    var minutes: Int { hour * 60 + minute }
    var text: String { String(format: "%02d:%02d", hour, minute) }
    var launchdIntervals: [[String: Int]] {
        (1...5).map { ["Weekday": $0, "Hour": hour, "Minute": minute] }
    }
    var notificationComponents: [DateComponents] {
        (2...6).map { weekday in
            var c = DateComponents(); c.weekday = weekday; c.hour = hour; c.minute = minute
            return c
        }
    }
}
struct ReminderConfiguration: Codable, Equatable, Sendable {
    var reminderEnabled: Bool
    var time: ReminderTime
    var notificationsEnabled: Bool
    var popupEnabled: Bool
    var effectiveNotifications: Bool { reminderEnabled && notificationsEnabled }
    var effectivePopup: Bool { reminderEnabled && popupEnabled }
    init(reminderEnabled: Bool = true, time: ReminderTime = .defaultTime, notificationsEnabled: Bool = true, popupEnabled: Bool = true) {
        self.reminderEnabled = reminderEnabled; self.time = time
        self.notificationsEnabled = notificationsEnabled; self.popupEnabled = popupEnabled
    }
    enum CodingKeys: String, CodingKey { case reminderEnabled, reminderHour, reminderMinute, notificationsEnabled, popupEnabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? true
        notificationsEnabled = try c.decodeIfPresent(Bool.self,forKey:.notificationsEnabled) ?? true
        popupEnabled = try c.decodeIfPresent(Bool.self,forKey:.popupEnabled) ?? true
        time = ReminderTime(hour: try c.decodeIfPresent(Int.self, forKey: .reminderHour) ?? 8,
                            minute: try c.decodeIfPresent(Int.self, forKey: .reminderMinute) ?? 50)
        guard time.isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "提醒时间超出范围")) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reminderEnabled, forKey: .reminderEnabled)
        try c.encode(notificationsEnabled,forKey:.notificationsEnabled); try c.encode(popupEnabled,forKey:.popupEnabled)
        try c.encode(time.hour, forKey: .reminderHour); try c.encode(time.minute, forKey: .reminderMinute)
    }
    static func load(_ defaults: UserDefaults = .standard) -> ReminderConfiguration {
        let time = ReminderTime(hour: defaults.object(forKey: "reminderHour") as? Int ?? 8,
                                minute: defaults.object(forKey: "reminderMinute") as? Int ?? 50)
        return ReminderConfiguration(reminderEnabled: defaults.object(forKey: "reminderEnabled") as? Bool ?? true,
                                     time: time.isValid ? time : .defaultTime,
                                     notificationsEnabled: defaults.object(forKey:"notificationsEnabled") as? Bool ?? true,
                                     popupEnabled: defaults.object(forKey:"popupEnabled") as? Bool ?? true)
    }
    func persist(_ defaults: UserDefaults = .standard) {
        // 只增加/更新提醒键，保留 v1.0 的其他设置和去重日期。
        defaults.set(time.hour, forKey: "reminderHour"); defaults.set(time.minute, forKey: "reminderMinute")
        defaults.set(reminderEnabled, forKey: "reminderEnabled")
        defaults.set(notificationsEnabled,forKey:"notificationsEnabled"); defaults.set(popupEnabled,forKey:"popupEnabled")
    }
}
extension ReminderRules {
    static func nextReminder(after now: Date, config: ReminderConfiguration, lastDay: String?, calendar: Calendar = .current) -> Date? {
        guard config.reminderEnabled, (config.notificationsEnabled || config.popupEnabled), config.time.isValid else { return nil }
        return config.time.notificationComponents.compactMap { components in
            guard var candidate = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
            if day(candidate, calendar: calendar) == lastDay {
                guard let next = calendar.nextDate(after: candidate, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
                candidate = next
            }
            return candidate
        }.min()
    }
}

struct OnboardingPolicy {
    static let presets = [0,20,30,50].map { ReminderTime(hour:8,minute:$0) }
    static func shouldPresent(preferences: [String:Any], hasRecords: Bool) -> Bool {
        guard !hasRecords else { return false }
        let existing = ["onboardingSeen","onboardingFlowVersion","onboarded","reminderHour","reminderMinute","reminderEnabled","notificationsEnabled","popupEnabled","copyMessagesEnabled","cleanStartPromptVersion"]
        return !existing.contains { preferences[$0] != nil }
    }
}

struct NotificationCopy {
    static let title = "该给瑶总发 Todo 啦！"
    static let body = "点击打开 Daily Todo"
    static let testBody = "这是一条测试提醒"
}
struct CopyFeedbackTiming {
    static let enter = 0.2
    static let reducedEnter = 0.12
    static let hold = 4.0
    static let fade = 0.4
    static func dismissDelay(reduceMotion:Bool) -> Double { hold + (reduceMotion ? reducedEnter : enter) }
}

/// MainActor串行写入使用的版本门；保存结果不回写正文。
struct DraftVersions {
    private(set) var current=0
    private(set) var saved=0
    mutating func changed() {current += 1}
    var dirty:Bool {current != saved}
    mutating func didSave(_ revision:Int) {if revision == current {saved=revision}}
}
