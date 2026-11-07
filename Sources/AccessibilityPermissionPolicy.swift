import Foundation

enum AccessibilityPermissionStatus:Equatable {
    case checking,notGranted,restartRequired,allowed
    var ready:Bool {self == .allowed}
    static func evaluate(current:Bool,fresh:Bool?)->Self {
        guard let fresh else {return .checking}
        guard fresh else {return .notGranted}
        return current ? .allowed : .restartRequired
    }
}
