import Foundation
struct CopyMessages {
    let messages: [String]
    private var previous: String?
    init(messages: [String], previous: String? = nil) { self.messages = messages; self.previous = previous }
    static func load(_ url: URL) throws -> [String] {
        try JSONDecoder().decode([String].self,from:Data(contentsOf:url))
    }
    mutating func next() -> String? {
        let candidates = messages.filter { $0 != previous }
        let chosen = candidates.randomElement() ?? messages.first
        previous = chosen; return chosen
    }
}
