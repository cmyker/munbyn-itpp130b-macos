public enum BLEWritePreference: String,Codable {
    case withResponse = "with-response"
    case withoutResponse = "without-response"
    public static func choose(preferred: Self?,withResponse: Bool,withoutResponse: Bool) throws -> Self {
        if let preferred {
            guard preferred == .withResponse ? withResponse : withoutResponse else {
                throw BridgeError.invalid("Selected BLE write mode is unavailable; no silent fallback")
            }
            guard withResponse else { throw BridgeError.invalid("A response-capable characteristic is required for the final data chunk") }
            return preferred
        }
        // Prefer streaming writes when the selected characteristic supports them.
        // Readiness, mode-specific limits and pacing still apply; neither mode
        // supplies a physical-print acknowledgement. Saved preferences win above.
        if withoutResponse && withResponse { return .withoutResponse }
        if withResponse { return .withResponse }
        throw BridgeError.invalid("A response-capable characteristic is required for the final data chunk")
    }
}
