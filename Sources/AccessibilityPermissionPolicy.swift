import Foundation

enum AccessibilityAccessVerdict:String {case allowed,denied,unknown}

enum AccessibilityPermissionStatus:Equatable {
    case checking,notGranted,restartRequired,allowed
    var ready:Bool {self == .allowed}
    static func evaluate(current:Bool,fresh:Bool?,access:AccessibilityAccessVerdict = .unknown)->Self {
        if access == .allowed {return .allowed}
        if access == .denied {return fresh == true ? .restartRequired : .notGranted}
        guard let fresh else {return .checking}
        guard fresh else {return .notGranted}
        return current ? .allowed : .restartRequired
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
