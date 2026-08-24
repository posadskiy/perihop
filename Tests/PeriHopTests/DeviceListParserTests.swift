import Testing
@testable import PeriHop

struct DeviceListParserTests {
    @Test func parsesValidJSON() throws {
        let json = #"[{"address":"aa-bb-cc-dd-ee-ff","name":"Magic Keyboard"},{"address":"11-22-33-44-55-66","name":"Magic Trackpad"}]"#
        let result = DeviceListParser.ProcessResult(status: 0, output: json, wasAborted: false)

        let devices = try DeviceListParser.parse(result)

        #expect(devices.count == 2)
        #expect(devices[0].name == "Magic Keyboard")
        #expect(devices[0].address == DeviceAddress("aa-bb-cc-dd-ee-ff"))
        #expect(devices[1].name == "Magic Trackpad")
    }

    @Test func fallsBackToAddressWhenNameMissing() throws {
        let json = #"[{"address":"aa-bb-cc-dd-ee-ff"}]"#
        let result = DeviceListParser.ProcessResult(status: 0, output: json, wasAborted: false)

        let devices = try DeviceListParser.parse(result)

        #expect(devices.count == 1)
        #expect(devices[0].name == "aa-bb-cc-dd-ee-ff")
    }

    @Test func skipsEntriesMissingAddress() throws {
        let json = #"[{"name":"No Address Here"},{"address":"aa-bb-cc-dd-ee-ff","name":"Valid"}]"#
        let result = DeviceListParser.ProcessResult(status: 0, output: json, wasAborted: false)

        let devices = try DeviceListParser.parse(result)

        #expect(devices.count == 1)
        #expect(devices[0].name == "Valid")
    }

    @Test func emptyArrayReturnsEmpty() throws {
        let result = DeviceListParser.ProcessResult(status: 0, output: "[]", wasAborted: false)

        #expect(try DeviceListParser.parse(result).isEmpty)
    }

    @Test func malformedJSONReturnsEmptyRatherThanThrowing() throws {
        // blueutil exited 0 but the output isn't parseable JSON — treated as
        // "found nothing" rather than a hard failure, since a successful
        // exit means blueutil itself didn't report an error.
        let result = DeviceListParser.ProcessResult(status: 0, output: "not json", wasAborted: false)

        #expect(try DeviceListParser.parse(result).isEmpty)
    }

    @Test func abortedProcessThrowsPermissionError() {
        let result = DeviceListParser.ProcessResult(status: 134, output: "", wasAborted: true)

        #expect(throws: BlueUtilError.self) {
            try DeviceListParser.parse(result)
        }
    }

    @Test func abortedProcessErrorMentionsBluetoothPermission() throws {
        let result = DeviceListParser.ProcessResult(status: 134, output: "", wasAborted: true)

        #expect {
            try DeviceListParser.parse(result)
        } throws: { error in
            (error as? BlueUtilError)?.errorDescription?.contains("Bluetooth access denied") == true
        }
    }

    @Test func genericFailureIncludesRawOutput() throws {
        let result = DeviceListParser.ProcessResult(status: 1, output: "some blueutil error text", wasAborted: false)

        #expect {
            try DeviceListParser.parse(result)
        } throws: { error in
            (error as? BlueUtilError)?.errorDescription?.contains("some blueutil error text") == true
        }
    }
}
