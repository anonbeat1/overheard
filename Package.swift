// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Overheard",
    platforms: [.macOS("14.2")],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")],
    targets: [.executableTarget(
        name: "Overheard",
        dependencies: [.product(name: "Sparkle", package: "Sparkle")],
        // Sparkle.framework sta in Contents/Frameworks (lo copia build.sh); FoundationModels c'è solo da macOS 26
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                       "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
    )]
)
