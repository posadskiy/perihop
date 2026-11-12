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

    @Test func configFromAnOlderVersionStillLoads() throws {
        let json = #"""
        {"devices":[{"address":"38-09-fb-1a-a7-cc","bondMode":"single","holder":"thisMac","holderSince":815952132.7,"name":"Magic Keyboard"}]}
        """#

        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(json.utf8))

        #expect(config.devices == [DeviceEntry(name: "Magic Keyboard", address: "38-09-fb-1a-a7-cc")])
    }

    @Test func pointerMovesBeforeTheKeyboard() {
        let keyboard = DeviceEntry(name: "Magic Keyboard", address: "aa-bb-cc-dd-ee-01")
        let mouse = DeviceEntry(name: "Magic Mouse", address: "aa-bb-cc-dd-ee-02")
        let trackpad = DeviceEntry(name: "Dmitrii’s Trackpad", address: "aa-bb-cc-dd-ee-03")

        #expect(DeviceEntry.handoffOrder([keyboard, mouse, trackpad]) == [trackpad, mouse, keyboard])
    }

    @Test func phonesAndHeadphonesAreNotOfferedForSwitching() {
        #expect(BTDevice.nameSuggestsInput("Dimitri’s Magic Keyboard"))
        #expect(BTDevice.nameSuggestsInput("MX Master 3"))
        #expect(!BTDevice.nameSuggestsInput("iPhone 2nd"))
        #expect(!BTDevice.nameSuggestsInput("Dmitriy’s Apple Watch"))
        #expect(!BTDevice.nameSuggestsInput("Dimitri’s AirPods"))
    }

    @Test func urlFilterMatchesNameOrAddress() {
        let keyboard = DeviceEntry(name: "Magic Keyboard", address: "aa-bb-cc-dd-ee-01")
        let trackpad = DeviceEntry(name: "Magic Trackpad", address: "aa-bb-cc-dd-ee-03")
        let all = [keyboard, trackpad]

        #expect(AppModel.matching([], in: all) == all)
        #expect(AppModel.matching(["trackpad"], in: all) == [trackpad])
        #expect(AppModel.matching(["AA:BB:CC:DD:EE:01"], in: all) == [keyboard])
        #expect(AppModel.matching(["mouse"], in: all).isEmpty)
    }
}
