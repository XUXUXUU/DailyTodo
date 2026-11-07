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
