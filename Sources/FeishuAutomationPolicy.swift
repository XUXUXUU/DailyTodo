import Foundation
import CryptoKit
import Darwin

enum FeishuDeliveryMode:String,Codable,CaseIterable {
    case draft,send
    var title:String { self == .draft ? "填入草稿" : "直接发送" }
}
struct FeishuAutomationConfiguration:Codable,Equatable {
    var enabled=false
    var recipient="何雪瑶"
    var mode:FeishuDeliveryMode = .draft
    var recipientIsSelf=false
    static let key="feishuAutomationV1"
    var buttonTitle:String { "发给" + (recipient == "何雪瑶" ? "瑶总" : recipient) }
    static func load(from defaults:UserDefaults)->Self {
        guard let data=defaults.data(forKey:key),let config=try? JSONDecoder().decode(Self.self,from:data),
              (try? config.validated()) != nil else {return Self()}
        return config
    }
    func validated() throws -> Self {
        var result=self
        result.recipient=recipient.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !result.recipient.isEmpty,result.recipient.count <= 80,
              result.recipient.rangeOfCharacter(from:.controlCharacters) == nil else {throw FeishuAutomationError.message("请填写一个完整的联系人姓名。")}
        return result
    }
    func save(to defaults:UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(validated()),forKey:Self.key)
    }
}
enum FeishuAutomationError:LocalizedError {
    case message(String)
    var errorDescription:String? { if case .message(let s)=self {return s};return nil }
}
enum FeishuAutomationRules {
    static func normalized(_ text:String)->String {
        text.replacingOccurrences(of:"\u{200b}",with:"").replacingOccurrences(of:"\u{feff}",with:"")
            .replacingOccurrences(of:"\u{2060}",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func compact(_ text:String)->String { normalized(text).components(separatedBy:.whitespacesAndNewlines).joined() }
    static func isEmptyDraft(_ text:String)->Bool {normalized(text).isEmpty}
    static func recipientMatches(_ description:String,name:String,isSelf:Bool)->Bool {
        let description=compact(description),name=compact(name)
        return description == "发送给"+name || (isSelf && description == "可以向自己发送文件或转发消息")
    }
    static func uniqueExactMatch(_ names:[String],name:String)->Int? {
        let matches=names.indices.filter {normalized(names[$0]) == normalized(name)}
        return matches.count == 1 ? matches[0] : nil
    }
    static func canSendUsingReturn(hint:String)->Bool {
        let hint=compact(hint).lowercased()
        return hint == "shift+enter换行" || hint == "shift+return换行"
    }
    static func isEmptyComposer(_ value:String,name:String,isSelf:Bool,readable:Bool,editableText:Bool)->Bool {
        guard readable else {return false}
        let text=normalized(value)
        return text.isEmpty || (!editableText && recipientMatches(text,name:name,isSelf:isSelf))
    }
    static func mayFill(header:String,description:String,name:String,isSelf:Bool,draft:String,focused:Bool,readable:Bool=true,editableText:Bool=true)->Bool {
        readable && focused && normalized(header)==normalized(name) && (description.isEmpty || recipientMatches(description,name:name,isSelf:isSelf)) && isEmptyComposer(draft,name:name,isSelf:isSelf,readable:readable,editableText:editableText)
    }

}
/// A dispatched but unconfirmed message must never be retried automatically.
struct FeishuDeliveryLedger {
    let directory:URL
    static func fingerprint(recipient:String,day:String,text:String)->String {
        let data=try! JSONEncoder().encode([recipient,day,text])
        return SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    }
    private func transaction<T>(_ body:(inout [String:String]) throws ->T) throws ->T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(directory.appendingPathComponent("feishu-deliveries.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd >= 0 else {throw FeishuAutomationError.message("无法保存发送记录，已暂停自动发送。")}
        defer {Darwin.close(fd)}
        guard flock(fd,LOCK_EX)==0 else {throw FeishuAutomationError.message("发送记录正在使用，请稍后再试。")}
        defer {flock(fd,LOCK_UN)}
        let url=directory.appendingPathComponent("feishu-deliveries.json")
        var records:[String:String]=[:]
        if FileManager.default.fileExists(atPath:url.path) {records=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))}
        let value=try body(&records)
        try JSONEncoder().encode(records).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        return value
    }
    func hasAttempt(_ fingerprint:String)throws ->Bool {try transaction {$0[fingerprint] != nil}}
    func claim(_ fingerprint:String)throws ->Bool {
        try transaction {records in
            guard records[fingerprint] == nil else {return false}
            records[fingerprint]="dispatched";return true
        }
    }
    func finish(_ fingerprint:String,sent:Bool)throws {
        try transaction {$0[fingerprint] = sent ? "sent" : "unconfirmed"}
    }
}
