import Foundation

/// A complete Xray configuration, either handed over as JSON text or parsed
/// out of proxy share links. It carries no state of its own; launching it
/// goes through `XrayBridge`, and every launch replaces the previous running
/// instance of this process.
///
/// ```swift
/// let config = try XrayBridge.fromShareLinks(myLinks)
/// try config.check()    // validate without starting
/// try config.launch()   // take over; background task recommended
/// ```
public struct XrayConfig {
    /// The configuration as JSON text, ready to hand to `launch` or `check`
    /// (or to `XrayBridge.launch` / `XrayBridge.check` directly, which take
    /// plain strings).
    public var json: String

    /// Builds a configuration from raw Xray JSON text. No validation happens
    /// here; call `check()` to have the engine confirm it parses and builds.
    public init(json: String) {
        self.json = json
    }

    /// Validates this configuration with the engine. Throws `EngineError`
    /// with the engine's own complaint if it will not build.
    public func check() throws {
        try XrayBridge.check(json)
    }

    /// Starts (or replaces) this process's engine instance with this
    /// configuration. Blocks, so call it from a background task when coming
    /// from UI code.
    public func launch() throws {
        try XrayBridge.launch(json)
    }

    /// Stops this process's running engine instance.
    public func shutDown() throws {
        try XrayBridge.shutDown()
    }
}
