import Testing
@testable import BridgeCore

struct WriteModeTests {
    @Test func selectsOnlyAnAvailableExplicitWriteMode() throws {
        #expect(try BLEWritePreference.choose(preferred:.withResponse,withResponse:true,withoutResponse:true) == .withResponse)
        #expect(try BLEWritePreference.choose(preferred:.withoutResponse,withResponse:true,withoutResponse:true) == .withoutResponse)
        expectThrows(try BLEWritePreference.choose(preferred:nil,withResponse:false,withoutResponse:true))
        expectThrows(try BLEWritePreference.choose(preferred:.withoutResponse,withResponse:false,withoutResponse:true))
        expectThrows(try BLEWritePreference.choose(preferred:.withoutResponse,withResponse:true,withoutResponse:false))
        expectThrows(try BLEWritePreference.choose(preferred:.withResponse,withResponse:false,withoutResponse:true))
        expectThrows(try BLEWritePreference.choose(preferred:nil,withResponse:false,withoutResponse:false))
    }
    @Test func newSelectionUsesStreamingWritesWhenSupported() throws {
        #expect(try BLEWritePreference.choose(preferred:nil,withResponse:true,withoutResponse:true) == .withoutResponse)
        #expect(try BLEWritePreference.choose(preferred:nil,withResponse:true,withoutResponse:false) == .withResponse)
    }
}
