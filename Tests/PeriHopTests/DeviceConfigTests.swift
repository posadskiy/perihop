import Testing
import Foundation
@testable import PeriHop

struct DeviceConfigTests {
    @Test func roundTripsThroughJSON() throws {
        let config = DeviceConfig(devices: [
            DeviceEntry(name: "Magic Keyboard", address: DeviceAddress("aa-bb-cc-dd-ee-ff")),
            DeviceEntry(name: "Magic Trackpad", address: DeviceAddress("11-22-33-44-55-66")),
        ])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DeviceConfig.self, from: data)

        #expect(decoded == config)
    }

    @Test func addressEncodesAsPlainStringNotNestedObject() throws {
        // DeviceAddress wraps a String, but the on-disk config format (and
        // anything a previous build already wrote) must stay a plain JSON
        // string for that field, not `{"rawValue": "..."}`.
        let entry = DeviceEntry(name: "Magic Keyboard", address: DeviceAddress("aa-bb-cc-dd-ee-ff"))

        let data = try JSONEncoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""aa-bb-cc-dd-ee-ff""#))
        #expect(!json.contains("rawValue"))
    }

    @Test func decodesPlainStringAddress() throws {
        let json = #"{"name":"Magic Keyboard","address":"aa-bb-cc-dd-ee-ff"}"#

        let entry = try JSONDecoder().decode(DeviceEntry.self, from: Data(json.utf8))

        #expect(entry.address == DeviceAddress("aa-bb-cc-dd-ee-ff"))
        #expect(entry.name == "Magic Keyboard")
    }
}
