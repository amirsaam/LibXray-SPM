// swift-tools-version: 5.9
import PackageDescription

// The nightly workflow (.github/workflows/update-libxray.yml) keeps the two
// lines below in lockstep with the latest XTLS/libXray release: the URL of
// upstream's libxray-apple-cgo.zip asset and the SHA-256 of its bytes.
// SwiftPM downloads that zip, verifies the checksum, unpacks LibXray.xcframework
// from it, and caches the result per checksum, so both lines must always
// describe the same release.
let package = Package(
    name: "LibXray-SPM",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .tvOS(.v17)
    ],
    products: [
        .library(name: "LibXraySwift", targets: ["LibXraySwift"])
    ],
    targets: [
        .binaryTarget(
            name: "LibXray",
            url: "https://github.com/XTLS/libXray/releases/download/v26.10.29/libxray-apple-cgo.zip",
            checksum: "4e788ea0068939132373e3d899342630e8de763ed08042e0a0bef5202f4ccaf2"
        ),
        .target(
            name: "LibXraySwift",
            dependencies: ["LibXray"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("resolv")
            ]
        )
    ]
)
