import AppKit
import ApplicationServices
import Combine

/// A bounded read of another process is the live permission signal. No contents are traversed.
enum AccessibilityLiveAccess {
    static func read(pid:pid_t)->AccessibilityAccessVerdict {
        guard pid != ProcessInfo.processInfo.processIdentifier else {return .unknown}
        let target=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(target,0.25)
        var value:CFTypeRef?
        let error=AXUIElementCopyAttributeValue(target,kAXWindowsAttribute as CFString,&value)
        if error == .apiDisabled {return .denied}
        if error == .success,let value,CFGetTypeID(value)==CFArrayGetTypeID() {return .allowed}
        return .unknown
    }
    @MainActor static func candidatePIDs()->[pid_t] {
        let workspace=NSWorkspace.shared
        let apps=workspace.runningApplications
        let preferred=[workspace.frontmostApplication?.bundleIdentifier,"com.electron.lark","com.apple.finder","com.apple.systempreferences"].compactMap {$0}
        var seen=Set<pid_t>()
        return preferred.compactMap { id in
            guard let app=apps.first(where:{$0.bundleIdentifier==id && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier}),seen.insert(app.processIdentifier).inserted else {return nil}
            return app.processIdentifier
        }
    }
    static func probe(pids:[pid_t]) async ->(access:AccessibilityAccessVerdict,trusted:Bool,targets:[pid_t:AccessibilityAccessVerdict]) {
        await Task.detached(priority:.utility) {
            var results:[AccessibilityAccessVerdict]=[]
            for pid in pids {results.append(read(pid:pid))}
            let trusted=AXIsProcessTrusted()
            Runtime.report("accessibility-probes",payload:["pids":pids,"results":results.map(\.rawValue),"workerTrusted":trusted])
            return (AccessibilityAccessVerdict.combining(results),trusted,Dictionary(uniqueKeysWithValues:zip(pids,results)))
        }.value
    }

}

@MainActor final class AccessibilityPermission:ObservableObject {
    static let shared=AccessibilityPermission()
    static let prepareRestartNotification=Notification.Name("DailyTodoPreparePermissionRestart")
    static let restoreRestartNotification=Notification.Name("DailyTodoRestorePermissionSettings")
    static let restartNotification=Notification.Name("DailyTodoRestartForAccessibility")
    @Published private(set) var status:AccessibilityPermissionStatus = .checking
    @Published private(set) var lastCheck:Date?
    @Published var error:String?
    @Published var hasOpenedSettings=CommandLine.arguments.contains("--resume-forwarding-setup") || CommandLine.arguments.contains("--resume-onboarding-forwarding")
    var ready:Bool {status.ready}
    private var permissionSession=AccessibilityPermissionSession()
    private var observers=0
    private var timer:Timer?
    private var activation:AnyCancellable?
    @Published private(set) var isChecking=false
    private var refreshTask:Task<Void,Never>?
    private var diagnosticTime:Date?
    private var diagnosticResult:Bool?
    private var diagnosticCurrent:Bool?

    private init() {
        activation=NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in
                guard let self,self.observers>0 else{return}
                await self.refresh()
            }}
    }
    func startMonitoring() {
        observers += 1
        if timer == nil {
            timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            if let timer {RunLoop.main.add(timer,forMode:.common)}
        }
        Task {await refresh()}
    }
    func stopMonitoring() {
        observers=max(0,observers-1)
        if observers==0 {timer?.invalidate();timer=nil}
    }
    func refresh(userInitiated:Bool=false) async {
        if userInitiated {isChecking=true}
        defer {if userInitiated {isChecking=false}}
        if let pending=refreshTask {await pending.value;return}
        let pending=Task { @MainActor in
            defer {refreshTask=nil}
            await performRefresh(forceDiagnostic:userInitiated)
        }
        refreshTask=pending
        await pending.value
    }
    private func performRefresh(forceDiagnostic:Bool) async {
        let targetPID=NSRunningApplication.runningApplications(withBundleIdentifier:"com.electron.lark").first?.processIdentifier
        let probe=await AccessibilityLiveAccess.probe(pids:AccessibilityLiveAccess.candidatePIDs())
        let access=probe.access
        let target=targetPID.flatMap {probe.targets[$0]} ?? .unknown
        let observedCurrent=AXIsProcessTrusted()
        let shouldDiagnose=forceDiagnostic || diagnosticTime == nil || observedCurrent != diagnosticCurrent ||
            Date().timeIntervalSince(diagnosticTime!)>15 || (access == .allowed && diagnosticResult == false)
        let executable=Bundle.main.executableURL
        let supported=(Bundle.main.object(forInfoDictionaryKey:"DailyTodoAccessibilityProbeVersion") as? Int)==1
        if shouldDiagnose,supported,let executable {
            diagnosticResult=await Task.detached(priority:.userInitiated) {
                let process=Process();let output=Pipe()
                process.executableURL=executable
                process.arguments=["--probe-accessibility"]
                process.standardOutput=output;process.standardError=FileHandle.nullDevice
                defer {if process.isRunning {process.terminate()}}
                do {
                    try process.run()
                    let deadline=ProcessInfo.processInfo.systemUptime+2
                    while process.isRunning && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:25_000_000)}
                    if process.isRunning {process.terminate();return false}
                    let text=String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)
                    return process.terminationStatus==0 && text=="allowed\n"
                } catch {return false}
            }.value
            diagnosticTime=Date();diagnosticCurrent=observedCurrent
        }
        let current=AXIsProcessTrusted()
        let result=permissionSession.evaluate(main:current,worker:probe.trusted,fresh:diagnosticResult,access:access,target:target)
        AccessibilityAuthorizationGate.shared.confirm(ready:result.ready)
        if result != status {status=result}
        lastCheck=Date()
        Runtime.report("accessibility-permission",payload:["state":String(describing:status),"current":current,"worker":probe.trusted,"target":target.rawValue,"fresh":diagnosticResult.map {$0 as Any} ?? NSNull(),"access":access.rawValue,"manual":forceDiagnostic])
    }
    func requireRestart() {
        permissionSession.requireRestart();status = .restartRequired
        AccessibilityAuthorizationGate.shared.confirm(ready:false)
    }
    func restart() {
        guard status == .restartRequired || status == .notGranted else{return}
        NotificationCenter.default.post(name:Self.restartNotification,object:nil)
    }
}
