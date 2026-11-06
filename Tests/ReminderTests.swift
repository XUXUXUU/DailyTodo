import Foundation
@main struct ReminderTests {
 static func main() throws {
    if CommandLine.arguments.count>2 && CommandLine.arguments[1]=="--claim" {
        let ledger=ReminderLedger(directory:URL(fileURLWithPath:CommandLine.arguments[2]))
        try ledger.transaction {s in
            var day=s.days["2026-11-03"] ?? ReminderDayState()
            if !day.notificationClaimed && !day.completedByCopy {day.notificationClaimed=true;s.days["2026-11-03"]=day;print("CLAIMED")}
        };return
    }
    var checks=[String:Bool]();var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Shanghai")!
    let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=calendar.timeZone;f.dateFormat="yyyy-MM-dd HH:mm:ss"
    func d(_ s:String)->Date {f.date(from:s)!}
    let config=ReminderConfiguration()
    func reason(_ s:String,_ day:ReminderDayState=ReminderDayState(),_ c:ReminderConfiguration=config)->String {OfficialPolicy.reason(now:d(s),config:c,state:day,calendar:calendar)}
    checks["T06_afternoonOutsideWindow"]=reason("2026-11-03 14:30:00")=="outsideWindow"
    checks["beforeTooEarly"]=reason("2026-11-03 08:49:59")=="tooEarly"
    checks["T07_atTime"]=reason("2026-11-03 08:50:00")=="eligible"
    checks["windowLastSecond"]=reason("2026-11-03 08:54:59")=="eligible"
    checks["windowStrictUpperBound"]=reason("2026-11-03 08:55:00")=="outsideWindow"
    checks["weekend"]=reason("2026-11-07 08:50:00")=="weekend"
    checks["masterOff"]=reason("2026-11-03 08:50:00",ReminderDayState(),ReminderConfiguration(reminderEnabled:false))=="disabled"
    let completed=ReminderDayState(completedByCopy:true,copiedAt:d("2026-11-03 07:30:00"))
    checks["T08_completionSuppresses"]=reason("2026-11-03 08:50:00",completed)=="alreadyCopied"
    checks["T11_changedTimeKeepsCompletion"]=reason("2026-11-03 10:00:00",completed,ReminderConfiguration(time:ReminderTime(hour:10,minute:0)))=="alreadyCopied"
    checks["T10_editIsNotCompletion"]=reason("2026-11-03 08:50:00")=="eligible"
    checks["T12_nextWorkday"]=OfficialPolicy.next(now:d("2026-11-06 07:30:00"),config:config,days:["2026-11-06":completed],calendar:calendar)==d("2026-11-09 08:50:00")
    var la=calendar;la.timeZone=TimeZone(identifier:"America/Los_Angeles")!
    let l=DateFormatter();l.timeZone=la.timeZone;l.dateFormat=f.dateFormat
    checks["localTimeZoneDST"]=OfficialPolicy.reason(now:l.date(from:"2026-11-02 08:50:00")!,config:config,state:ReminderDayState(),calendar:la)=="eligible"
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let ledger=ReminderLedger(directory:root)
    try ledger.transaction{s in s.configuration=config;s.days["2026-11-03"]=completed}
    checks["T09_reopenPersistentCompletion"]=try ReminderLedger(directory:root).transaction{$0.days["2026-11-03"]?.completedByCopy==true}
    try ledger.transaction{$0.days=[:]}
    var processes=[Process](),pipes=[Pipe]()
    for _ in 0..<12 {let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=["--claim",root.path];p.standardOutput=pipe;try p.run();processes.append(p);pipes.append(pipe)}
    var winners=0
    for (p,pipe) in zip(processes,pipes) {let text=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);p.waitUntilExit();winners += text.contains("CLAIMED") ? 1:0}
    checks["T14_twelveProcessesOneClaim"]=winners==1
    do {let corrupt=ReminderLedger(directory:root.appendingPathComponent("bad"));_ = try corrupt.makeLock();try Data("bad".utf8).write(to:corrupt.file);_ = try corrupt.transaction{$0};checks["corruptFailsClosed"]=false}catch{checks["corruptFailsClosed"]=true}
    let data=try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self));if checks.values.contains(false){exit(1)}
 }
}
