// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "open-wispr",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                // whisper.h #includes <ggml.h>, which homebrew installs under
                // a separate prefix from whisper-cpp's. Point clang at both.
                .unsafeFlags(["-I/opt/homebrew/include", "-I/usr/local/include"]),
            ]
        ),
        .target(
            name: "OpenWisprLib",
            dependencies: ["CWhisper"],
            path: "Sources/OpenWisprLib",
            swiftSettings: [
                // When Swift imports CWhisper, Clang has to resolve <whisper.h>
                // and its transitive <ggml.h>. The CWhisper target's cSettings
                // only apply to its own .c files, so pass the brew include
                // prefixes through the Clang importer here.
                .unsafeFlags([
                    "-Xcc", "-I/opt/homebrew/include",
                    "-Xcc", "-I/usr/local/include",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedLibrary("whisper"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                // libggml/-base live in ggml's Cellar dir, libwhisper in
                // whisper-cpp's. Point at both brew prefixes so the linker
                // can resolve them on any arch.
                .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]),
            ]
        ),
        .executableTarget(
            name: "open-wispr",
            dependencies: ["OpenWisprLib"],
            path: "Sources/OpenWispr"
        ),
        .testTarget(
            name: "OpenWisprTests",
            dependencies: ["OpenWisprLib"],
            path: "Tests/OpenWisprTests",
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-I/opt/homebrew/include",
                    "-Xcc", "-I/usr/local/include",
                ]),
            ]
        ),
    ]
)
