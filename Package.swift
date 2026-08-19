// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Earmark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Earmark", targets: ["Earmark"])
    ],
    dependencies: [
        .package(path: "../audible-kit")
    ],
    targets: [
        .executableTarget(
            name: "Earmark",
            dependencies: [.product(name: "AudibleKit", package: "audible-kit")]
        ),
        .testTarget(
            name: "EarmarkTests",
            dependencies: ["Earmark"]
        )
    ]
)
