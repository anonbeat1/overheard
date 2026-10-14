// swift-tools-version: 5.10
// meeting-transcriber: transcript locale di una cartella di Overheard (Cohere Transcribe + diarizzazione).
// Build: ./build.sh (compila anche mlx.metallib, necessario a runtime accanto all'eseguibile)
import PackageDescription

let package = Package(
    name: "meeting-transcriber",
    platforms: [.macOS("15.0")],
    dependencies: [.package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.28")],
    targets: [
        .executableTarget(
            name: "meeting-transcriber",
            dependencies: [
                .product(name: "CohereTranscribeASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ]
        ),
    ]
)
