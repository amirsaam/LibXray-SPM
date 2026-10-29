import Foundation

// Re-exports the bundled binary target, so advanced users can call the raw
// `CGoInvoke` / `CGoFree` C entry points with a single
// `import LibXraySwift`. The rest of the module funnels all engine traffic
// through them.
@_exported import LibXray

/// Bridges between this process and the libXray engine (Xray-core compiled
/// for every Apple platform).
///
/// Every call is synchronous: it serializes a request, hands it to the C
/// entry point, frees the returned C string, and decodes the answer. Engine
/// launches and latency probes block, so run those from a background task.
public enum XrayBridge {
    /// Protocol number the engine accepts. These change only if
    /// XTLS/libXray raises its version constant; a mismatch shows up as
    /// "unsupported apiVersion" engine errors.
    static let protocolVersion = 3

    // MARK: Raw plumbing (also usable directly as static methods)

    /// Sends a raw request document to the engine and returns the raw
    /// response document. Strings returned by the engine are malloc'd; this
    /// method releases them internally, so no cleanup is left for callers.
    public static func rawCall(_ request: String) -> String {
        var bytes = Array(request.utf8CString)
        guard let response = CGoInvoke(&bytes) else {
            return "{\"success\":false,\"data\":null,\"error\":\"CGoInvoke returned no response\"}"
        }
        defer { CGoFree(response) }
        return String(cString: response)
    }

    // MARK: Internal machinery

    /// The operations the engine understands, keyed by the strings its Go
    /// side dispatches on.
    enum Method: String {
        case sparePorts = "getFreePorts"
        case decodeSubscription = "decodeSubscriptionText"
        case configFromShareLinks = "convertShareLinksToXrayJson"
        case shareLinksFromConfig = "convertXrayJsonToShareLinks"
        case newAgeKeys = "generateAgeKeyPair"
        case catalogGeoData = "countGeoData"
        case ping = "pingBatch"
        case checkConfig = "testXray"
        case launchEngine = "runXray"
        case stopEngine = "stopXray"
        case engineVersion = "xrayVersion"
        case engineState = "getXrayState"
    }

    /// Envelope every engine answer arrives in.
    struct EngineEnvelope<Payload: Decodable>: Decodable {
        let succeeded: Bool
        let payload: Payload?
        let failure: String?

        enum CodingKeys: String, CodingKey {
            case succeeded = "success"
            case payload = "data"
            case failure = "error"
        }
    }

    /// Stand-in payload for operations that only report success or failure.
    struct EngineEnvelopeNoPayload: Decodable {}

    /// Sends an operation with no payload.
    static func send(_ method: Method) throws -> String {
        rawCall("""
        {"apiVersion":\(protocolVersion),"method":"\(method.rawValue)"}
        """)
    }

    /// Sends an operation with a payload, encoding it as JSON.
    static func send<Payload: Encodable>(_ method: Method, payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EngineError("payload could not be encoded as UTF-8 JSON")
        }
        return rawCall("""
        {"apiVersion":\(protocolVersion),"method":"\(method.rawValue)","payload":\(text)}
        """)
    }

    /// Decodes an envelope and returns its payload, raising `EngineError`
    /// on engine-reported failures. An envelope's payload is always present
    /// on success; for purely status operations it is an empty object, so
    /// callers pass that unless they expect structured data.
    static func resolved<Payload: Decodable>(_ envelope: EngineEnvelope<Payload>) throws -> Payload {
        guard envelope.succeeded else {
            throw EngineError(envelope.failure ?? "engine failure with no message")
        }
        guard let payload = envelope.payload else {
            throw EngineError("engine reported success but answered without a payload")
        }
        return payload
    }

    /// Parses a raw engine response into its envelope.
    static func envelope<Payload: Decodable>(of response: String, as type: Payload.Type) throws -> EngineEnvelope<Payload> {
        try JSONDecoder().decode(EngineEnvelope<Payload>.self, from: Data(response.utf8))
    }

    /// Runs an operation and returns its decoded payload.
    static func ask<Payload: Decodable>(_ method: Method, as type: Payload.Type) throws -> Payload {
        try resolved(envelope(of: try send(method), as: Payload.self))
    }

    /// Runs an operation with a payload and returns its decoded payload.
    static func ask<Payload: Decodable, Sent: Encodable>(
        _ method: Method,
        payload: Sent,
        as type: Payload.Type
    ) throws -> Payload {
        try resolved(envelope(of: try send(method, payload: payload), as: Payload.self))
    }

    /// Runs a status-only operation, checking the envelope for success.
    static func acknowledge(_ method: Method) throws {
        _ = try ask(method, as: EngineEnvelopeNoPayload.self)
    }

    /// Runs a status-only operation with a payload, checking the envelope.
    static func acknowledge<Sent: Encodable>(_ method: Method, payload: Sent) throws {
        _ = try ask(method, payload: payload, as: EngineEnvelopeNoPayload.self)
    }
}
