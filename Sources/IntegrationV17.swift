#if INTEGRATION_TESTING
import AppKit
import UserNotifications
extension AppDelegate {
    func runV17Scenarios() async {
        var checks=[String:Bool]();var popups=0
        services.onOfficialPopup={popups += 1}
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone = .current;f.dateFormat="yyyy-MM-dd HH:mm:ss"
        func date(_ s:String)->Date {f.date(from:s)!}
        let key="2026-11-03",base=date("2026-11-03 08:50:00")
        func reset()throws {
            try services.ledger.transaction{$0.days=[:]}

        }
        do {
            let old=UNMutableNotificationContent();old.title=NotificationCopy.title
            // Exercise migration without registering an indefinitely repeating test alarm.
            let legacyTrigger=UNTimeIntervalNotificationTrigger(timeInterval:3600,repeats:false)
            try await services.center.add(UNNotificationRequest(identifier:services.prefix+"weekday.3",content:old,trigger:legacyTrigger))
            checks["legacySeeded"]=await services.center.pendingNotificationRequests().contains{$0.identifier==services.prefix+"weekday.3"}
            _ = await services.apply(time:ReminderTime(hour:8,minute:50),enabled:true,notifications:true,popup:true,requestPermission:true)
            checks["T16_noCalendarNotificationsAfterMigration"]=await services.center.pendingNotificationRequests().filter{services.owns($0.identifier)}.isEmpty
            let agent=await services.scheduler.command(["print",services.scheduler.service]);checks["realLaunchAgentRegistered"]=agent.code==0
            try reset();services.clock={date("2026-11-03 14:30:00")}
            for source in ["agent","wake","open","settings"] {await services.deliverOfficial(source:source)}
            checks["T06_lateNoClaimOrPopup"]=try services.ledger.transaction{$0.days[key]==nil} && popups==0
            services.clock={base};try reset()
            model.edit(\.tasks,"仅编辑不复制");_ = model.flush()
            await services.deliverOfficial(source:"open")
            checks["ordinaryOpenDoesNotSend"]=try services.ledger.transaction{$0.days[key]==nil}
            await services.deliverOfficial(source:"agent");await services.deliverOfficial(source:"wake");await services.deliverOfficial(source:"agent")
            try? await Task.sleep(nanoseconds:700_000_000)
            let delivered=await services.center.deliveredNotifications().filter{$0.request.identifier==services.officialID(key)}
            checks["T07_actualNotificationAndPopupCallback"]=delivered.count==1 && popups==1 && delivered.first?.request.content.title==NotificationCopy.title
            checks["T10_editWithoutCopyStillReminds"]=try services.ledger.transaction{$0.days[key]?.completedByCopy==false && $0.days[key]?.notificationClaimed==true}
            checks["T14_duplicateEventsOnlyOnce"]=try services.ledger.transaction{$0.days[key]?.notificationClaimed==true && $0.days[key]?.popupClaimed==true} && popups==1
            try reset();let before=popups
            services.recordCopiedToday(at:date("2026-11-03 07:30:00"));await services.completionTask?.value
            await services.deliverOfficial(source:"agent")
            checks["T08_copySuppressesBoth"]=try services.ledger.transaction{$0.days[key]?.completedByCopy==true && $0.days[key]?.notificationClaimed==false && $0.days[key]?.popupClaimed==false} && popups==before
            _ = await services.apply(time:ReminderTime(hour:10,minute:0));services.clock={date("2026-11-03 10:00:00")};await services.deliverOfficial(source:"agent")
            checks["T11_rescheduleKeepsCompletion"]=try services.ledger.transaction{$0.days[key]?.completedByCopy==true && $0.days[key]?.popupClaimed==false}
            let beforeState=try services.ledger.transaction{$0};let beforeNext=services.nextText
            await services.test();try? await Task.sleep(nanoseconds:700_000_000)
            let afterTestState=try services.ledger.transaction{$0}
            checks["T15_testAfterCopy"]=services.testWasSubmitted && afterTestState==beforeState && services.nextText==beforeNext
            services.clock={date("2026-11-04 10:00:00")};await services.deliverOfficial(source:"agent")
            checks["T12_nextDayDoesNotInheritCompletion"]=try services.ledger.transaction{$0.days["2026-11-04"]?.notificationClaimed==true && $0.days["2026-11-04"]?.completedByCopy==false}
            try reset();_ = await services.apply(time:ReminderTime(hour:8,minute:50),notifications:false,popup:true);services.clock={date("2026-11-05 08:50:00")};let channelKey="2026-11-05";let n=popups
            await services.deliverOfficial(source:"agent")
            checks["T13_popupOnly"]=try services.ledger.transaction{$0.days[channelKey]?.popupClaimed==true && $0.days[channelKey]?.notificationClaimed==false} && popups==n+1
            try reset();_ = await services.apply(notifications:true,popup:false);let n2=popups;await services.deliverOfficial(source:"agent")
            checks["T13_notificationOnly"]=try services.ledger.transaction{$0.days[channelKey]?.notificationClaimed==true && $0.days[channelKey]?.popupClaimed==false} && popups==n2
            for time in [ReminderTime(hour:8,minute:20),ReminderTime(hour:8,minute:50)] {_ = await services.apply(time:time)}
            let safeState=try Data(contentsOf:services.ledger.file)
            try Data("invalid".utf8).write(to:services.ledger.file)
            services.recordCopiedToday(at:date("2026-11-06 07:30:00"));await services.completionTask?.value
            checks["completionWriteFailureTruthful"]=services.completionError != nil
            try safeState.write(to:services.ledger.file,options:.atomic)
            services.clock={date("2026-11-09 08:50:00")};services.retryPendingCopies();await services.completionTask?.value
            checks["completionRetryPreservesOriginalDate"]=try services.ledger.transaction{$0.days["2026-11-06"]?.completedByCopy==true && $0.days["2026-11-09"]==nil} && services.completionError==nil
            checks["T16_timeChangesNoPendingUN"]=await services.center.pendingNotificationRequests().filter{services.owns($0.identifier)}.isEmpty
        }catch {Runtime.report("v17-scenario-error",payload:["error":error.localizedDescription]);checks["noThrownError"]=false}
        Runtime.report("v17-scenarios",payload:checks);Runtime.event("v17-scenarios-finished")
    }
}
#endif
