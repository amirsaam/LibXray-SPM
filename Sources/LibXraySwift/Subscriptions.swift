import Foundation

// Subscription texts, proxy share links, and their two-way conversion into
// Xray configurations.

public extension XrayBridge {
    /// Decodes a subscription export. Subscription texts are usually base64
    /// blocks with one proxy link per line; this returns the readable link
    /// text. Optionally passes an Age secret key first, for exports that
    /// were encrypted with it.
    ///
    /// - Parameters:
    ///   - text: the raw subscription text as fetched from the feed
    ///   - ageSecret: Age secret key ("AGE-SECRET-KEY-...") when the feed
    ///     sent an encrypted export
    /// - Returns: the decoded proxy links, newline-separated
    static func decode(_ text: String, ageSecret: String? = nil) throws -> String {
        try ask(
            .decodeSubscription,
            payload: TextSnapshot(text: text, ageSecret: ageSecret),
            as: TextSnapshot.self
        ).text
    }

    /// Builds a full Xray configuration from proxy share links
    /// (vless://, vmess://, ss://, trojan://, hysteria2://, Age-encrypted
    /// exports, or a `{"outbounds":[...]}` JSON blob). Exports that mix valid
    /// and invalid entries are fine; entries the engine cannot build are
    /// dropped rather than failing the whole call, and an export where
    /// nothing survives raises `EngineError`.
    ///
    /// - Parameters:
    ///   - links: the share links or subscription text to parse
    ///   - ageSecret: Age secret key when the input is an encrypted export
    /// - Returns: a configuration over the surviving outbounds, ready for
    ///   `check()` or `launch()`
    static func fromShareLinks(_ links: String, ageSecret: String? = nil) throws -> XrayConfig {
        let envelope = try envelope(
            of: try send(.configFromShareLinks, payload: TextSnapshot(text: links, ageSecret: ageSecret)),
            as: FreeJSON.self
        )
        let value = try unpackJSON(envelope)
        guard let written = serializeJSONText(value) else {
            throw EngineError("engine answered with a document this bridge cannot serialize")
        }
        return XrayConfig(json: written)
    }

    /// Goes the other way: turns an Xray configuration back into proxy share
    /// links, newline-separated, one link per routable outbound.
    static func toShareLinks(_ configuration: String) throws -> String {
        try ask(
            .shareLinksFromConfig,
            payload: ConfigPayload(xrayJson: configuration),
            as: LinkList.self
        ).links
    }
}

// MARK: - Internal codecs

extension XrayBridge {
    struct TextSnapshot: Encodable, Decodable, Sendable {
        let text: String
        let age: AgeSecret?

        init(text: String, ageSecret: String?) {
            self.text = text
            self.age = ageSecret.map(AgeSecret.init)
        }

        enum CodingKeys: String, CodingKey {
            case text
            case age
        }
    }

    struct AgeSecret: Encodable, Decodable, Sendable {
        let secretKey: String

        init(secretKey: String) {
            self.secretKey = secretKey
        }
    }

    struct LinkList: Decodable {
        let links: String
    }
}
