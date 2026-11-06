import Foundation
import Darwin

struct ReminderDayState:Codable,Equatable {
    var completedByCopy=false
    var copiedAt:Date?
    var notificationClaimed=false
    var popupClaimed=false
}
struct ReminderLedgerState:Codable,Equatable {
    var schemaVersion=1
    var configuration:ReminderConfiguration?
    var days=[String:ReminderDayState]()
}
enum OfficialPolicy {
    static func scheduled(_ now:Date,time:ReminderTime,calendar:Calendar = .current)->Date? {
        guard time.isValid else{return nil}
        return calendar.date(bySettingHour:time.hour,minute:time.minute,second:0,of:now,matchingPolicy:.nextTime,repeatedTimePolicy:.first,direction:.forward)
    }
    static func reason(now:Date,config:ReminderConfiguration,state:ReminderDayState,calendar:Calendar = .current)->String {
        if !config.reminderEnabled || (!config.notificationsEnabled && !config.popupEnabled) {return "disabled"}
        if !(2...6).contains(calendar.component(.weekday,from:now)) {return "weekend"}
        if state.completedByCopy {return "alreadyCopied"}
        guard let scheduled=scheduled(now,time:config.time,calendar:calendar) else{return "invalidTime"}
        let elapsed=now.timeIntervalSince(scheduled)
        if elapsed<0 {return "tooEarly"}
        if elapsed>=300 {return "outsideWindow"}
        return "eligible"
    }
    static func next(now:Date,config:ReminderConfiguration,days:[String:ReminderDayState],calendar:Calendar = .current)->Date? {
        guard config.reminderEnabled && (config.notificationsEnabled || config.popupEnabled) else{return nil}
        for offset in 0..<15 {
            guard let date=calendar.date(byAdding:.day,value:offset,to:now),let candidate=scheduled(date,time:config.time,calendar:calendar), candidate>now else{continue}
            let state=days[ReminderRules.day(candidate,calendar:calendar)] ?? ReminderDayState()
            if !(2...6).contains(calendar.component(.weekday,from:candidate)) || state.completedByCopy {continue}
            if (!config.notificationsEnabled || state.notificationClaimed) && (!config.popupEnabled || state.popupClaimed) {continue}
            return candidate
        }
        return nil
    }
}
/// 文件锁涵盖原子状态写入；进程间共享，不依赖UserDefaults缓存。
final class ReminderFileLock {
    let fd:Int32
    init(_ url:URL)throws {
        fd=open(url.path,O_CREAT|O_RDWR,0o600)
        if fd<0 {throw CocoaError(.fileWriteUnknown)}
    }
    func tryAcquire()->Bool {flock(fd,LOCK_EX|LOCK_NB)==0}
    func acquire()throws {if flock(fd,LOCK_EX) != 0 {throw CocoaError(.fileWriteUnknown)}}
    func release(){flock(fd,LOCK_UN)}
    deinit {close(fd)}
}
struct ReminderLedger {
    let directory:URL
    var file:URL {directory.appendingPathComponent("reminder-state.json")}
    static func directory(sessionID:String?)->URL {
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        return sessionID.map {support.appendingPathComponent("DailyTodoTesting/\($0)/ReminderState")} ?? support.appendingPathComponent("DailyTodo-ReminderState")
    }
    func makeLock()throws->ReminderFileLock {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        return try ReminderFileLock(directory.appendingPathComponent("state.lock"))
    }
    /// Caller owns lock, including across async notification submission.
    func readLocked()throws->ReminderLedgerState {
        guard FileManager.default.fileExists(atPath:file.path) else{return ReminderLedgerState()}
        let state=try JSONDecoder().decode(ReminderLedgerState.self,from:Data(contentsOf:file))
        guard state.schemaVersion==1 else{throw CocoaError(.fileReadCorruptFile)}
        return state
    }
    func writeLocked(_ state:ReminderLedgerState)throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(state).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func transaction<T>(_ body:(inout ReminderLedgerState)throws->T)throws->T {
        let lock=try makeLock();try lock.acquire();defer{lock.release()}
        var state=try readLocked();let before=state;let result=try body(&state)
        if before != state {try writeLocked(state)}
        return result
    }
    func log(source:String,requestID:String,now:Date,config:ReminderConfiguration,state:ReminderDayState,decision:String,reason:String) {
        let f=ISO8601DateFormatter();f.timeZone = .current
        let payload:[String:Any]=["eventSource":source,"requestId":requestID,"setting":config.time.text,"scheduledLocal":OfficialPolicy.scheduled(now,time:config.time).map{f.string(from:$0)} ?? "invalid","actualLocal":f.string(from:now),"timezone":TimeZone.current.identifier,"localDateKey":ReminderRules.day(now),"copiedToday":state.completedByCopy,"remindersEnabled":config.reminderEnabled,"notificationsEnabled":config.notificationsEnabled,"popupEnabled":config.popupEnabled,"decision":decision,"reason":reason]
        appendLog(payload)
    }
    func appendLog(_ payload:[String:Any]) {
        // 本地不含正文；单独日志锁，最多保留约1MB和一份轮转日志。
        guard let data=try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys) else{return}
        let url=directory.appendingPathComponent("reminder-events.jsonl")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        guard let lock=try? ReminderFileLock(directory.appendingPathComponent("log.lock")),lock.tryAcquire() else{return};defer{lock.release()}
        if let size=(try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber,size.intValue>1_000_000 {
            let old=directory.appendingPathComponent("reminder-events.previous.jsonl");try? FileManager.default.removeItem(at:old);try? FileManager.default.moveItem(at:url,to:old)
        }
        if !FileManager.default.fileExists(atPath:url.path){FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])}
        if let handle=try? FileHandle(forWritingTo:url){defer{try? handle.close()};_ = try? handle.seekToEnd();try? handle.write(contentsOf:data+Data([10]))}
    }
}
