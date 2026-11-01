import Foundation

// Friendly starting points on the shared instance: create the objects an app
// holds onto without spelling out their constructors or the engine pipeline
// underneath. Everything here returns before touching the engine except
// `validate`, which only checks.

extension Xray {
    /// A session to hold onto for the app's lifetime: it owns the launch
    /// lifecycle with an optional log sink.
    public func newSession(logger: ((String) -> Void)? = nil) -> Session {
        Session(logger: logger)
    }

    /// Builds a runnable configuration from JSON text or share links, with
    /// the session defaults applied — no session needed when all you want is
    /// the document (persist it, diff it, hand it over later).
    public func configuration(
        _ source: Config.Source,
        options: Session.Options? = nil
    ) throws -> Config {
        try Session().build(source, options: options ?? Session.Options())
    }

    /// Checks a source the way `start` would, without starting anything.
    /// Throws the engine's parser complaint, which is the cheapest way to
    /// reject bad user input.
    public func validate(
        _ source: Config.Source,
        options: Session.Options? = nil
    ) throws {
        try Session().validate(source, options: options ?? Session.Options())
    }

    /// Starts an assembly from a source: the one-call path from intent to a
    /// runnable document (conversion, entries, sections, patches applied).
    /// Tune the result through the returned assembly before calling
    /// `assemble()` on it.
    public func assembler(_ source: Config.Source) -> Assembly {
        Assembly(source: source)
    }

    /// Builds a runnable proxy document from a source in one call: conversion
    /// plus local inbounds and sections, no struct construction. A socks
    /// inbound on `socksPort` is included by default (matching the native
    /// apps); pass nil to leave it out, or a port for an HTTP inbound via
    /// `httpPort`. Anything fancier — TUN, observatory, patches — still goes
    /// through `assembler(_:)` or `Session().build`.
    public func proxyConfiguration(
        _ source: Config.Source,
        remarks: String? = nil,
        socksPort: Int? = 10808,
        httpPort: Int? = nil,
        routing: Xray.Routing? = nil,
        dns: Xray.DNS? = nil,
        log: Xray.Log? = nil
    ) throws -> Config {
        if let socksPort { try Self.validPort(socksPort, name: "socks") }
        if let httpPort { try Self.validPort(httpPort, name: "http") }
        var assembly = Assembly(source: source)
        assembly.remarks = remarks
        assembly.socks = socksPort.map { Assembly.SocksEntry(port: $0) }
        assembly.http = httpPort.map { Assembly.HttpEntry(port: $0) }
        assembly.routing = routing
        assembly.dns = dns
        assembly.log = log
        return try assembly.assemble()
    }
}

// Shared validation for factory-built values.
extension Xray {
    internal static func validPort(_ port: Int, name: String) throws {
        guard (1 ... 65_535).contains(port) else {
            throw Error.invalidInput("\(name) port must be 1-65535, got \(port)")
        }
    }
}
