import Foundation

enum AccessibilityAccessVerdict:String {
    case allowed,denied,unknown
    static func combining(_ results:[Self])->Self {
        if results.contains(.allowed) {return .allowed}
        return results.contains(.denied) ? .denied : .unknown
    }
}

enum AccessibilityPermissionStatus:Equatable {
    case checking,notGranted,restartRequired,allowed
    var ready:Bool {self == .allowed}
    static func evaluate(current:Bool,fresh:Bool?,access:AccessibilityAccessVerdict = .unknown)->Self {
        guard let fresh else {return .checking}
        guard fresh else {return .notGranted}
        guard current else {return .restartRequired}
        return access == .denied ? .restartRequired : .allowed
    }
}


struct AccessibilityGuideContinuation {
    enum Action {case none,returnToApp,closeQuietly}
    private var pending=false
    mutating func begin() {pending=true}
    mutating func cancel() {pending=false}
    mutating func take(ready:Bool,setupOwnsFocus:Bool)->Action {
        guard pending,ready else {return .none}
        pending=false
        return setupOwnsFocus ? .returnToApp : .closeQuietly
    }
}

enum AccessibilityGuideForeground {
    static func isSetup(bundleIdentifier:String?,isOwnApp:Bool)->Bool {
        isOwnApp || bundleIdentifier == "com.apple.systempreferences" || bundleIdentifier == "com.apple.finder"
    }
}

struct AccessibilityPermissionSession {
    private var needsRestart=false
    mutating func requireRestart() {needsRestart=true}
    mutating func evaluate(main:Bool,worker:Bool,fresh:Bool?,access:AccessibilityAccessVerdict,target:AccessibilityAccessVerdict = .unknown)->AccessibilityPermissionStatus {
        var result=AccessibilityPermissionStatus.evaluate(current:main && worker,fresh:fresh,access:access)
        if result == .allowed && target == .denied {result = .restartRequired}
        if result == .restartRequired {needsRestart=true}
        return needsRestart && result == .allowed ? .restartRequired : result
    }
}

/// A bounded, synchronized authorization snapshot for background AX work.
final class AccessibilityAuthorizationGate:@unchecked Sendable {
    static let shared=AccessibilityAuthorizationGate()
    private let lock=NSLock()
    private var checkedAt:Double?
    func confirm(ready:Bool,at:Double=ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer {lock.unlock()};checkedAt=ready ? at:nil
    }
    func permits(at:Double=ProcessInfo.processInfo.systemUptime)->Bool {
        lock.lock();defer {lock.unlock()}
        guard let checkedAt else {return false}
        return at>=checkedAt && at-checkedAt<6
    }
}
