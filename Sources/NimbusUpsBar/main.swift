// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpdater
import NimbusUpsBarKit
import UpsGuardCore

// Nimbus UPS Bar — a menu bar guard that unmounts external drives before a UPS runs out. See
// README.md.
//
// Flags (all optional; build.sh uses most of them):
//   --enable-agent          register this bundle's launchd agent (run at login, restart on crash) and exit
//   --disable-agent         unregister the agent and exit
//   --agent-status          print the agent's state and exit
//   --agent-plist [ID]      print the agent plist build.sh puts into the bundle with identifier ID
//                           (default: the release's), and exit
//   --render-icon PATH [--size PX]   write the app icon as a PNG and exit
//   --render-iconset DIR    write an .iconset (for iconutil) and exit
//   --render-dmg-background DIR [--signed]   write the disk image's background PNGs and exit
//   --dump-bar PATH         render just the status item to PATH, quit (layout check)
//   --dump-chart PATH       render the chart with fake data to PATH (+ -hover, -light, -empty), quit
//   --dump-settings DIR     render each pane of the Settings window to DIR/N-name.png, quit (layout check)
//   --dump-hid-raw PATH     write every raw HID element value of the attached UPS as JSON (the decode fixture); "-" for stdout
//
// Command-line use of the same readers and guard (no UI):
//   --after-safe sleep|shutdown   perform the after-safe action once, at the keyboard, after a typed confirmation
//   --print                 everything the menu would show, as text; exit
//   --inspect-json          the Inspector's whole snapshot (every section, as JSON) after a HID read; exit
//   --dump-inspector DIR    the Inspector window on screen, one PNG per section (Table and JSON); exit
//   --print-menu            the menu itself, built against the real UPS and volumes, as an indented tree; exit
//   --watch                 print readings and the guard's log as they happen (Ctrl-C to stop)
//   --simulate [SCENARIO]   run a rehearsal (pretend outage, nothing touched) in the terminal; exit when done.
//                           SCENARIO: drain (default), shortBattery, upsLostInOutage, upsLostOnLine
//   --holders PATH          who has files open on a mount point; exit
//   --volumes               the external volumes as the guard sees them; exit
//   --check-update          what the updater sees on GitHub; exit
//   --preflight APP.app     the release checks build.sh release runs; exit

func usage() -> Never {
    print("""
    usage: NimbusUpsBar [--enable-agent | --disable-agent | --agent-status | --agent-plist [BUNDLE_ID]]
                        [--render-icon PATH [--size PX]] [--render-iconset DIR]
                        [--render-dmg-background DIR [--signed]] [--dump-bar PATH] [--dump-chart PATH]
                        [--dump-settings DIR] [--dump-inspector DIR] [--inspect-json] [--dump-hid-raw PATH] [--after-safe sleep|shutdown]
                        [--print | --print-menu | --watch | --simulate [SCENARIO] | --holders PATH | --volumes]
                        [--check-update | --preflight APP.app]
    """)
    exit(2)
}

var dumpBarPath: String?
var renderIconPath: String?
var renderIconSize = 1024
var renderIconsetDir: String?
var renderDMGBackgroundDir: String?
var dmgSigned = false
var cli: CLI.Command?

// The development bundle has a defaults domain of its own; its first run starts from the
// owner's settings in the release's domain rather than from the defaults.
if Bundle.main.bundleIdentifier == Updates.devBundleID {
    let d = UserDefaults.standard
    let leaving: Set = [UPSMonitor.outageStartKey, CarryoverStore.key, BackgroundAgent.registeredDefaultsKey]
    if let seed = DevDefaults.seed(release: d.persistentDomain(forName: Updates.bundleID),
                                   dev: d.persistentDomain(forName: Updates.devBundleID) ?? [:], leaving: leaving) {
        for (k, v) in seed { d.set(v, forKey: k) }
        d.synchronize()
    }
}

var args = Array(CommandLine.arguments.dropFirst())
func takeValue(_ flag: String) -> String {
    guard !args.isEmpty else { fputs("\(flag) needs a value\n", stderr); usage() }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--enable-agent":
        do { try BackgroundAgent.setEnabled(true); print("agent: \(BackgroundAgent.statusDescription)") }
        catch { fputs("could not register the agent: \(error)\n", stderr); exit(1) }
        UserDefaults.standard.set(true, forKey: BackgroundAgent.registeredDefaultsKey)
        UserDefaults.standard.synchronize()
        exit(0)
    case "--disable-agent":
        do { try BackgroundAgent.setEnabled(false); print("agent: \(BackgroundAgent.statusDescription)") }
        catch { fputs("could not unregister the agent: \(error)\n", stderr); exit(1) }
        exit(0)
    case "--agent-status":
        print(BackgroundAgent.statusDescription)
        exit(0)
    case "--agent-plist":
        let id = args.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
        if id != nil { args.removeFirst() }
        cli = .agentPlist(bundleID: id ?? Updates.bundleID)
    case "--render-icon": renderIconPath = takeValue(a)
    case "--size": renderIconSize = Int(takeValue(a)) ?? 1024
    case "--render-iconset": renderIconsetDir = takeValue(a)
    case "--render-dmg-background": renderDMGBackgroundDir = takeValue(a)
    case "--signed": dmgSigned = true
    case "--dump-bar": dumpBarPath = takeValue(a)
    case "--dump-chart":
        let path = takeValue(a)
        MainActor.assumeIsolated {
            // A day shaped like 2026-10-10's: 80–105 W with steps as the display and drives
            // wake, and a four-minute outage twenty minutes ago where the voltage-derived gauge
            // loses 25 points in the first minute, flattens, and recharges slowly afterwards.
            let now = monotonicNow()
            var fake: [UPSMonitor.Sample] = []
            for i in 0..<360 {
                let t = now - Double(360 - i) * 10
                let outage = i >= 216 && i < 240
                var load = 88 + 6 * sin(Double(i) / 7) + (i % 90 < 30 ? 14 : 0)
                if i < 40 { load -= 20 }
                let charge: Int
                if i < 216 { charge = 100 } else if outage { charge = max(72, 100 - (i - 216) * 4) } else { charge = min(100, 72 + (i - 240) / 5) }
                let runtime = outage ? 3300 - (i - 216) * 20 : 5700 - (100 - charge) * 40
                fake.append(UPSMonitor.Sample(t: t, date: Date(), loadWatts: load, charge: charge, onBattery: outage,
                                              inputVoltage: outage ? 0 : 122, runtimeSeconds: runtime, batteryVoltage: outage ? 25.4 : 27.1))
            }
            let base = path.hasSuffix(".png") ? String(path.dropLast(4)) : path
            for (suffix, appearance, hover, data) in [("", NSAppearance.Name.darkAqua, nil as CGFloat?, fake), ("-hover", .darkAqua, 0.63, fake),
                                                      ("-light", .aqua, nil, fake), ("-empty", .darkAqua, nil, [])] {
                NSApplication.shared.appearance = NSAppearance(named: appearance)
                let v = ChartView(frame: NSRect(x: 0, y: 0, width: StatusBarController.chartWidth, height: ChartView.chartHeight))
                v.appearance = NSAppearance(named: appearance)
                v.samples = { data }
                v.now = { now }
                v.chargeLimit = Policy().hardAt.chargeAtMost
                v.simulateHover(atFraction: hover)
                v.debugBackground = true
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = base + suffix + ".png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("wrote \(out)")
            }
        }
        exit(0)
    case "--dump-settings": cli = .dumpSettings(dir: takeValue(a))
    case "--dump-inspector": cli = .dumpInspector(dir: takeValue(a))
    case "--inspect-json": cli = .inspectJSON
    case "--dump-hid-raw": cli = .dumpHIDRaw(path: takeValue(a))
    case "--after-safe": cli = .afterSafe(action: takeValue(a))
    case "--print": cli = .print
    case "--print-menu": cli = .printMenu
    case "--watch": cli = .watch
    case "--simulate":
        // An optional scenario name may follow: drain (the default), shortBattery,
        // upsLostInOutage, upsLostOnLine.
        var scenario = SimulatedOutage.Scenario.drain
        if let next = args.first, !next.hasPrefix("-") {
            args.removeFirst()
            guard let s = SimulatedOutage.Scenario(rawValue: next) else {
                fputs("--simulate takes \(SimulatedOutage.Scenario.allCases.map(\.rawValue).joined(separator: ", "))\n", stderr); usage()
            }
            scenario = s
        }
        cli = .simulate(scenario: scenario)
    case "--holders": cli = .holders(path: takeValue(a))
    case "--volumes": cli = .volumes
    case "--check-update": cli = .checkUpdate
    case "--preflight": cli = .preflight(app: takeValue(a))
    case "-h", "--help": usage()
    default:
        if !a.hasPrefix("-psn") { fputs("ignoring unknown argument \(a)\n", stderr) }
    }
}

if let dir = renderIconsetDir {
    do { try AppIcon.writeIconset(to: dir); print("wrote \(dir)") } catch { fputs("iconset: \(error)\n", stderr); exit(1) }
    exit(0)
}
if let dir = renderDMGBackgroundDir {
    do { try DMGBackground.write(to: dir, signed: dmgSigned); print("wrote \(dir)") } catch { fputs("dmg background: \(error)\n", stderr); exit(1) }
    exit(0)
}
if let path = renderIconPath {
    guard let data = AppIcon.pngData(px: renderIconSize) else { fputs("icon render failed\n", stderr); exit(1) }
    do { try data.write(to: URL(fileURLWithPath: path)); print("wrote \(path) (\(renderIconSize)×\(renderIconSize))") }
    catch { fputs("icon: \(error)\n", stderr); exit(1) }
    exit(0)
}
if let cli { exit(MainActor.assumeIsolated { CLI.run(cli) }) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var shared: AppDelegate?
    var monitor: UPSMonitor!
    var statusBar: StatusBarController!
    var updater: Updater?
    var settings: SettingsWindowController?
    var inspector: InspectorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()
        Log.shared.persistToFile = true

        // One copy only. The newest one wins: when the launchd agent starts a copy while a
        // hand-launched one is running (or the other way round), the older copy is asked to
        // quit, exits 0, and launchd's KeepAlive leaves it alone. The development bundle counts
        // as a copy too: two guards would both quit apps and unmount the same drives.
        if dumpBarPath == nil, Bundle.main.bundleIdentifier != nil {
            let others = Updates.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .filter { $0.processIdentifier != getpid() }
            for o in others {
                Log.shared.append("another copy is running (pid \(o.processIdentifier), \(o.bundleURL?.path ?? "?")); asking it to quit")
                o.terminate()
            }
        }

        monitor = UPSMonitor()
        if dumpBarPath == nil, let version = Updates.runningVersion {
            let u = Updater(config: Updates.config(currentVersion: version))
            u.onWillRelaunch = { [weak self] in self?.monitor.stop() }
            updater = u
        }
        statusBar = StatusBarController(monitor: monitor, updater: updater)
        updater?.onChange = { [weak self] in self?.statusBar.updaterChanged() }
        updater?.start()
        monitor.start()
        Notifications.shared.requestAuthorizationIfNeeded()

        // Persistence. `build.sh install` registers with --enable-agent before launching; a
        // drag-install from the disk image has nobody to do that, so the first launch from
        // /Applications registers instead. Once only: the flag is then set, so turning it off
        // later (menu, System Settings) sticks across relaunches and updates.
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        let registered = UserDefaults.standard.bool(forKey: BackgroundAgent.registeredDefaultsKey)
        if installed, !registered, BackgroundAgent.isAvailable {
            UserDefaults.standard.set(true, forKey: BackgroundAgent.registeredDefaultsKey)
            setAgent(enabled: true)
        }

        if let path = dumpBarPath {
            let t = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    let ok = self?.statusBar.dumpBar(to: path) ?? false
                    NSLog(ok ? "bar → \(path)" : "bar dump failed")
                    exit(ok ? 0 : 1)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }

    /// The Settings window, made on first use and kept.
    @objc func showSettings() {
        if settings == nil { settings = SettingsWindowController(monitor: monitor, updater: updater) }
        settings?.show()
    }

    /// The Inspector, made on first use and kept (its change log lives as long as the app).
    @objc func showInspector() {
        if inspector == nil { inspector = InspectorWindowController(monitor: monitor, updater: updater) }
        inspector?.show()
    }

    /// Turning the agent on makes launchd start a second copy at once (RunAtLoad), which then
    /// asks this one to quit; turning it off makes launchd stop the agent's job, so a plain
    /// copy is launched first to take over the menu bar item. Either way one copy survives.
    func setAgent(enabled: Bool) {
        do {
            if enabled {
                try BackgroundAgent.setEnabled(true)
                Log.shared.append("background agent registered: \(BackgroundAgent.statusDescription)")
            } else {
                let app = Bundle.main.bundleURL.path
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", app]
                try? relaunch.run()
                try BackgroundAgent.setEnabled(false)
                Log.shared.append("background agent unregistered: \(BackgroundAgent.statusDescription)")
            }
        } catch {
            Log.shared.append("agent: \(error)")
            let alert = NSAlert()
            alert.messageText = enabled ? "Could not enable Run in Background" : "Could not disable Run in Background"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        Log.shared.append("Nimbus UPS Bar quit")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
