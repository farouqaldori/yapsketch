import Foundation

struct Screenshot {
    let n: Int
    /// When the point ends.
    let t: Double
    var picture: Picture
}

struct Picture {
    /// Relative to the session folder.
    let path: String
    let t: Double
    /// The user's drawings and pointer circles it shows.
    var marks: [SessionEvent] = []

    /// "A drawing", "2 drawings and a pointer circle".
    var shows: String {
        let drawings = marks.filter { $0.kind != .gesture }.count
        let said = [(drawings, "drawing"), (marks.count - drawings, "pointer circle")].filter { $0.0 > 0 }.map {
            $0.0 == 1 ? "a \($0.1)" : "\($0.0) \($0.1)s"
        }.joined(separator: " and ")
        return said.prefix(1).uppercased() + said.dropFirst()
    }
}
