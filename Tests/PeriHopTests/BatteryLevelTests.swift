import Foundation
import Testing
@testable import PeriHop

struct BatteryLevelTests {
    @Test func zeroFromBluetoothIsHiddenUntilTheRegistryHasALevel() {
        #expect(BatteryLevel.choose(reported: [0], registry: nil) == nil)
        #expect(BatteryLevel.choose(reported: [0, 0], registry: 64) == 64)
        #expect(BatteryLevel.choose(reported: [81], registry: 10) == 81)
        #expect(BatteryLevel.choose(reported: [-1, 140], registry: 0) == nil)
    }

    @Test func productNameMatchesTheAccessoryAndNotTheBuiltInKeyboard() {
        #expect(BatteryLevel.namesMatch(product: "Dimitri’s Magic Keyboard", device: "Dimitri’s Magic Keyboard"))
        #expect(BatteryLevel.namesMatch(product: "Magic Keyboard", device: "Dimitri’s Magic Keyboard"))
        #expect(!BatteryLevel.namesMatch(product: "Apple Internal Keyboard / Trackpad", device: "Dimitri’s Magic Keyboard"))
    }

    @Test func addressMatchesTextAndEitherByteOrder() {
        let address = DeviceAddress("38:09:fb:1a:a7:cc")
        #expect(BatteryLevel.matchesAddress("38-09-FB-1A-A7-CC", address: address))
        let bytes = Data([0x38, 0x09, 0xfb, 0x1a, 0xa7, 0xcc])
        #expect(BatteryLevel.matchesAddress(bytes, address: address))
        #expect(BatteryLevel.matchesAddress(Data(bytes.reversed()), address: address))
        #expect(!BatteryLevel.matchesAddress("4c-74-bf-f2-a3-1b", address: address))
        #expect(BatteryLevel.matchesAddress(NSData(data: bytes), address: address))
    }

    @Test func nameMatchIsDroppedWhenTwoAccessoriesDisagree() {
        #expect(BatteryLevel.chooseByName([]) == nil)
        #expect(BatteryLevel.chooseByName([55, 55]) == 55)
        #expect(BatteryLevel.chooseByName([55, 90]) == nil)
    }
}
