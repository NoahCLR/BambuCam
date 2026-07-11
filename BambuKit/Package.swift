// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BambuKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BambuKit", targets: ["BambuKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.1")
    ],
    targets: [
        .target(
            name: "BambuKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "BambuKitTests", dependencies: ["BambuKit"]),
    ]
)
