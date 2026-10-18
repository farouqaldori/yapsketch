import Foundation

struct TypeSafe: Provider {
    let id = "typesafe"
    let name = "TypeSafe"
    let offers = "Jev"

    private static let systemOne = URL(string: "https://api.typesafe.ai/v1/systemone")!

    var connect: Connect {
        .apiKey(getOne: URL(string: "https://docs.typesafe.ai")!) { key in await Jev.check(key, at: Self.systemOne, model: "jev-1.14.0") }
    }

    var jev: JevEndpoint? { JevEndpoint(url: Self.systemOne, model: "jev-1.14.0", images: .multipart) }
}
