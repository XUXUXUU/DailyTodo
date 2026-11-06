import Foundation
struct Runtime {
    static let sessionID: String? = {
#if INTEGRATION_TESTING
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of:"--integration-session"),args.indices.contains(index+1),UUID(uuidString:args[index+1]) != nil else {
            FileHandle.standardError.write(Data("测试构建必须指定有效的 --integration-session UUID。\n".utf8))
            exit(64)
        }
        return args[index+1]
#else
        return nil
#endif
    }()
    static var reduceMotionOverride:Bool {
#if INTEGRATION_TESTING
        return sessionID != nil && CommandLine.arguments.contains("--integration-reduce-motion")
#else
        return false
#endif
    }
    static var reminderScheme:String { sessionID == nil ? "dailytodo-reminder" : "dailytodo-reminder-testing" }
    static var preferencesDomain: String { sessionID.map { "com.personal.dailytodo.integration.\($0)" } ?? "com.personal.dailytodo" }
    static let defaults: UserDefaults = sessionID.flatMap { UserDefaults(suiteName:"com.personal.dailytodo.integration.\($0)") } ?? .standard
    static let dataDirectory: URL = {
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
#if INTEGRATION_TESTING
        guard let sessionID else { preconditionFailure("Missing test session") }
        return support.appendingPathComponent("DailyTodoTesting").appendingPathComponent(sessionID)
#else
        return support.appendingPathComponent("DailyTodo")
#endif
    }()
    static func report(_ name: String, payload: [String:Any]) {
        guard sessionID != nil else { return }
        try? FileManager.default.createDirectory(at:dataDirectory,withIntermediateDirectories:true)
        if let data = try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys,.prettyPrinted]) {
            try? data.write(to:dataDirectory.appendingPathComponent(name + ".json"),options:.atomic)
        }
    }
    static func event(_ name: String) {
        guard sessionID != nil else { return }
        try? FileManager.default.createDirectory(at:dataDirectory,withIntermediateDirectories:true)
        let url = dataDirectory.appendingPathComponent("\(name).json")
        let value: [String:Any] = ["event":name,"timestamp":ISO8601DateFormatter().string(from:Date()),"pid":ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys) { try? data.write(to:url,options:.atomic) }
    }
}
