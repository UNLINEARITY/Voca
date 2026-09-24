// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Voca",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Voca",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Voca"
        ),
        .testTarget(
            name: "VocaTests",
            dependencies: ["Voca"],
            path: "Tests/VocaTests"
        )
    ]
)
