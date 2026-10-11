// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NimbusUpsBar",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "NimbusUpsBar", targets: ["NimbusUpsBar"]),
    ],
    dependencies: [
        // Ours, MIT, no dependencies of its own: the GitHub-release auto-updater. Pinned by
        // Package.resolved; a new tag reaches this app only when someone bumps it here.
        .package(url: "https://github.com/njoubert/nimbus-updater.git", from: "1.4.0"),
    ],
    targets: [
        // The outage state machine and everything it needs, with no AppKit and no IOKit: the
        // readings, the policy, the phases, the simulated outage. Everything that decides
        // *what* to do lives here so it can be driven by fakes in the tests.
        .target(name: "UpsGuardCore"),
        .testTarget(name: "UpsGuardCoreTests", dependencies: ["UpsGuardCore"]),
        // The menu bar app: IOKit power sources and HID, Disk Arbitration, the menu, the
        // chart, the launchd agent. build.sh wraps the binary into Nimbus UPS Bar.app.
        .executableTarget(
            name: "NimbusUpsBar",
            dependencies: [
                "UpsGuardCore",
                .product(name: "NimbusUpdater", package: "nimbus-updater"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
