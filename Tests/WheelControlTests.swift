import AppKit

/// In-process input fixture. No events are posted to the user's desktop.
final class WheelScrollFixture: NSEvent {
    var delta: CGFloat = 0
    var gesture: NSEvent.Phase = []
    var inertia: NSEvent.Phase = []
    override var scrollingDeltaY: CGFloat { -delta }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { gesture }
    override var momentumPhase: NSEvent.Phase { inertia }
}

@main
enum WheelControlTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let wheel = WheelControl(frame: NSRect(x:0,y:0,width:125,height:172))
        wheel.updateFromBinding(20,presetRevision:0)
        func scroll(_ rows:CGFloat, _ phase:NSEvent.Phase = .changed,
                    momentum:NSEvent.Phase = []) {
            let event = WheelScrollFixture()
            event.delta = rows * 34
            event.gesture = phase
            event.inertia = momentum
            wheel.scrollWheel(with:event)
        }

        scroll(0,.began)
        scroll(0.45)
        try await Task.sleep(nanoseconds:250_000_000)
        precondition(wheel.value == 20 && wheel.input.isHidden,
                     "A held gesture must retain its visible fractional offset")
        scroll(0.06)
        precondition(wheel.value == 21)
        scroll(0,.ended)
        scroll(1,momentum:.changed)
        for _ in 0..<20 { scroll(1,momentum:.changed) }
        scroll(0,momentum:.ended)
        try await Task.sleep(nanoseconds:250_000_000)
        precondition(wheel.value == 24 && !wheel.input.isHidden,
                     "Coasting must be bounded and finish on an integer")

        wheel.updateFromBinding(50,presetRevision:1)
        scroll(3,momentum:.changed)
        precondition(wheel.value == 50, "A preset must discard obsolete momentum")
        wheel.reduceMotion = true
        scroll(0,.began)
        scroll(0.55)
        precondition(wheel.value == 51 && !wheel.input.isHidden)
        scroll(0,.ended)
        scroll(3,momentum:.changed)
        precondition(wheel.value == 51)

        wheel.reduceMotion = false
        wheel.updateFromBinding(59,presetRevision:2)
        scroll(0,.began)
        scroll(1)
        precondition(wheel.value == 0)
        scroll(0,.ended)
        try await Task.sleep(nanoseconds:250_000_000)
        precondition(!wheel.input.isHidden)
        print("PASS: held gesture, bounded coast, snap, preset interruption, reduced motion, boundary")
    }
}
