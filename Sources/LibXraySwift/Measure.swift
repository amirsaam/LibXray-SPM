import Foundation

// Operating-system helpers and network measurements the engine offers:
// picking spare ports and measuring per-server latency.

public extension XrayBridge {
    /// Asks the operating system for TCP ports nothing else is listening on.
    /// Handy for the inbound `port` fields of configurations that listen
    /// locally, so every launch can sit on a fresh pocket instead of a
    /// hardcoded port.
    ///
    /// - Parameters:
    ///   - count: how many ports to reserve
    ///   - excluding: ports to skip even when unused
    /// - Returns: that many free TCP port numbers
    static func sparePorts(
        howMany count: Int = 1,
        excluding reserved: [Int] = []
    ) throws -> [Int] {
        try ask(
            .sparePorts,
            payload: PortRequest(count: count, excluding: reserved),
            as: PortList.self
        ).ports ?? []
    }

    /// Measures connect latency, opening one engine connection per target.
    /// Same idea as the native Xray apps: each measurement completes a full
    /// HTTP request through the outbound, so success covers routing and TLS
    /// handshakes, not just a bare TCP probe. Blocks until every request
    /// finishes or the deadline passes, so call from a background task.
    ///
    /// - Parameters:
    ///   - targets: one entry per server, each carrying its own Xray JSON
    ///     plus the tag of the outbound that should be requested through
    ///   - timeoutSeconds: whole-batch deadline
    ///   - testURL: the HTTP endpoint fetched through every outbound
    /// - Returns: answers in the same order as `targets`
    static func ping(
        targets: [ProxyPingTarget],
        timeoutSeconds: Int,
        testURL: String
    ) throws -> [PingAnswer] {
        try ask(
            .ping,
            payload: PingTaskPayload(
                configs: targets,
                timeout: timeoutSeconds,
                url: testURL
            ),
            as: PingAnswers.self
        ).outcomes ?? []
    }
}

// MARK: - Public types

public extension XrayBridge {
    /// One server to measure: its own compact Xray JSON plus the tag of the
    /// outbound inside it that should be requested through.
    ///
    /// ```swift
    /// ProxyPingTarget(
    ///     configuration: #"{"outbounds":[{"tag":"proxy","protocol":"vless",...}]}"#,
    ///     tag: "proxy"
    /// )
    /// ```
    struct ProxyPingTarget: Encodable, Sendable {
        public var configuration: String
        public var tag: String

        public init(configuration: String, tag: String) {
            self.configuration = configuration
            self.tag = tag
        }

        enum CodingKeys: String, CodingKey {
            case configuration = "xrayJson"
            case tag = "outboundTag"
        }
    }

    /// Measurement result for one target of `XrayBridge.ping`.
    struct PingAnswer: Decodable, Sendable {
        /// Whether a full request completed through the outbound inside the
        /// timeout.
        public let succeeded: Bool

        /// Milliseconds from request start to completion.
        public let milliseconds: Int

        /// The engine's failure note when `succeeded` is false.
        public let failureNote: String?

        enum CodingKeys: String, CodingKey {
            case succeeded = "success"
            case milliseconds = "delay"
            case failureNote = "error"
        }
    }
}

// MARK: - Internal codecs

extension XrayBridge {
    struct PortRequest: Encodable {
        let count: Int
        let excluding: [Int]?

        enum CodingKeys: String, CodingKey {
            case count
            case excluding = "excludePorts"
        }
    }

    struct PortList: Decodable {
        let ports: [Int]?
    }

    struct PingTaskPayload: Encodable {
        let configs: [ProxyPingTarget]
        let timeout: Int
        let url: String
    }

    struct PingAnswers: Decodable {
        let outcomes: [PingAnswer]?

        enum CodingKeys: String, CodingKey {
            case outcomes = "results"
        }
    }
}
