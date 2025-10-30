// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sbf70Kit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Sbf70Kit", targets: ["Sbf70Kit"]),
    ],
    targets: [
        .target(name: "Sbf70Kit"),
        .executableTarget(name: "sbf70-smoke", dependencies: ["Sbf70Kit"]),
        .testTarget(name: "Sbf70KitTests", dependencies: ["Sbf70Kit"]),
    ]
)
