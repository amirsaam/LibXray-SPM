import Foundation

// App-facing session over the engine: owns one launch lifecycle, assembles
// configurations from JSON or share links, and offers the hooks integrators
// always end up needing (inspect-before-run, last-minute tweaks, log sink).
// The static `Xray` API is the thin binding underneath; this is the layer a
// VPN app holds onto.

extension Xray {
    /// One launch lifecycle. Hold onto an instance for as long as its engine
    /// should live; stopping is explicit through `stop()`. Confine each
    /// session to a single serial context: the engine calls underneath are
    /// serialized, but interleaving two sessions' start/stop sequences from
    /// different threads is a logic race this type does not referee.
    ///
    /// ```swift
    /// let session = Xray.Session(logger: { print("[xray]", $0) })
    /// try session.start(.shareLinks(pastedText), options: .init(
    ///     sniffing: Xray.shared.sniffing(),
    ///     transform: { $0["log"] = ["loglevel": "warning"] }
    /// ))
    /// ```
    public final class Session: @unchecked Sendable {
        // Mutable state lives behind `stateLock`; the bridge calls underneath
        // are serialized by the transport lane. `@unchecked` is the honest
        // marking: `logger` runs on the caller's thread by design, so keep
        // each session on one serial context — interleaving two sessions'
        // start/stop sequences from different threads is a logic race no
        // lock can referee.
        private let stateLock = NSLock()
        private var _logger: ((String) -> Void)?
        private var _entries: [String] = []
        private var _connectedSince: Date?
        private var _accessLogPath: String?
        private var _errorLogPath: String?
        private static let stamp = ISO8601DateFormatter()

        /// Transport for feed fetches. `URLSession.shared` in production;
        /// tests swap in a stubbed configuration. Set before use.
        internal var urlSession: URLSession = .shared

        /// Receives lifecycle notes: what is launching, the byte count of the
        /// final JSON, engine answers. Set at init or any time after. Every
        /// note is also kept in the `recentLogs` ring buffer.
        public var logger: ((String) -> Void)? {
            get { stateLock.withLock { _logger } }
            set { stateLock.withLock { _logger = newValue } }
        }

        /// When the running instance came up, if one did. Nil before the
        /// first start and after every stop. The engine exposes no clock of
        /// its own, so this stamp is the uptime anchor — pair it with traffic
        /// totals, which reset on every launch.
        public var connectedSince: Date? {
            stateLock.withLock { _connectedSince }
        }

        internal init(logger: ((String) -> Void)? = nil) {
            self._logger = logger
        }

        // MARK: - Launch options

        /// Knobs for `build` and `start`. Everything defaults to plain proxy
        /// mode, so `session.start(.json(text))` behaves exactly as before.
        public struct Options {
            /// Sniffing injected into inbounds that lack their own settings.
            public var sniffing: Xray.Sniffing?

            /// Last-minute document patch, applied after everything else.
            public var transform: ((inout Xray.JSONObject) -> Void)?

            /// A complete routing section, written verbatim. Replaces any
            /// routing section already in the document.
            public var routing: Xray.Routing?

            /// Username + password guarding the local SOCKS entry points.
            /// Only SOCKS inbounds are touched; other inbound types pass
            /// through unchanged.
            public var credentials: Xray.Credentials?

            /// Device-wide capture through the engine's own TUN inbound (see
            /// `Xray.TunEntry` and the TUN section in the README). Assembling
            /// appends a `protocol: tun` inbound and, when the entry carries
            /// a file descriptor, merges `xray.tun.fd` into the document's
            /// `env`. Nil means proxy mode: no TUN inbound, no `env` key.
            /// Launch the result where the interface lives — inside the
            /// NetworkExtension on iOS, in the app on macOS.
            public var tun: TunEntry?

            /// Extra document environment entries, merged into `env` before
            /// the TUN descriptor is applied. The engine turns `env` into
            /// its own process environment at launch — the documented carrier
            /// for `xray.location.asset` (geo database lookup directory),
            /// `xray.location.cert`, and similar engine settings. Keys here
            /// never overwrite ones already in the document.
            public var environment: [String: String]?

            /// Per-outbound health probing: writes the `observatory` section
            /// the engine needs, and feeds `TrafficSnapshot.observatory` when
            /// `metricsPort` is also set. The engine probes every outbound
            /// whose tag matches a `subjectSelector` prefix through the
            /// network, so a short interval costs live requests. Nil means
            /// no probing.
            public var observatory: Observatory?

            /// Whether assembling checks that geo databases referenced by the
            /// routing (`geosite:`) or dns (`geosite:` / `geoip:`) sections
            /// actually exist next to the engine, before anything launches.
            /// The engine only complains at traffic time otherwise. Rules
            /// naming plain domains or IPs never trigger it. Default true.
            public var geoCheck: Bool

            /// A dns section, written verbatim. Replaces any dns section
            /// already in the document.
            public var dns: Xray.DNS?

            /// FakeDNS pools, written verbatim as the `fakedns` array.
            /// Replaces any fakedns section already in the document.
            public var fakeDNS: [Xray.FakeDNS]?

            /// A log section, written verbatim. Replaces any log section
            /// already in the document.
            public var log: Xray.Log?

            /// Metrics endpoint port. When set, the build adds a Metrics
            /// listener on 127.0.0.1:`metricsPort`, an empty `stats` section,
            /// and the four `policy.system` stats switches — everything
            /// `TrafficMonitor` needs to read live counters. Replaces any
            /// metrics section already in the document; existing policy keys
            /// are kept, the stats switches are turned on alongside them.
            public var metricsPort: Int?

            internal init(
                sniffing: Xray.Sniffing? = nil,
                transform: ((inout Xray.JSONObject) -> Void)? = nil,
                routing: Xray.Routing? = nil,
                credentials: Xray.Credentials? = nil,
                tun: TunEntry? = nil,
                environment: [String: String]? = nil,
                observatory: Observatory? = nil,
                geoCheck: Bool = true,
                dns: Xray.DNS? = nil,
                fakeDNS: [Xray.FakeDNS]? = nil,
                log: Xray.Log? = nil,
                metricsPort: Int? = nil
            ) {
                self.sniffing = sniffing
                self.transform = transform
                self.routing = routing
                self.credentials = credentials
                self.tun = tun
                self.environment = environment
                self.observatory = observatory
                self.geoCheck = geoCheck
                self.dns = dns
                self.fakeDNS = fakeDNS
                self.log = log
                self.metricsPort = metricsPort
            }
        }

        // MARK: - Assembly (no launch)

        /// Assembles everything `start` would launch: conversion, environment,
        /// the tun inbound when set, the observatory section when set,
        /// sniffing, dns, fakedns, log, metrics, routing, credentials, then
        /// `transform` last so it can overrule anything, and finally the geo
        /// asset check. Use the result to inspect, persist, or diff
        /// before committing to a launch.
        ///
        /// The transform works on a typed tree (`Xray.JSONObject`), so there
        /// is nothing to cast:
        ///
        /// ```swift
        /// try session.build(.shareLinks(text), options: .init(
        ///     routing: Xray.Routing(
        ///         rules: [.init(domains: ["googleadservices.com"],
        ///                        destination: .proxy)],
        ///         final: .direct
        ///     )
        /// ))
        /// ```
        public func build(
            _ source: Config.Source,
            options: Options? = nil
        ) throws -> Config {
            let options = options ?? Options()
            let json: String
            switch source {
            case .json(let text):
                json = text
            case .shareLinks(let links):
                json = try Config(shareLinks: links).json
            }
            let decoded: JSONValue
            do {
                decoded = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            } catch {
                throw Error.invalidInput("configuration is not valid JSON")
            }
            guard case .object(var dict) = decoded else {
                throw Error.invalidInput("configuration is not a JSON object")
            }
            if let environment = options.environment {
                var env = dict["env"]?.objectValue ?? [:]
                for (key, value) in environment where env[key] == nil {
                    env[key] = .string(value)
                }
                dict["env"] = .object(env)
            }
            if let tun = options.tun {
                var inbounds = dict["inbounds"]?.arrayValue ?? []
                inbounds.append(.object(tun.wireObject))
                dict["inbounds"] = .array(inbounds)
                tun.applyEnvironment(to: &dict)
            }
            if options.observatory != nil && options.metricsPort == nil {
                throw Error.invalidInput(
                    "observatory is set but metricsPort is nil: probe answers are published on the metrics endpoint, so set metricsPort to read them"
                )
            }
            if let observatory = options.observatory {
                dict["observatory"] = .object(observatory.wireObject)
            }
            options.sniffing?.inject(into: &dict)
            if let dns = options.dns {
                dict["dns"] = .object(dns.wireObject)
            }
            if let fakeDNS = options.fakeDNS {
                dict["fakedns"] = .array(fakeDNS.map { .object($0.wireObject) })
            }
            if let log = options.log {
                dict["log"] = .object(log.wireObject)
            }
            if let metricsPort = options.metricsPort {
                guard (1 ... 65_535).contains(metricsPort) else {
                    throw Error.invalidInput("metrics port \(metricsPort) is outside 1...65535")
                }
                dict["metrics"] = .object(Xray.Metrics(port: metricsPort).wireObject)
                if dict["stats"] == nil {
                    dict["stats"] = .object([:])
                }
                var policy = dict["policy"]?.objectValue ?? [:]
                var system = policy["system"]?.objectValue ?? [:]
                system["statsInboundUplink"] = .bool(true)
                system["statsInboundDownlink"] = .bool(true)
                system["statsOutboundUplink"] = .bool(true)
                system["statsOutboundDownlink"] = .bool(true)
                policy["system"] = .object(system)
                dict["policy"] = .object(policy)
            }
            if let routing = options.routing {
                let proxyTag: String
                if routing.needsProxy {
                    guard let resolved = Self.ensureProxyTag(in: &dict) else {
                        throw Error.invalidInput("routing sends traffic to the proxy but the document has no outbounds")
                    }
                    proxyTag = resolved
                } else {
                    proxyTag = Self.firstOutboundTag(in: dict) ?? "proxy"
                }
                dict["routing"] = .object(routing.wireObject(proxyTag: proxyTag))
            }
            try Self.applyCredentials(options.credentials, to: &dict)
            options.transform?(&dict)
            Self.ensureStandardOutbounds(in: &dict)
            if options.geoCheck {
                try Self.checkGeoAssets(in: dict)
            }
            let text = try EngineTransport.serialize(.object(dict))
            recordLogPaths(from: dict)
            log("assembled configuration (\(text.count) bytes)")
            return Config(json: text)
        }

        // MARK: - Launch

        /// Builds from `source` with `options` and launches the engine with
        /// the result. Blocks until the engine is up.
        public func start(
            _ source: Config.Source,
            options: Options? = nil
        ) throws {
            try start(try build(source, options: options))
        }

        /// Launches an assembled configuration. Blocks until the engine is
        /// up, so prefer a background task (or the async variant) from UI code.
        /// Starting again while an instance runs replaces it.
        public func start(_ config: Config) throws {
            log("launching engine (\(config.json.count) bytes of configuration)")
            try LifecycleCalls.launch(config.json)
            markLaunched()
            log("engine launched")
        }

        /// Launches JSON text exactly as given: no conversion, no sniffing,
        /// no transform. For fully pre-built configs you control end to end.
        /// The log section's file paths are still recorded, so
        /// `recentEngineLogs` works the same as for built documents.
        public func start(rawJSON json: String) throws {
            log("launching engine from raw JSON (\(json.count) bytes)")
            if let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
               case .object(let dict) = decoded {
                recordLogPaths(from: dict)
            }
            try LifecycleCalls.launch(json)
            markLaunched()
            log("engine launched")
        }

        /// Reads a JSON file and launches it exactly as written.
        public func start(contentsOf url: URL) throws {
            let json: String
            do {
                json = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw Error.bridgeFailed("could not read config file: \(error.localizedDescription)")
            }
            try start(rawJSON: json)
        }

        /// Assembles with `options` and validates the result, so you check
        /// exactly what would launch.
        public func validate(
            _ source: Config.Source,
            options: Options? = nil
        ) throws {
            try build(source, options: options).validate()
        }

        /// Stops this process's running engine instance. Safe when idle: the
        /// engine still answers with success.
        public func stop() throws {
            log("stopping engine")
            try LifecycleCalls.stop()
            markStopped()
            log("engine stopped")
        }

        /// Whether an engine instance started earlier in this process is
        /// running.
        public func isRunning() throws -> Bool {
            return try LifecycleCalls.isRunning()
        }

        // MARK: - Async conveniences

        /// Assembles off the calling thread with `options`, then launches
        /// without blocking it. Logging still runs on the caller's executor
        /// around the handoff.
        public func start(
            _ source: Config.Source,
            options: Options? = nil
        ) async throws {
            let config = try build(source, options: options)
            log("launching engine (\(config.json.count) bytes of configuration)")
            let json = config.json
            try await Task.detached { try LifecycleCalls.launch(json) }.value
            markLaunched()
            log("engine launched")
        }

        /// Starts a source like `start(_:options:)`, but gives up if the
        /// engine is not up within `deadline` and stops the half-started
        /// instance before throwing. Use from providers, where the system
        /// kills a start that overstays its time budget — a thrown error is
        /// recoverable, a watchdog kill is not.
        public func start(
            _ source: Config.Source,
            options: Options? = nil,
            deadline: Duration
        ) async throws {
            let config = try build(source, options: options)
            log("launching engine (\(config.json.count) bytes of configuration)")
            let json = config.json
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: deadline)
                    throw Error.invalidInput(
                        "engine start exceeded its deadline and was stopped; check geo assets and listener ports"
                    )
                }
                group.addTask {
                    try await Task.detached { try LifecycleCalls.launch(json) }.value
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    try? self.stop()
                    throw error
                }
            }
            markLaunched()
            log("engine launched")
        }

        /// Assembles on the caller, then validates the result without
        /// blocking it. Only the engine check runs detached, so the
        /// non-Sendable transform never crosses threads.
        public func validate(
            _ source: Config.Source,
            options: Options? = nil
        ) async throws {
            let config = try build(source, options: options)
            let json = config.json
            try await Task.detached { try Xray.Config(json: json).validate() }.value
        }

        /// Provider sanity check over an assembled document: every inbound
        /// must listen on loopback (an extension cannot bind public
        /// addresses) and a `tun` inbound must exist (a packet tunnel with
        /// nothing to pump packets through launches a proxy, not a tunnel).
        /// Throws one `.invalidInput` listing every problem found, so a
        /// single run surfaces the whole list. Runs `build` first, so the
        /// geo gate and every other assembly rule apply. For UI, prefer
        /// `preflightIssues`, which returns the same problems as values.
        public func preflightForProvider(
            _ source: Config.Source,
            options: Options? = nil
        ) throws {
            let problems = try preflightIssues(source, options: options)
            if !problems.isEmpty {
                throw Error.invalidInput("provider preflight: " + problems.joined(separator: "; "))
            }
        }

        /// The same check as `preflightForProvider`, returned instead of
        /// thrown: an empty array means the document is provider-ready.
        /// Render each string next to its fix instead of parsing an error.
        public func preflightIssues(
            _ source: Config.Source,
            options: Options? = nil
        ) throws -> [String] {
            let config = try build(source, options: options)
            guard let document = try? JSONDecoder().decode(JSONValue.self, from: Data(config.json.utf8)),
                  let object = document.objectValue else {
                throw Error.invalidInput("provider preflight could not parse the assembled document")
            }
            var problems: [String] = []
            var sawTun = false
            if case .array(let inbounds) = object["inbounds"] {
                for inbound in inbounds {
                    guard let entry = inbound.objectValue else { continue }
                    if entry["protocol"]?.stringValue == "tun" { sawTun = true }
                    if let listen = entry["listen"]?.stringValue,
                       !["127.0.0.1", "localhost", "::1"].contains(listen) {
                        problems.append(
                            "inbound '\(entry["tag"]?.stringValue ?? "?")' listens on \(listen): extensions can only bind loopback"
                        )
                    }
                }
            }
            if !sawTun {
                problems.append("no tun inbound: a packet tunnel with nothing to pump packets through launches a proxy, not a tunnel")
            }
            return problems
        }

        /// Fetches a subscription feed, unwraps it, tops up geo assets, and
        /// launches — the whole provider start in one call. The feed is
        /// fetched fresh every call: nothing is cached, nothing
        /// auto-refreshes. `http(s)` requires status 200; anything else
        /// (including `file:` URLs, handy for tests and bundled feeds) is
        /// accepted as-is. When `assetDirectory` is given it becomes
        /// `xray.location.asset` unless the options already set one, missing
        /// referenced databases are fetched into it, and the launch then runs
        /// under `deadline` like `start(_:options:deadline:)`. Feeds are capped
        /// at the engine's own request limit (`timeoutSeconds` bounds the
        /// wait): a declared or actual body past it throws before anything
        /// is decoded, so a hostile feed can't park memory. Note the scan
        /// build runs `transform` twice when assets are topped up — keep
        /// transforms idempotent.
        public func start(
            remoteSubscription url: URL,
            ageSecret: String? = nil,
            assetDirectory: URL? = nil,
            options: Options? = nil,
            deadline: Duration = .seconds(30),
            timeoutSeconds: TimeInterval = 30
        ) async throws {
            log("fetching subscription from \(url.host ?? url.path)")
            let text: String
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = timeoutSeconds
                let (data, response) = try await urlSession.data(for: request)
                if let http = response as? HTTPURLResponse {
                    guard http.statusCode == 200 else {
                        throw Error.bridgeFailed("subscription fetch returned HTTP \(http.statusCode)")
                    }
                    if http.expectedContentLength > Int64(EngineTransport.maxRequestBytes) {
                        throw Error.invalidInput(
                            "subscription feed declares \(http.expectedContentLength) bytes, past the \(EngineTransport.maxRequestBytes)-byte cap"
                        )
                    }
                }
                guard data.count <= EngineTransport.maxRequestBytes else {
                    throw Error.invalidInput(
                        "subscription feed is \(data.count) bytes, past the \(EngineTransport.maxRequestBytes)-byte cap"
                    )
                }
                guard let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else {
                    throw Error.invalidInput("subscription at \(url) is empty or not text")
                }
                text = decoded
            } catch let error as Xray.Error {
                throw error
            } catch {
                throw Error.bridgeFailed("could not fetch subscription: \(error.localizedDescription)")
            }
            let unwrapped = try Xray.shared.decodeSubscription(text, ageSecret: ageSecret)
            var resolved = options ?? Xray.shared.options()
            if let assetDirectory {
                var env = resolved.environment ?? [:]
                if env["xray.location.asset"] == nil {
                    env["xray.location.asset"] = assetDirectory.path
                }
                resolved.environment = env
                var scan = resolved
                scan.geoCheck = false
                let scanned = try build(.shareLinks(unwrapped), options: scan)
                _ = try await Xray.shared.ensureAssets(for: scanned, in: assetDirectory)
            }
            try await start(.shareLinks(unwrapped), options: resolved, deadline: deadline)
        }

        // MARK: - Private

        /// Fail-fast geo database check over the final, post-transform
        /// document: what the routing and dns sections reference must exist
        /// wherever the engine will look for it. The document's `env` counts
        /// first, so an asset path shipped in it overrides the defaults.
        private static func checkGeoAssets(in config: JSONObject) throws {
            try Xray.GeoAssets.check(
                referenced: Xray.GeoAssets.referenced(in: config),
                env: config["env"]?.objectValue
            )
        }

        /// Guards every SOCKS inbound with the username + password. Other
        /// inbound types (HTTP, dokodemo-door, TUN) pass through untouched.
        /// A configuration with no SOCKS inbound is rejected as
        /// misconfiguration.
        private static func applyCredentials(
            _ credentials: Xray.Credentials?,
            to config: inout JSONObject
        ) throws {
            guard let credentials else { return }
            guard case .array(var inbounds) = config["inbounds"] else {
                throw Error.invalidInput("credentials need a SOCKS inbound to protect, and this configuration has no inbounds")
            }
            var guarded = false
            for index in inbounds.indices {
                if case .object(var inbound) = inbounds[index], inbound["protocol"] == .string("socks") {
                    Self.guardSocksInbound(&inbound, using: credentials)
                    inbounds[index] = .object(inbound)
                    guarded = true
                }
            }
            if !guarded {
                throw Error.invalidInput("credentials need a SOCKS inbound to protect, and this configuration has none")
            }
            config["inbounds"] = .array(inbounds)
        }

        /// Guards one SOCKS inbound object with a username + password.
        private static func guardSocksInbound(_ inbound: inout JSONObject, using credentials: Credentials) {
            var settings = inbound["settings"]?.objectValue ?? [:]
            settings["auth"] = .string("password")
            settings["users"] = .array([.object([
                "user": .string(credentials.username),
                "pass": .string(credentials.password),
            ])])
            inbound["settings"] = .object(settings)
        }

        /// Returns the first outbound's tag, assigning `"proxy"` when it has
        /// none. Returns nil when the document has no outbounds at all.
        private static func ensureProxyTag(in config: inout JSONObject) -> String? {
            guard case .array(var outbounds) = config["outbounds"], !outbounds.isEmpty else { return nil }
            guard case .object(var first) = outbounds[0] else { return nil }
            if case .string(let tag) = first["tag"] { return tag }
            first["tag"] = .string("proxy")
            outbounds[0] = .object(first)
            config["outbounds"] = .array(outbounds)
            return "proxy"
        }

        /// The first outbound's tag, if any.
        private static func firstOutboundTag(in config: JSONObject) -> String? {
            guard case .array(let outbounds) = config["outbounds"],
                  case .object(let first) = outbounds.first,
                  case .string(let tag) = first["tag"] else { return nil }
            return tag
        }

        /// Appends the standard `direct` (freedom), `block` (blackhole), and
        /// `dns-out` (dns) outbounds when the routing section references
        /// them but the document does not define them.
        private static func ensureStandardOutbounds(in config: inout JSONObject) {
            guard case .object(let routing) = config["routing"],
                  case .array(let rules) = routing["rules"] else { return }
            var referenced: Set<String> = []
            for rule in rules {
                if case .object(let entry) = rule,
                   case .string(let tag) = entry["outboundTag"] {
                    referenced.insert(tag)
                }
            }
            if case .string(let final) = routing["final"] {
                referenced.insert(final)
            }
            let standards = [("direct", "freedom"), ("block", "blackhole"), ("dns-out", "dns")]
            var outbounds = config["outbounds"]?.arrayValue ?? []
            let before = outbounds.count
            for (tag, proto) in standards where referenced.contains(tag) {
                let exists = outbounds.contains {
                    if case .object(let entry) = $0, entry["tag"] == .string(tag) { return true }
                    return false
                }
                if !exists {
                    outbounds.append(.object(["protocol": .string(proto), "tag": .string(tag)]))
                }
            }
            if outbounds.count != before {
                config["outbounds"] = .array(outbounds)
            }
        }

        private func log(_ message: String) {
            let sink: ((String) -> Void)? = stateLock.withLock {
                _entries.append("\(Self.stamp.string(from: Date())) \(message)")
                if _entries.count > 200 {
                    _entries.removeFirst(_entries.count - 200)
                }
                return _logger
            }
            sink?(message)
        }

        /// The last lifecycle notes this session recorded, oldest first,
        /// capped at 200 entries: launches, byte counts, failures. A flight
        /// recorder for the package side — what it did, not what the engine
        /// saw. For engine output, see `recentEngineLogs`.
        public func recentLogs(limit: Int = 200) -> [String] {
            stateLock.withLock { Array(_entries.suffix(max(0, limit))) }
        }

        /// Which engine-written log file to tail (see `recentEngineLogs`).
        public enum EngineLogKind {
            case access
            case error
        }

        /// Tails the engine's own log file named by the last assembled
        /// document: the `access` / `error` paths in its log section. The
        /// engine only writes when the document points it at files, so a
        /// stdout, `none`, or missing path throws `.invalidInput` naming the
        /// fix. Reads at most the trailing 256 KiB, so a verbose access log
        /// can't blow up the caller. The bridge exposes no log stream, so
        /// this is file tailing — the only engine output there is.
        public func recentEngineLogs(_ kind: EngineLogKind = .error, lines: Int = 100) throws -> [String] {
            let path: String? = stateLock.withLock {
                switch kind {
                case .access: return _accessLogPath
                case .error: return _errorLogPath
                }
            }
            guard let path else {
                throw Error.invalidInput(
                    "no \(kind) log file recorded: point the document's log section at a file path to capture engine output"
                )
            }
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                let window: UInt64 = 262_144
                try handle.seek(toOffset: size > window ? size - window : 0)
                guard let data = try handle.readToEnd(), !data.isEmpty else { return [] }
                var text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                if size > window, let first = text.firstIndex(of: "\n") {
                    text.removeSubrange(...first)
                }
                var tail = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if tail.last?.isEmpty == true {
                    tail.removeLast()
                }
                return Array(tail.suffix(max(0, lines)))
            } catch {
                throw Error.bridgeFailed("could not read engine log at \(path): \(error.localizedDescription)")
            }
        }

        private func recordLogPaths(from dict: JSONObject) {
            let section = dict["log"]?.objectValue
            stateLock.withLock {
                _accessLogPath = Self.filePath(section?["access"]?.stringValue)
                _errorLogPath = Self.filePath(section?["error"]?.stringValue)
            }
        }

        private static func filePath(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value != "none", value != "stdout" else { return nil }
            return value
        }

        private func markLaunched() {
            stateLock.withLock { _connectedSince = Date() }
        }

        private func markStopped() {
            stateLock.withLock {
                _connectedSince = nil
                _accessLogPath = nil
                _errorLogPath = nil
            }
        }
    }

    // MARK: - Traffic control

    /// Username + password guarding the local entry points. Applied to every
    /// SOCKS inbound in the assembled configuration (`auth: "password"`
    /// with the pair in `users`); other inbound types are untouched.
    public struct Credentials: Sendable {
        public var username: String
        public var password: String

        internal init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    // MARK: - Sniffing

    /// Traffic-sniffing settings injected into a configuration's inbounds
    /// before launch. Applied per inbound: inbounds that already carry their
    /// own `sniffing` object keep it, every other inbound receives this one.
    public struct Sniffing: Codable, Sendable {
        /// Destination protocols to sniff (e.g. "http", "tls", "quic", "fakedns").
        public var destOverride: [String]

        /// Whether sniffing is on.
        public var enabled: Bool

        /// Whether to route only sniffed traffic.
        public var routeOnly: Bool

        /// Domains to leave alone.
        public var domainsExcluded: [String]

        /// Whether to extract metadata without touching payloads.
        public var metadataOnly: Bool

        internal init(
            destOverride: [String] = ["http", "tls", "quic", "fakedns"],
            enabled: Bool = true,
            routeOnly: Bool = false,
            domainsExcluded: [String] = [],
            metadataOnly: Bool = false
        ) {
            self.destOverride = destOverride
            self.enabled = enabled
            self.routeOnly = routeOnly
            self.domainsExcluded = domainsExcluded
            self.metadataOnly = metadataOnly
        }

        /// The object as the engine expects it inside an inbound.
        var wireObject: [String: JSONValue] {
            [
                "destOverride": .array(destOverride.map(JSONValue.string)),
                "enabled": .bool(enabled),
                "routeOnly": .bool(routeOnly),
                "metadataOnly": .bool(metadataOnly),
                "domainsExcluded": .array(domainsExcluded.map(JSONValue.string)),
            ]
        }

        /// Merges these settings into every inbound of a parsed configuration
        /// dictionary that does not already define `sniffing`.
        func inject(into config: inout JSONObject) {
            guard case .array(var inbounds) = config["inbounds"] else { return }
            for index in inbounds.indices {
                if case .object(var inbound) = inbounds[index], inbound["sniffing"] == nil {
                    inbound["sniffing"] = .object(wireObject)
                    inbounds[index] = .object(inbound)
                }
            }
            config["inbounds"] = .array(inbounds)
        }
    }
}

// Value factories for session credentials, sniffing, and the full options
// bag. `start`/`build` still take `Options`; this only changes how one is
// made.
extension Xray {
    public func credentials(username: String, password: String) -> Credentials {
        Credentials(username: username, password: password)
    }

    public func sniffing(
        destOverride: [String] = ["http", "tls", "quic", "fakedns"],
        enabled: Bool = true,
        routeOnly: Bool = false,
        domainsExcluded: [String] = [],
        metadataOnly: Bool = false
    ) -> Sniffing {
        Sniffing(
            destOverride: destOverride, enabled: enabled, routeOnly: routeOnly,
            domainsExcluded: domainsExcluded, metadataOnly: metadataOnly
        )
    }

    public func options(
        sniffing: Xray.Sniffing? = nil,
        transform: ((inout Xray.JSONObject) -> Void)? = nil,
        routing: Xray.Routing? = nil,
        credentials: Xray.Credentials? = nil,
        tun: TunEntry? = nil,
        environment: [String: String]? = nil,
        observatory: Observatory? = nil,
        geoCheck: Bool = true,
        dns: Xray.DNS? = nil,
        fakeDNS: [Xray.FakeDNS]? = nil,
        log: Xray.Log? = nil,
        metricsPort: Int? = nil
    ) -> Session.Options {
        Session.Options(
            sniffing: sniffing, transform: transform, routing: routing,
            credentials: credentials, tun: tun, environment: environment,
            observatory: observatory, geoCheck: geoCheck, dns: dns,
            fakeDNS: fakeDNS, log: log, metricsPort: metricsPort
        )
    }
}
