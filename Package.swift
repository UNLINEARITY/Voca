// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Voca",
    defaultLocalization: "en",
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
            path: "Sources/Voca",
            resources: [
                // 内嵌只读词典（scripts/make_dictionary.py 生成）
                .copy("Resources/dictionary.sqlite"),
                // 术语覆盖库（scripts/make_terms.py 生成，查词最高优先级）
                .copy("Resources/terms.sqlite"),
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
            ]
        ),
        .testTarget(
            name: "VocaTests",
            dependencies: ["Voca"],
            path: "Tests/VocaTests"
        )
    ]
)
