// swift-tools-version:5.10
import PackageDescription
import Foundation

// The standalone Owlse demo/example apps need the mock data and demo views
// (gated behind `STANDALONE_OWLSE_APP` in Sources/OwlseUI/Mocks) compiled into
// release builds. Enable it by building with `STANDALONE_OWLSE_APP=1` in the
// environment; it stays off for apps that embed Owlse so mocks never ship.
let owlseUISwiftSettings: [SwiftSetting] = ProcessInfo.processInfo
    .environment["STANDALONE_OWLSE_APP"] != nil ? [.define("STANDALONE_OWLSE_APP")] : []

let package = Package(
    name: "Owlse",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15),
        .macOS(.v13),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "Owlse", targets: ["Owlse"]),
        .library(name: "OwlseProxy", targets: ["OwlseProxy"]),
        .library(name: "OwlseUI", targets: ["OwlseUI"]),
    ],
    targets: [
        .target(name: "Owlse", dependencies: ["OwlseObjCHelpers"]),
        .target(name: "OwlseProxy", dependencies: ["Owlse"]),
        .target(name: "OwlseUI", dependencies: ["Owlse"], swiftSettings: owlseUISwiftSettings),
        .target(name: "OwlseObjCHelpers"),
        .testTarget(name: "OwlseTests", dependencies: ["Owlse"]),
    ]
)
