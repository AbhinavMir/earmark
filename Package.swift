// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Earmark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Earmark", targets: ["Earmark"])
    ],
    dependencies: [
        // Fetched by name, so a clone of this repository alone builds. Point
        // it at a sibling checkout to work on both at once:
        //   swift package edit AudibleKit --path ../audible-kit
        .package(url: "https://github.com/AbhinavMir/audible-kit", from: "0.3.0")
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
