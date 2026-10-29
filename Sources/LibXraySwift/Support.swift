import Foundation

/// A failure reported by the libXray engine (or by the bridge code itself).
public struct EngineError: Error, LocalizedError {
    /// What the engine said went wrong.
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

struct FreeJSON: Decodable {
    let value: Any

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let whole = try? container.decode(Int.self) {
            value = whole
        } else if let fraction = try? container.decode(Double.self) {
            value = fraction
        } else if let flag = try? container.decode(Bool.self) {
            value = flag
        } else if let text = try? container.decode(String.self) {
            value = text
        } else if let items = try? container.decode([FreeJSON].self) {
            value = items.map(\.value)
        } else if let fields = try? container.decode([String: FreeJSON].self) {
            value = fields.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "engine answered with a JSON value this type cannot represent"
            )
        }
    }
}

extension XrayBridge {
    /// Parses a free-form JSON payload out of an engine envelope. Used by
    /// operations whose answer is a whole document (config conversion) where
    /// no fixed Swift type would fit.
    static func unpackJSON(_ envelope: EngineEnvelope<FreeJSON>) throws -> Any {
        guard envelope.succeeded else {
            throw EngineError(envelope.failure ?? "engine failure with no message")
        }
        guard let payload = envelope.payload else {
            throw EngineError("engine reported success but answered without a payload")
        }
        return payload.value
    }

    /// Writes a parsed JSON tree back out as compact JSON text.
    static func serializeJSONText(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        let written = try? JSONSerialization.data(withJSONObject: value, options: [])
        return written.flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - Shared wire codecs
// Engine payload structs used by more than one feature file.

/// Wraps a plain `xrayJson` string, the shape engine status operations and
/// config round-trips read.
struct ConfigPayload: Encodable {
    let xrayJson: String
}
