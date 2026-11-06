import Foundation

@main
enum WheelMotionTests {
    static func main() {
        var motion = WheelMotion()
        precondition(motion.advance(0.24) == 0)
        precondition(motion.advance(0.28) == 1)
        precondition(abs(motion.offset + 0.48) < 0.001)
        precondition(motion.advance(2.70) == 2)
        precondition(abs(motion.offset - 0.22) < 0.001)

        motion.reset()
        var coast = 0
        for _ in 0..<20 { coast += motion.advance(1, momentum: true) }
        precondition(coast == 3 && motion.offset == 0)
        motion.reset()
        precondition(motion.advance(-1.6, momentum: true) == -2)
        precondition(motion.advance(-6, momentum: true) == -1)
        precondition(motion.advance(-1, momentum: true) == 0)

        motion.reset()
        precondition(motion.advance(-0.5) == -1)
        precondition(motion.advance(0) == 0)
        precondition(WheelMotion.wrap(-1, maximum: 23) == 23)
        precondition(WheelMotion.wrap(60, maximum: 59) == 0)
        precondition(WheelMotion.wrap(27, maximum: 23) == 3)
        precondition(WheelMotion.mouseSteps(for: 3) == 1)
        precondition(WheelMotion.mouseSteps(for: -9) == -3)
        precondition(WheelMotion.mouseSteps(for: 120) == 6)
        print("PASS: slow, fast, reversal, momentum budget, and circular limits")
    }
}
