import Foundation
import CryptoKit
import Darwin

enum FeishuDeliveryMode:String,Codable,CaseIterable {
    case draft,send
    var title:String { self == .draft ? "填入聊天框" : "自动发送" }
}
struct FeishuAutomationConfiguration:Codable,Equatable {
    var enabled=false
    var recipient="何雪瑶"
    var mode:FeishuDeliveryMode = .draft
    var recipientIsSelf=false
    func canDispatch(selfTest:Bool)->Bool {selfTest || enabled}
    func deliveryMode(selfTest:Bool,testMode:FeishuDeliveryMode?=nil)->FeishuDeliveryMode {selfTest ? (testMode ?? mode) : mode}
    var summary:String {enabled ? mode.title : "关闭"}
    static let key="feishuAutomationV1"
    var buttonTitle:String { enabled ? "一键转发" : "复制全部" }
    var productionSafe:Self {
        var result=self
        if recipient != "何雪瑶" || recipientIsSelf {result.enabled=false}
        result.recipient="何雪瑶";result.recipientIsSelf=false
        return result
    }
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
    case message(String),accessibilityRestartRequired
    var errorDescription:String? {
        switch self {
        case .message(let s):return s
        case .accessibilityRestartRequired:return "权限连接需要刷新，请在一键转发设置中点「重启继续」。正文和已保存的设置会保留。"
        }
    }
}
enum FeishuAutomationRules {
    static func selfName(profileTexts:[String])->String? {
        guard let first=profileTexts.first else {return nil}
        let name=normalized(first)
        guard !name.isEmpty,name.count <= 80,name.rangeOfCharacter(from:.controlCharacters)==nil,
              profileTexts.contains(where:{$0.contains("我的个人名片")}),
              profileTexts.contains(where:{$0.contains("退出登录")}),
              !["我的个人名片","退出登录","设置","已认证","未认证","状态"].contains(name),
              !["已认证","未认证"].contains(profileTexts.dropFirst().first.map(normalized) ?? "") else {return nil}
        return name
    }
    static func isVerifiedSelfComposer(_ value:String,editableText:Bool)->Bool {
        !editableText && compact(value)=="可以向自己发送文件或转发消息"
    }
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
        if isSelf {return isVerifiedSelfComposer(value,editableText:editableText)}
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

/// Account cards render in stages. A plausible first text is not yet an identity.
struct FeishuProfileReadiness {
    private var texts:[String]=[]
    private var nodes=0
    private var since:TimeInterval=0
    mutating func sample(texts:[String],nodeCount:Int,at now:TimeInterval)->String? {
        guard let name=FeishuAutomationRules.selfName(profileTexts:texts) else {
            self.texts=[];nodes=0;since=now;return nil
        }
        guard self.texts==texts,nodes==nodeCount else {
            self.texts=texts;nodes=nodeCount;since=now;return nil
        }
        return now-since >= 0.6 ? name : nil
    }
}

/// Read shallow controls before deep content. Web content unrelated to delivery is opaque.
enum FeishuAXTraversal {
    static func shouldExpand(role:String,label:String,url:String)->Bool {
        guard role == "AXWebArea" else {return true}
        let pages=["search-command-bar","messenger-chat","ternantCardModal"]
        return pages.contains(label) || ["/search/search-command-bar/","/messenger/messenger-chat/","/main-window/ternantCardModal/"].contains(where:url.contains)
    }
    struct Snapshot<Node> {let root:Node;let complete:Bool;let deepestLevel:Int}
    static func build<Element,Node>(root:Element,limit:Int,maxDepth:Int,makeNode:(Element)->Node,children:(Element)->[Element],shouldExpand:(Node)->Bool,appendChild:(Node,Node)->Void)->Snapshot<Node> {
        precondition(limit>0 && maxDepth>=0)
        let first=makeNode(root)
        var queue:[(Element,Node,Int)]=[(root,first,0)]
        var cursor=0
        var complete=true
        var deepestLevel=0
        while cursor<queue.count {
            let (element,node,depth)=queue[cursor];cursor += 1
            guard shouldExpand(node) else {continue}
            let descendants=children(element)
            guard depth<maxDepth else {if !descendants.isEmpty {complete=false};continue}
            for child in descendants {
                guard queue.count<limit else {complete=false;break}
                let next=makeNode(child);appendChild(node,next)
                queue.append((child,next,depth+1));deepestLevel=max(deepestLevel,depth+1)
            }
        }
        return Snapshot(root:first,complete:complete,deepestLevel:deepestLevel)
    }
}
