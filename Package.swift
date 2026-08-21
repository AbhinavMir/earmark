// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Earmarky",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Earmarky", targets: ["Earmarky"])
    ],
    dependencies: [
        // Fetched by name, so a clone of this repository alone builds. Point
        // it at a sibling checkout to work on both at once:
        //   swift package edit AudibleKit --path ../audible-kit
        .package(url: "https://github.com/AbhinavMir/audible-kit", from: "0.4.4")
    ],
    targets: [
        .executableTarget(
            name: "Earmarky",
            dependencies: [.product(name: "AudibleKit", package: "audible-kit")]
        ),
        .testTarget(
            name: "EarmarkyTests",
            dependencies: ["Earmarky"]
        )
    ]
)
