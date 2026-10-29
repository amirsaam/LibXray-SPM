import Foundation

// Key generation for encrypted feeds and inventory scans of GeoIP/GeoSite
// database files.

public extension XrayBridge {
    /// Generates a key pair for Age-encrypted subscription exports.
    ///
    /// - Parameter kind: `.x25519` for the classic pair, or `.hybrid` to add
    ///   post-quantum resistance on feeds that support it.
    static func newAgeKeys(kind: AgeKeyKind = .x25519) throws -> AgeKeyPair {
        try ask(.newAgeKeys, payload: AgeKindChoice(kind: kind), as: AgeKeyPair.self)
    }

    /// Writes a human-readable inventory of a GeoIP or GeoSite database file.
    /// The engine answers nothing beyond success or failure; the summary
    /// lands on disk next to the database, at
    /// `<folder>/<file>.<kind>.txt`, listing every code/region with its rule
    /// and category counts.
    ///
    /// - Parameters:
    ///   - folder: the directory holding the `.dat` files
    ///   - file: the database name without extension, e.g. "geosite" or "geoip"
    ///   - kind: what the database describes
    static func catalogGeoData(
        folder: String,
        file: String,
        kind: GeoDataKind
    ) throws {
        try acknowledge(
            .catalogGeoData,
            payload: GeoCatalogRequest(folder: folder, file: file, kind: kind)
        )
    }
}

// MARK: - Public types

public extension XrayBridge {
    /// Flavor of Age key pair. `hybrid` folds ML-KEM-768 over the classic
    /// X25519 exchange.
    enum AgeKeyKind: String, Encodable, Sendable {
        case x25519
        case hybrid
    }

    /// A fresh Age key pair: the secret stays on this device, the public
    /// half goes to whoever exports encrypted feeds for you.
    struct AgeKeyPair: Decodable, Sendable {
        /// Starts with "AGE-SECRET-KEY-"; keep it out of logs.
        public let secretKey: String

        /// Starts with "age1"; publishable.
        public let publicKey: String?

        enum CodingKeys: String, CodingKey {
            case secretKey
            case publicKey
        }
    }

    /// What a GeoIP/GeoSite database catalogues.
    enum GeoDataKind: String, Encodable, Sendable {
        /// Hostname databases, e.g. "geosite".
        case domains

        /// IP range databases, e.g. "geoip".
        case addresses
    }
}

// MARK: - Internal codecs

extension XrayBridge {
    struct AgeKindChoice: Encodable {
        let kind: AgeKeyKind

        enum CodingKeys: String, CodingKey {
            case kind = "keyType"
        }
    }

    struct GeoCatalogRequest: Encodable {
        let folder: String
        let file: String
        let kind: GeoDataKind

        /// Engine-side spellings: "domain" for geosite databases, "ip" for geoip ones.
        private var engineKind: String {
            switch kind {
            case .domains: return "domain"
            case .addresses: return "ip"
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(folder, forKey: .folder)
            try container.encode(file, forKey: .file)
            try container.encode(engineKind, forKey: .kind)
        }

        enum CodingKeys: String, CodingKey {
            case folder = "datDir"
            case file = "name"
            case kind = "geoType"
        }
    }
}
