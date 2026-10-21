// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Backstage",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        /// The panel and everything it shows. Apps import this one.
        .library(name: "Backstage", targets: ["Backstage"]),
        /// Recording and settings without any UI, for code that only reports traffic.
        .library(name: "BackstageCore", targets: ["BackstageCore"]),
        /// Prints the salt and hash for a passphrase: `swift run backstage-passphrase`.
        .executable(name: "backstage-passphrase", targets: ["backstage-passphrase"])
    ],
    targets: [
        .target(name: "BackstageCore"),
        .target(name: "Backstage", dependencies: ["BackstageCore"]),
        .executableTarget(name: "backstage-passphrase", dependencies: ["BackstageCore"]),
        .testTarget(name: "BackstageCoreTests", dependencies: ["BackstageCore"])
    ]
)
