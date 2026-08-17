// swift-tools-version: 6.2

import PackageDescription

let occtRoot = "Vendor/OpenCascadeStatic/macos-arm64"
let occtLibraries = [
    "TKDESTEP",
    "TKDEIGES",
    "TKDECascade",
    "TKDESTL",
    "TKDEPLY",
    "TKDEOBJ",
    "TKDEGLTF",
    "TKRWMesh",
    "TKXCAF",
    "TKDE",
    "TKXSBase",
    "TKVCAF",
    "TKCAF",
    "TKLCAF",
    "TKCDF",
    "TKBO",
    "TKBool",
    "TKPrim",
    "TKV3d",
    "TKService",
    "TKMesh",
    "TKShHealing",
    "TKHLR",
    "TKTopAlgo",
    "TKGeomAlgo",
    "TKBRep",
    "TKGeomBase",
    "TKG3d",
    "TKG2d",
    "TKMath",
    "TKernel"
]

let package = Package(
    name: "Stairs",
    platforms: [
        // The Xcode project owns the iOS/iPadOS app targets. This package is
        // intentionally macOS-only so Xcode does not try to link the SwiftUI
        // executable product as an iPhoneOS command-line package target.
        // v15 floor: the RealityKit canvas uses LowLevelMesh and static-mesh
        // collision (macOS 15+); the shipping app deploys far above this anyway.
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Stairs", targets: ["Stairs"])
    ],
    targets: [
        .target(
            name: "StairsStepImporter",
            path: "Sources/StairsStepImporter",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Vendor/OpenCascadeStatic/macos-arm64/include/opencascade"),
                .unsafeFlags([
                    "-std=c++17",
                    "-Wno-documentation",
                    "-Wno-deprecated-declarations"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(occtRoot)/lib"
                ]),
                .linkedLibrary("objc", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ] + occtLibraries.map { .linkedLibrary($0, .when(platforms: [.macOS])) }
        ),
        .target(
            name: "StairsCore",
            dependencies: [
                .target(name: "StairsStepImporter", condition: .when(platforms: [.macOS]))
            ],
            path: "Sources/StairsCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Stairs",
            dependencies: [
                "StairsCore"
            ],
            path: "Sources/Stairs",
            swiftSettings: [
                .define("STAIRS_SWIFTPM_EXECUTABLE"),
                .swiftLanguageMode(.v6),
                // Approachable concurrency: the UI module defaults to the main
                // actor (StairsCore stays non-isolated for its off-main import
                // work). Keeps Xcode's SWIFT_DEFAULT_ACTOR_ISOLATION /
                // SWIFT_APPROACHABLE_CONCURRENCY in sync with `swift build`.
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "StairsCoreTests",
            dependencies: ["StairsCore"],
            path: "Tests/StairsCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "StairsQuickLookPreview",
            dependencies: [
                "StairsCore"
            ],
            path: "Sources/StairsQuickLookPreview",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-application-extension"], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("QuickLookUI", .when(platforms: [.macOS])),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"], .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "StairsQuickLookThumbnail",
            dependencies: [
                "StairsCore"
            ],
            path: "Sources/StairsQuickLookThumbnail",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-application-extension"], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("QuickLookThumbnailing", .when(platforms: [.macOS])),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"], .when(platforms: [.macOS]))
            ]
        )
    ]
)
