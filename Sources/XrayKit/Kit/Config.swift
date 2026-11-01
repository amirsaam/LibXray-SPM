import Foundation

// A complete Xray configuration as it travels: JSON text you already have, or
// the output of share-link conversion. A pure value; running it belongs to
// `Xray.Session`, which is the single owner of engine side effects.

extension Xray {
    public struct Config: Sendable {
        /// The configuration as JSON text, ready to hand to a session (or to
        /// persist, log, or edit between calls).
        public var json: String

        /// Builds a configuration from raw Xray JSON text. No validation
        /// happens here; call `validate()` to have the engine confirm it
        /// parses and builds.
        internal init(json: String) {
            self.json = json
        }

        /// Builds a configuration from proxy share links (vless://, vmess://,
        /// ss://, trojan://, hysteria2://, Age-encrypted exports, or a
        /// `{"outbounds":[...]}` JSON blob). Entries the engine cannot build
        /// are dropped; if nothing survives, throws `Xray.Error`.
        internal init(shareLinks: String, ageSecret: String? = nil) throws {
            self.json = try ConfigCalls.convert(shareLinks: shareLinks, ageSecret: ageSecret)
        }

        /// Turns this configuration back into proxy share links,
        /// newline-separated, one link per routable outbound.
        public func shareLinks() throws -> String {
            try ConfigCalls.links(from: json)
        }

        /// Validates this configuration with the engine without starting
        /// anything. The thrown `Xray.Error` carries the engine's parser
        /// complaint, which is the cheapest way to reject bad user input.
        public func validate() throws {
            try ConfigCalls.check(json: json)
        }

        /// What a session can start from: JSON you already have, or share
        /// links that still need converting.
        public enum Source: Sendable {
            /// Complete Xray JSON configuration text.
            case json(String)

            /// Proxy share links; converted through the engine first.
            case shareLinks(String)
        }
    }

    /// Unwraps a provider's Age-encrypted subscription export: text
    /// starting with the Age armor header is decrypted with `ageSecret`,
    /// and any other text comes back unchanged. It does not parse links
    /// and does not base64-decode — the result (whatever it is) goes to
    /// `Config(shareLinks:ageSecret:)`, which accepts a single link, many
    /// newline-separated links, a base64 blob, or a
    /// `{"outbounds":[...]}` JSON blob.
    public func decodeSubscription(_ text: String, ageSecret: String? = nil) throws -> String {
        try ConfigCalls.decodeText(text, ageSecret: ageSecret)
    }
}
