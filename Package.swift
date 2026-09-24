// swift-tools-version:6.0
// PolyForm Noncommercial 1.0.0 — see LICENSE. Source-available, not open-source.
// Copyright (c) 2026 SwiftCoreWeb contributors.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SwiftCoreWeb",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "SwiftCoreWeb", targets: ["SwiftCoreWeb"]),
        .library(name: "SwiftCoreWebTesting", targets: ["SwiftCoreWebTesting"]),
        .library(name: "SwiftCoreWebDashboard", targets: ["SwiftCoreWebDashboard"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0"),
        // ponytail: pinned exact — swift-collections 1.7.0 (swift-nio's own
        // transitive dependency) calls `_swift_initBorrow`, a runtime symbol
        // only present in macOS 27+'s libswiftCore.dylib (apple/swift-collections#733).
        // On an older host OS the built test binary fails to `dlopen` with
        // "Symbol not found: _swift_initBorrow". Remove this pin once the
        // development machine's OS is upgraded past that runtime gap.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0")
    ],
    targets: [
        // MARK: - Compiler plugin (macros)
        .macro(
            name: "SwiftCoreWebMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Sources/SwiftCoreWebMacros",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Core framework
        .target(
            name: "SwiftCoreWeb",
            dependencies: [
                "SwiftCoreWebMacros",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
            ],
            path: "Sources/SwiftCoreWeb",
            resources: [
                .copy("Resources/vue")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - On-device SwiftUI dashboard (opt-in, depends on UIKit/SwiftUI)
        .target(
            name: "SwiftCoreWebDashboard",
            dependencies: ["SwiftCoreWeb"],
            path: "Sources/SwiftCoreWebDashboard",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // MARK: - In-memory test host
        .target(
            name: "SwiftCoreWebTesting",
            dependencies: [
                "SwiftCoreWeb",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ],
            path: "Sources/SwiftCoreWebTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        .testTarget(
            name: "SwiftCoreWebMacrosTests",
            dependencies: [
                "SwiftCoreWebMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            path: "Tests/SwiftCoreWebMacrosTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SwiftCoreWebTests",
            dependencies: ["SwiftCoreWeb", "SwiftCoreWebTesting"],
            path: "Tests/SwiftCoreWebTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SwiftCoreWebDashboardTests",
            dependencies: ["SwiftCoreWebDashboard"],
            path: "Tests/SwiftCoreWebDashboardTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
