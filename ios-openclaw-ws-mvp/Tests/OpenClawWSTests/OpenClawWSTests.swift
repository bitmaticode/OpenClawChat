import Foundation
import Testing
@testable import OpenClawWS

@Test func jsonValueRoundTrip() throws {
    let value: JSONValue = .object([
        "ok": .bool(true),
        "n": .number(3),
        "s": .string("hola")
    ])

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    guard let object = decoded.objectValue else {
        Issue.record("Expected object JSONValue")
        return
    }

    #expect(object["s"]?.stringValue == "hola")
}
