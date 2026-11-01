import Foundation

// Device-wide capture through the engine's own TUN inbound — the documented
// shape the published Xray clients run, not a pump around a SOCKS port.
// The engine reads packets off a TUN interface: on macOS it creates the
// interface itself from `name`, while on iOS/Android the interface belongs
// to the app or its NetworkExtension, so the provider passes its file
// descriptor through `fileDescriptor` (written into the document's `env`
// as `xray.tun.fd`, the variable Xray-core reads). There is no port and no
// auth on a TUN entry: traffic arrives as packets, not connections.

extension Xray {
    public struct TunEntry: Sendable {
        /// Inbound tag routing rules match on. Defaults to "tunIn".
        public var tag: String

        /// Interface address the entry binds. Defaults to 127.0.0.1.
        public var listen: String

        /// Interface name the engine creates (e.g. "utun10"). Nil leaves the
        /// engine's default. Only used when the engine creates the interface
        /// itself (macOS); ignored when a descriptor is passed in.
        public var name: String?

        /// Interface MTU. Defaults to 1500.
        public var mtu: Int

        /// Address prefixes assigned to the interface, e.g.
        /// ["198.18.0.1/15", "fc00::1/64"]. On macOS only IPv4 takes effect.
        /// Nil leaves interface addressing to the platform.
        public var gateway: [String]?

        /// Policy level for connections through this entry. Nil means 0.
        public var userLevel: Int?

        /// Destination prefixes the engine adds to the system routing table
        /// itself, e.g. ["0.0.0.0/0", "::/0"]. Nil means you route manually.
        public var autoSystemRoutingTable: [String]?

        /// Physical interface Xray's own traffic binds to, so it never loops
        /// back into the tunnel. "auto" lets the engine choose — and when
        /// `autoSystemRoutingTable` is set but this is nil, the engine
        /// already treats it as "auto".
        public var autoOutboundsInterface: String?

        /// The TUN file descriptor from the app or NetworkExtension that owns
        /// the interface (iOS/Android). Written into the document's `env` as
        /// `xray.tun.fd`. Nil means the engine creates the interface itself
        /// (the macOS path) — no descriptor needed.
        public var fileDescriptor: Int32?

        /// Carried verbatim; nil entries still receive the assembly's
        /// sniffing through the normal pipeline.
        public var sniffing: Xray.Sniffing?

        internal init(
            tag: String = "tunIn",
            listen: String = "127.0.0.1",
            name: String? = nil,
            mtu: Int = 1500,
            gateway: [String]? = nil,
            userLevel: Int? = nil,
            autoSystemRoutingTable: [String]? = nil,
            autoOutboundsInterface: String? = nil,
            fileDescriptor: Int32? = nil,
            sniffing: Xray.Sniffing? = Xray.Sniffing()
        ) {
            self.tag = tag
            self.listen = listen
            self.name = name
            self.mtu = mtu
            self.gateway = gateway
            self.userLevel = userLevel
            self.autoSystemRoutingTable = autoSystemRoutingTable
            self.autoOutboundsInterface = autoOutboundsInterface
            self.fileDescriptor = fileDescriptor
            self.sniffing = sniffing
        }

        var wireObject: JSONObject {
            var settings: JSONObject = ["mtu": .int(mtu)]
            if let name {
                settings["name"] = .string(name)
            }
            if let gateway {
                settings["gateway"] = .array(gateway.map(JSONValue.string))
            }
            if let userLevel {
                settings["userLevel"] = .int(userLevel)
            }
            if let autoSystemRoutingTable {
                settings["autoSystemRoutingTable"] = .array(autoSystemRoutingTable.map(JSONValue.string))
            }
            if let autoOutboundsInterface {
                settings["autoOutboundsInterface"] = .string(autoOutboundsInterface)
            }
            var entry: JSONObject = [
                "tag": .string(tag),
                "protocol": .string("tun"),
                "listen": .string(listen),
                "settings": .object(settings),
            ]
            if let sniffing {
                entry["sniffing"] = .object(sniffing.wireObject)
            }
            return entry
        }

        /// Keeps the launch environment faithful to this entry. With a
        /// descriptor, the fd is merged into the document's `env` as
        /// `xray.tun.fd`, preserving keys already there. Without one, any fd
        /// left in the process environment by an earlier TUN session is
        /// cleared: the engine applies document `env` entries into its own
        /// process at start and never unsets them, so a stale descriptor
        /// would hijack the next fd-less launch and make it read a dead fd
        /// instead of creating its own interface.
        func applyEnvironment(to config: inout JSONObject) {
            if let fileDescriptor {
                var env = config["env"]?.objectValue ?? [:]
                env["xray.tun.fd"] = .string("\(fileDescriptor)")
                config["env"] = .object(env)
            } else {
                Self.clearStaleFileDescriptor()
            }
        }

        /// Both spellings the engine's environment lookup accepts.
        static func clearStaleFileDescriptor() {
            unsetenv("xray.tun.fd")
            unsetenv("XRAY_TUN_FD")
        }
    }
}

// Value factory for the TUN entry. A negative file descriptor is rejected
// here instead of failing obscurely inside the engine.
extension Xray {
    public func tun(
        tag: String = "tunIn",
        listen: String = "127.0.0.1",
        name: String? = nil,
        mtu: Int = 1500,
        gateway: [String]? = nil,
        userLevel: Int? = nil,
        autoSystemRoutingTable: [String]? = nil,
        autoOutboundsInterface: String? = nil,
        fileDescriptor: Int32? = nil,
        sniffing: Xray.Sniffing? = nil
    ) throws -> TunEntry {
        if let fileDescriptor, fileDescriptor < 0 {
            throw Error.invalidInput("tun fileDescriptor must be non-negative, got \(fileDescriptor)")
        }
        return TunEntry(
            tag: tag, listen: listen, name: name, mtu: mtu, gateway: gateway,
            userLevel: userLevel, autoSystemRoutingTable: autoSystemRoutingTable,
            autoOutboundsInterface: autoOutboundsInterface,
            fileDescriptor: fileDescriptor, sniffing: sniffing ?? Xray.Sniffing()
        )
    }
}

// The provider's utun descriptor, read off the packet flow.
extension Xray {
    /// Reads the file descriptor of the utun interface backing a packet
    /// tunnel provider's flow, for handing to `tun(fileDescriptor:)`. The
    /// flow object hides it, so this walks the same key path the community
    /// has used for years — verified per iOS release, never assumed. Each
    /// hop is capability-checked first, so a renamed key throws
    /// `.invalidInput` instead of tripping an Objective-C exception.
    public func providerFileDescriptor(from packetFlow: NSObject) throws -> Int32 {
        guard packetFlow.responds(to: NSSelectorFromString("socket")),
              let socket = packetFlow.value(forKey: "socket") as? NSObject,
              socket.responds(to: NSSelectorFromString("fileDescriptor")),
              let raw = socket.value(forKey: "fileDescriptor") else {
            throw Error.invalidInput(
                "could not read the provider utun file descriptor: the flow object has no socket.fileDescriptor"
            )
        }
        let fd: Int32
        if let number = raw as? NSNumber {
            fd = number.int32Value
        } else if let direct = raw as? Int32 {
            fd = direct
        } else {
            throw Error.invalidInput(
                "the provider utun file descriptor has an unexpected type and cannot be handed to the engine"
            )
        }
        guard fd >= 0 else {
            throw Error.invalidInput("the provider utun file descriptor is negative (\(fd))")
        }
        return fd
    }
}
