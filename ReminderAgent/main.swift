import AppKit
let args=CommandLine.arguments
let sessionID:String? = {
    if let i=args.firstIndex(of:"--integration-session"),args.indices.contains(i+1),UUID(uuidString:args[i+1]) != nil{return args[i+1]}
#if INTEGRATION_TESTING
    FileHandle.standardError.write(Data("测试辅助程序必须指定有效的会话 UUID。\n".utf8))
    exit(64)
#else
    return nil
#endif
}()
let ledger=ReminderLedger(directory:ReminderLedger.directory(sessionID:sessionID))
do {
    let state=try ledger.transaction{$0}
    guard let config=state.configuration else {exit(0)}
    let now=Date(),day=state.days[ReminderRules.day(now)] ?? ReminderDayState()
    let reason=OfficialPolicy.reason(now:now,config:config,state:day)
    ledger.log(source:"agent-preflight",requestID:"daily.todo.reminder."+ReminderRules.day(now),now:now,config:config,state:day,decision:reason == "eligible" ? "open-background" : "skip",reason:reason)
    guard reason == "eligible",(config.notificationsEnabled && !day.notificationClaimed) || (config.popupEnabled && !day.popupClaimed) else{exit(0)}
} catch {ledger.appendLog(["eventSource":"agent-preflight","decision":"skip","reason":"stateReadFailure","error":error.localizedDescription]);exit(1)}
let own=URL(fileURLWithPath:args[0]).resolvingSymlinksInPath()
let application=own.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let configuration=NSWorkspace.OpenConfiguration();configuration.activates=false
configuration.arguments=["--background","--official-agent"]
if let sessionID {configuration.arguments += ["--integration-session",sessionID]}
let scheme=sessionID == nil ? "dailytodo-reminder" : "dailytodo-reminder-testing"
NSWorkspace.shared.open([URL(string:"\(scheme)://open")!],withApplicationAt:application,configuration:configuration){_,error in exit(error == nil ? 0 : 1)}
RunLoop.main.run()
