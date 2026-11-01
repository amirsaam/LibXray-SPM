import Foundation

// One-shot engine questions and lifecycle primitives on the shared instance.
// No validation needed here — these are direct readings and the launch/stop
// pair `Xray.Session` funnels into.

extension Xray {
    /// Xray-core version compiled into the framework, e.g. "26.10.29".
    public func version() throws -> String {
        try LifecycleCalls.version()
    }

    /// Whether an engine instance started earlier in this process is running.
    public func isRunning() throws -> Bool {
        try LifecycleCalls.isRunning()
    }

    /// Starts (or replaces) this process's engine instance with the given
    /// Xray JSON configuration. Blocks until the engine is up.
    public func launch(_ configuration: String) throws {
        try LifecycleCalls.launch(configuration)
    }

    /// Stops this process's running engine instance.
    public func stop() throws {
        try LifecycleCalls.stop()
    }

    /// Sends a raw request document to the engine and returns the raw
    /// response document. Throws `Xray.Error` on engine-reported failure.
    /// Strings returned by the engine are malloc'd; the transport releases
    /// them internally, so no cleanup is left for callers.
    public func sendRawRequest(_ request: String) throws -> String {
        try LifecycleCalls.rawRequest(request)
    }
}

// Liveness probe: the engine answers and an instance is up.
extension Xray {
    /// True when an engine instance is up and answering on the bridge: the
    /// state call proves the instance exists, the version round-trip proves
    /// the bridge is alive. False (not a throw) when nothing is running.
    /// Poll this from a watchdog; a throw means the bridge itself is wedged.
    public func health() throws -> Bool {
        guard try LifecycleCalls.isRunning() else { return false }
        _ = try LifecycleCalls.version()
        return true
    }
}
