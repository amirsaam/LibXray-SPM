import Foundation

// Engine lifecycle: what version is inside, whether it is running, starting
// and stopping instances, and pre-flight config checks.

extension XrayBridge {
    /// Xray-core version compiled into the xcframework, e.g. "26.10.29".
    public static func engineVersion() throws -> String {
        try ask(.engineVersion, as: EngineVersion.self).version
    }

    /// Whether an engine instance launched earlier in this process is still
    /// running.
    public static func engineIsRunning() throws -> Bool {
        try ask(.engineState, as: EngineState.self).running
    }

    /// Starts (or replaces) this process's engine instance with the given
    /// Xray JSON configuration. Blocks until the engine is up, so call it
    /// from a background task from UI code.
    public static func launch(_ configuration: String) throws {
        try acknowledge(.launchEngine, payload: ConfigPayload(xrayJson: configuration))
    }

    /// Validates an Xray JSON configuration without starting anything.
    public static func check(_ configuration: String) throws {
        try acknowledge(.checkConfig, payload: ConfigPayload(xrayJson: configuration))
    }

    /// Stops this process's running engine instance. Safe when idle: the
    /// engine still answers with success.
    public static func shutDown() throws {
        try acknowledge(.stopEngine)
    }
}

extension XrayBridge {
    private struct EngineVersion: Decodable {
        let version: String
    }

    private struct EngineState: Decodable {
        let running: Bool
    }
}
