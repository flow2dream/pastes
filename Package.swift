// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Pastes",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "pastes", targets: ["pastes"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "pastes",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "pastes",
            exclude: ["Assets.xcassets", "Info.plist", "pastes.entitlements"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
                .enableUpcomingFeature("MemberImportVisibility")
            ]
        ),
        .testTarget(
            name: "PastesTests",
            dependencies: ["pastes"],
            path: "Tests/PastesTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
