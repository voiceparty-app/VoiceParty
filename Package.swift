// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceParty",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "VoiceParty", targets: ["VoiceParty"]),
        .library(name: "VoicePartyCore", targets: ["VoicePartyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Parakeet speech recognition (CoreML, Apache-2.0). Text-normalization binary trait off.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.3", traits: []),
    ],
    targets: [
        // Portable logic: models, text pipeline, hotkey state machine, storage, profile import/export.
        // Foundation + GRDB only — no AppKit, no Apple ML frameworks.
        .target(
            name: "VoicePartyCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Apple on-device speech (SpeechAnalyzer) and language model (FoundationModels).
        .target(
            name: "VoicePartyEngines",
            dependencies: ["VoicePartyCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        // The macOS app: hotkeys, audio, overlay, insertion, hub UI.
        .executableTarget(
            name: "VoiceParty",
            dependencies: ["VoicePartyCore", "VoicePartyEngines"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
