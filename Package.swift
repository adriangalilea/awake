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
        // PermissionGrants: the Standing vocabulary + the notification reach probe.
        // AppInstallations: the app's whole life (the agent as its job, the move into
        // Applications, upgrade and delete).
        .package(url: "https://github.com/adriangalilea/swift-utils", .upToNextMinor(from: "0.38.6"))
    ],
    targets: [
        // The engine. Knows the kernel flag, assertions, battery, sessions. Knows no UI;
        // PermissionGrants only for the notification reach value Status carries.
        .target(name: "AwakeKit", dependencies: [
            .product(name: "PermissionGrants", package: "swift-utils")
        ]),
        // Every surface a human reads, as functions of state: the menu model, the
        // CLI's parse and output, the banners, the glyphs. The daemon and the CLI draw
        // it; awake-scene records it. Never does IO.
        .target(name: "AwakeSurface", dependencies: [
            "AwakeKit",
            .product(name: "Keymap", package: "swift-utils"),
            .product(name: "PermissionGrants", package: "swift-utils"),
        ]),
        // The single binary: `awake daemon` (menu bar + socket server, launchd-run),
        // `awake ...` / `asleep` (clients). Dispatch by argv[0] + subcommand.
        .executableTarget(name: "awake", dependencies: [
            "AwakeKit",
            "AwakeSurface",
            .product(name: "Keymap", package: "swift-utils"),
            .product(name: "PermissionGrants", package: "swift-utils"),
            .product(name: "AppInstallations", package: "swift-utils"),
        ]),
        // The showcase compiler, never shipped: plays a scene script through the real
        // engine against a scripted world and writes the timeline the web plays.
        .executableTarget(name: "awake-scene", dependencies: [
            "AwakeKit",
            "AwakeSurface",
            .product(name: "PermissionGrants", package: "swift-utils"),
        ]),
        // The notification hop: a separate .app nested in the bundle, LS-launched per
        // message so UNUserNotificationCenter sees a user-context app, not a launchd
        // agent. Takes one string, posts it, records the reach it saw, exits.
        .executableTarget(name: "awake-notifier", dependencies: [
            "AwakeKit",
            .product(name: "PermissionGrants", package: "swift-utils"),
        ]),
    ]
)
