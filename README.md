# LibXray-SPM

libXray as a Swift Package: `Package.swift` points directly at the
`libxray-apple-cgo.zip` asset of every [XTLS/libXray release](https://github.com/XTLS/libXray/releases),
and the raw C bridge hiding in its `LibXray.xcframework` is covered by a small
typed Swift API.

libXray is a wrapper XTLS builds for embedding Xray-core into iOS, macOS, and
tvOS clients. That is exactly what this package gives you, in two layers:

- A binary target whose URL and SHA-256 checksum name one XTLS release,
  updated by a nightly job. SwiftPM downloads the zip per version, verifies
  the hash, unpacks `LibXray.xcframework`, and caches it, so this repository
  itself stores no binaries.
- `LibXraySwift`, a Swift module over the engine's single JSON entry point,
  with names a Swift developer would pick rather than libXray's own

## Requirements

macOS 13+, iOS 15+, tvOS 17+, Swift 5.9 / Xcode 15+. The framework carries no
watchOS or visionOS slices because XTLS does not build those, so the package
declares no support for them either. Since the framework is static, linking
needs `Security.framework` and `libresolv`; the package wires both through its
own target settings, so nothing is required of your app target. On the first
resolve of a version SwiftPM fetches the ~100 MB zip from XTLS, checks the
checksum, and unpacks it; later builds on the same machine reuse the cached
framework without another download.

## Installation

Xcode: File > Add Package Dependencies, and enter

```
https://github.com/amirsaam/LibXray-SPM.git
```

In `Package.swift`:

```swift
.package(
    url: "https://github.com/amirsaam/LibXray-SPM.git",
    .exact("26.10.29")
)
```

Pick Exact Version in Xcode's requirement dropdown (or write `.exact`
yourself as above). Exact is the recommended setup for this package.

Versions here mirror the XTLS/libXray release the framework came from, with
same names upstream uses minus the "libXray" part: upstream "libXray v26.10.29"
is release/tag `v26.10.29` here.

Why exact rather than `upToNextMajor` or `upToNextMinor`: XTLS/libXray
publishes daily calver releases, so an open-ended requirement turns everyone
who resolves your project onto that day's rebuild, on whatever cadence Xcode
happens to resolve, without a decision on your side. Each version is one
~100 MB download on first use, and an engine update rewrites how your
connections behave, for better or worse. With `.exact`, an engine change only
happens in a commit you write and can review, and CI builds stay
reproducible across machines and months. Moving is deliberate: change the
string to the tag you want (check the Releases page here or upstream's), and
the next resolve pulls that engine and nothing else.

`Update To Latest Package Versions` in Xcode does not override an exact pin;
it only picks versions the requirement allows, so your chosen version is safe
from stray bumps. If you do want the newest engine as it lands rather than
reviewing each one, `.upToNextMinor` is the loose alternative, chosen
deliberately and with the download cost in mind.

## Importing

```swift
import LibXraySwift
```

The import exposes everything: the public `XrayBridge` API, `XrayConfig`, the
support types, and the underlying C functions `CGoInvoke` / `CGoFree` for when
a change has not reached this wrapper yet.

## The engine in ninety seconds

Xray-core runs in-process. You give it a complete JSON configuration, it
launches listeners and outbounds inside your app, and it keeps running until
you stop it or replace it. Everything else is helper work on top: turning
subscription texts or share links into that JSON, validating configs, probing
servers, and picking spare ports. The engine keeps no session history you can
read back; your app owns the lifecycle.

```swift
import LibXraySwift

// 1. Start from something a human or a feed gave you
let links = """
vless://12345678-abcd-abcd-abcd-123456789abc@example.com:443?type=tcp&security=tls&encryption=none&sni=example.com#Node
"""
let config = try XrayBridge.fromShareLinks(links)

// 2. Make sure it builds before you rely on it
try config.check()

// 3. Launch. Blocking call, so keep it off the main thread.
Task.detached {
    do { try config.launch() } catch { print("launch failed:", error) }
}

// 4. Later
try config.shutDown()
```

## API reference

Everything below is reachable after `import LibXraySwift`. Calls marked
blocking expect a background task from UI code. Failures surface as
`EngineError` with the engine's own message, catchable like any Swift error.

### Starting and stopping

```swift
XrayBridge.engineVersion() throws -> String
XrayBridge.engineIsRunning() throws -> Bool
XrayBridge.launch(_ configuration: String) throws
XrayBridge.check(_ configuration: String) throws
XrayBridge.shutDown() throws
```

- `engineVersion()` answers, for example, "26.10.29", the Xray-core build
  compiled into the framework.
- `engineIsRunning()` refers to an instance your own process launched.
- `launch(_:)` takes a complete Xray JSON configuration as a string and
  starts the engine. Launching again while an instance runs replaces it.
  Blocking.
- `check(_:)` validates a configuration string without starting anything; the
  thrown `EngineError` carries the engine's parser complaint, which is the
  cheapest way to reject bad user input.
- `shutDown()` stops the process's running instance, and answers success even
  when nothing was running.

### XrayConfig

A configuration as it travels: either JSON text you already have, or the
output of `XrayBridge.fromShareLinks`.

```swift
public struct XrayConfig {
    public var json: String
    public init(json: String)
    public func check() throws
    public func launch() throws
    public func shutDown() throws
}
```

`check()`, `launch()`, and `shutDown()` are thin wrappers over the plain-string
forms above. `json` is plain JSON text you can persist, log, or edit between
calls.

## Subscription texts and share links

```swift
XrayBridge.decode(_ text: String, ageSecret: String? = nil) throws -> String
XrayBridge.fromShareLinks(_ links: String, ageSecret: String? = nil) throws -> XrayConfig
XrayBridge.toShareLinks(_ configuration: String) throws -> String
```

- `decode(_:)` turns a raw subscription body (base64 blobs included) into
  readable proxy links. When the feed exports Age-encrypted content, pass the
  `AGE-SECRET-KEY-...` string as `ageSecret`.
- `fromShareLinks(_:)` accepts vless, vmess, trojan, ss, socks, and hysteria2
  share links, newline-separated mixed feeds, legacy vmess QR texts, and
  `{"outbounds":[...]}` JSON as input. Bad entries are dropped instead of
  failing the call; if nothing survives, it throws `EngineError`
  ("no valid outbound found"). Throwing when the input offers only
  half-specified links, e.g. vless URIs without any security settings, is
  normal.
- `toShareLinks(_:)` goes back: one routable outbound, one share link.

Note the engine's answer for `fromShareLinks` keeps only projected, buildable
outbounds, so what you get back is already pruned to what this build can run.

## Age keys

```swift
XrayBridge.newAgeKeys(kind: AgeKeyKind = .x25519) throws -> AgeKeyPair
```

`AgeKeyKind.x25519` gives the classic pair; `.hybrid` adds post-quantum
resistance for feeds that support it. An `AgeKeyPair` carries `secretKey`
(starting "AGE-SECRET-KEY-", stays on the device) and `publicKey` (starting
"age1-", publishable). The secret unlocks subscription exports someone shared
with you privately; nothing else uses it.

## Ports

```swift
XrayBridge.sparePorts(howMany count: Int = 1, excluding reserved: [Int] = []) throws -> [Int]
```

Reserves free TCP ports from the OS. Useful for client configurations whose
inbounds listen locally, since picking hardcoded port ranges means collisions
more often than not. `excluding` skips port numbers you already have.

## Latency probes

```swift
XrayBridge.ping(targets: [ProxyPingTarget], timeoutSeconds: Int, testURL: String)
    throws -> [PingAnswer]
```

`ProxyPingTarget` pairs a server's compact Xray JSON with the outbound tag to
request through:

```swift
ProxyPingTarget(
    configuration: #"{"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[...]},"streamSettings":{...}}]}"#,
    tag: "proxy"
)
```

Each measurement opens the engine, completes one full HTTP request through the
target's outbound, and closes. Answers come back in input order; each carries
`succeeded`, `milliseconds`, and — on failure — `failureNote` with the
engine's reason. Whole-batch deadline is `timeoutSeconds`, and the probe
endpoint is whatever `testURL` you point it at; `https://www.google.com/generate_204`
with a small timeout is the usual choice. Blocking since it waits for the
slowest target.

## Geo data catalogs

```swift
XrayBridge.catalogGeoData(folder: String, file: String, kind: GeoDataKind) throws
```

Reads a GeoIP/GeoSite `.dat` file from `folder` (database name without
extension in `file`, `kind` either `.domains` for geosite or `.addresses` for
geoip) and writes every code/region with rule and category counts to
`<folder>/<file>.<kind>.txt`. Great for building in-app pickers for rule sets
from `geoip.dat`/`geosite.dat` you ship or download.

## Raw bridge

The engine's protocol is a single JSON call:
`{"apiVersion":3,"method":"...","payload":{...}}` in,
`{"success":Bool,"data":Any,"error":"..."}` out. If this wrapper lags a new
upstream capability, bypass it:

```swift
let request = #"{"apiVersion":3,"method":"xrayVersion"}"#
var bytes = Array(request.utf8CString)
guard let pointer = CGoInvoke(&bytes) else { return }
defer { CGoFree(pointer) }
let response = String(cString: pointer)
```

`CGoInvoke` returns a malloc'd C string; `CGoFree` releases it. `XrayBridge`
does that cleanup internally on every call. Anything you pass with an
`apiVersion` the engine does not know earns "unsupported apiVersion", which is
also your signal that the embedded engine advanced and this wrapper's public
methods are the ones to prefer.

## Updating the engine across releases

The nightly job handles it. Timeline goes: at midnight UTC the workflow reads
XTLS/libXray's latest release; if no matching tag exists here, it downloads
upstream's `libxray-apple-cgo.zip`, hashes it, rewrites the `url` and
`checksum` lines in `Package.swift` to that release, commits, tags
`v<version>` (upstream "libXray v26.10.29" is release and tag `v26.10.29`
here, plain), and publishes the release. A follow-up `swift build` job on a
macOS runner checks the new tag as a consumer would.

After that, your app does not move on its own. With an exact requirement,
moving to the new engine is one deliberate change of the version string in
your manifest (Xcode: edit the package's Exact Version field), followed by a
resolve that fetches that day's archive straight from XTLS/libXray. Resolving
at, say, `26.10.31` embeds exactly the engine that tag's `Package.swift`
names. Nothing binary is committed here; this repository changes only by two
manifest lines per release.

You can also trigger the job from the Actions tab with workflow_dispatch if
you want the newest engine before the next midnight.

## Troubleshooting

- **"unsupported apiVersion"** — XTLS/libXray bumped its bridge protocol. The
  constant to update is `XrayBridge.protocolVersion` inside
  `Sources/LibXraySwift/XrayBridge.swift`, taken from the `LibXrayAPIVersion`
  in upstream `invoke_model.go` (and please open an issue so the next daily
  version also carries the fix).
- **"no valid outbound found"** — the engine declined every entry you passed.
  Share links need to be fully specified; a bare `vless://uuid@host:443`
  without scheme defaults will not build. Validate with `check()` for detail
  on a JSON config.
- **linker failures mentioning `Sec*` or `res_9_*` symbols** — your app built
  against the binary target directly instead of going through `LibXraySwift`.
  Depend on the `LibXraySwift` product, which owns the framework and library
  linkage.
- **Package resolution hangs or fails on "unsupported platform"** — the
  framework has no watchOS/visionOS slices, so those destinations cannot use
  this package, now or later.

## How the layout works

```
Package.swift                the only per-release change: binary target URL and checksum
Sources/LibXraySwift/        typed API over the C bridge
  XrayBridge.swift           raw call plumbing and protocol version
  Engine.swift               start/stop/version/state
  XrayConfig.swift           the XrayConfig wrapper type
  Subscriptions.swift        decode, share link conversions
  Measure.swift              spare ports, latency probes
  GeoAndKeys.swift           Age key pairs, geo data catalogs
  Support.swift              error type and shared codecs
scripts/update_package.py    manifest rewriter used by the nightly job
.github/workflows/update-libxray.yml    the nightly job
```

## Credits

All engine work belongs to the [XTLS team](https://github.com/XTLS/libXray)
and [Xray-core](https://github.com/XTLS/Xray-core). This repo only carries
their Apple builds in SwiftPM-friendly form. The license is upstream's; see
`LICENSE`.
