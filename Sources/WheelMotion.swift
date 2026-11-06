import Foundation

/// Rows relative to the selected integer. Limit only the coast after release,
/// so a deliberate long drag can still travel across the full range.
struct WheelMotion {
    private(set) var offset: Double = 0
    private var remainingCoast: Double = 3

    mutating func advance(_ rows: Double, momentum: Bool = false) -> Int {
        guard rows != 0 else { return 0 }
        let distance: Double
        if momentum {
            let magnitude = min(abs(rows), remainingCoast)
            guard magnitude > 0 else { return 0 }
            remainingCoast -= magnitude
            distance = rows < 0 ? -magnitude : magnitude
        } else {
            distance = rows
        }

        let position = offset + distance
        // At exactly half a row, select in the direction of travel.
        let nearest = distance > 0 ? floor(position + 0.5) : ceil(position - 0.5)
        offset = position - nearest
        return Int(nearest)
    }

    mutating func reset() { self = WheelMotion() }

    static func mouseSteps(for lines: Double) -> Int {
        guard lines != 0 else { return 0 }
        // AppKit supplies logical lines, which can be several lines per notch.
        let steps = Int(min(6, max(1, (abs(lines) / 3).rounded())))
        return lines > 0 ? steps : -steps
    }

    static func wrap(_ number: Int, maximum: Int) -> Int {
        let count = maximum + 1
        return (number % count + count) % count
    }
}
