// swift-tools-version: 6.2
// SwiftPM because the engine is a LIBRARY: the CLI client, the daemon, and any future
// App reader all link AwakeKit instead of talking to a wire they don't own. One brain,
// several mouths.
import PackageDescription

let package = Package(
    name: "awake",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AwakeKit", targets: ["AwakeKit"])
    ],
    dependencies: [
        // Keymap: the system-wide hotkey path (Carbon, permission-free).
        .package(url: "https://github.com/adriangalilea/swift-utils", from: "0.1.2")
    ],
    targets: [
        // The engine. Knows the kernel flag, assertions, battery, sessions. Knows no UI.
        .target(name: "AwakeKit"),
        // The single binary: `awake daemon` (menu bar + socket server, launchd-run),
        // `awake ...` / `asleep` (clients). Dispatch by argv[0] + subcommand.
        .executableTarget(name: "awake", dependencies: [
            "AwakeKit",
            .product(name: "Keymap", package: "swift-utils"),
        ]),
    ]
)
