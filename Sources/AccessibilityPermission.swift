import AppKit
import ApplicationServices
import Combine

@MainActor final class AccessibilityPermission:ObservableObject {
    static let shared=AccessibilityPermission()
    static let prepareRestartNotification=Notification.Name("DailyTodoPreparePermissionRestart")
    static let restoreRestartNotification=Notification.Name("DailyTodoRestorePermissionSettings")
    static let restartNotification=Notification.Name("DailyTodoRestartForAccessibility")
    @Published private(set) var status:AccessibilityPermissionStatus = .checking
    @Published private(set) var lastCheck:Date?
    @Published var error:String?
    @Published var hasOpenedSettings=CommandLine.arguments.contains("--resume-forwarding-setup") || CommandLine.arguments.contains("--resume-onboarding-forwarding")
    var ready:Bool {status.ready && AXIsProcessTrusted()}
    private var observers=0
    private var timer:Timer?
    private var activation:AnyCancellable?
    @Published private(set) var isChecking=false
    private var refreshTask:Task<Void,Never>?

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
    func refresh() async {
        if let pending=refreshTask {await pending.value;return}
        isChecking=true
        let pending=Task { @MainActor in
            defer {isChecking=false;refreshTask=nil}
            await performRefresh()
        }
        refreshTask=pending
        await pending.value
    }
    private func performRefresh() async {
        let executable=Bundle.main.executableURL
        let supported=(Bundle.main.object(forInfoDictionaryKey:"DailyTodoAccessibilityProbeVersion") as? Int)==1
        let fresh:Bool
        if supported,let executable {
            fresh=await Task.detached(priority:.userInitiated) {
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
        } else {fresh=false}
        status = .evaluate(current:AXIsProcessTrusted(),fresh:fresh)
        lastCheck=Date()
        Runtime.report("accessibility-permission",payload:["state":String(describing:status),"current":AXIsProcessTrusted(),"fresh":fresh])
    }
    func restart() {
        guard status == .restartRequired || status == .notGranted else{return}
        NotificationCenter.default.post(name:Self.restartNotification,object:nil)
    }
}
