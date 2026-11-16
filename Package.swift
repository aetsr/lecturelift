// swift-tools-version: 5.10
import PackageDescription

let rtFlags: [CXXSetting] = [
    .unsafeFlags(["-std=c++20", "-fno-exceptions", "-fno-rtti", "-O3"]),
    .define("AUDIOFFT_APPLE_ACCELERATE"),   // FFTConvolver: use vDSP (else it silently falls back to Ooura)
    .define("NDEBUG"),                      // FFTConvolver asserts must not run on the audio thread
    .headerSearchPath("vendor/FFTConvolver"),
]

let package = Package(
    name: "LectureLift",
    defaultLocalization: "de",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "LectureLift", targets: ["HSApp"]),
        .executable(name: "lecturelift-render", targets: ["lecturelift-render"]),
    ],
    targets: [
        // Everything the audio I/O thread touches. C/C++ only, no allocation after prepare().
        .target(
            name: "HSCore",
            path: "Sources/HSCore",
            publicHeadersPath: "include",
            cxxSettings: rtFlags,
            linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("CoreAudio")]
        ),
        // Tap / aggregate lifecycle, process resolution, session state machine.
        .target(
            name: "HSAudio",
            dependencies: ["HSCore"],
            path: "Sources/HSAudio",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("AppKit"), .linkedFramework("AVFoundation")]
        ),
        // Menu-bar UI (library, so it can be rendered in tests without running the app).
        .target(
            name: "HSUI",
            dependencies: ["HSAudio", "HSCore"],
            path: "Sources/HSUI",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "HSApp",
            dependencies: ["HSAudio", "HSCore", "HSUI"],
            path: "Sources/HSApp",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "lecturelift-render",
            dependencies: ["HSCore"],
            path: "Sources/lecturelift-render",
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .testTarget(name: "HSCoreTests", dependencies: ["HSCore"], path: "Tests/HSCoreTests"),
        .testTarget(name: "HSAudioTests", dependencies: ["HSAudio"], path: "Tests/HSAudioTests"),
        .testTarget(name: "HSUITests", dependencies: ["HSUI", "HSAudio", "HSCore"], path: "Tests/HSUITests"),
    ],
    cxxLanguageStandard: .cxx20
)
