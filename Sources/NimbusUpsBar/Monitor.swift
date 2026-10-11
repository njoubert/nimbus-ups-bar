// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import UpsGuardCore

/// The app's one source of truth: it reads the UPS (IOKit power sources every tick, the HID
/// report every few seconds), keeps the volume registry, feeds the `OutageGuard`, records the
/// samples the chart draws, and runs rehearsals and drills.
///
/// Cadence: a 2 s timer. On line power the HID is read every 10 s and a chart sample taken
/// with it; on battery (real or simulated) both happen every tick. A power-source change
/// notification, a wake, or a disk event polls at once.
@MainActor
final class UPSMonitor {

    struct Sample: Equatable {
        let t: TimeInterval        // monotonic
        let date: Date
        let loadWatts: Double?
        let charge: Int?
        let onBattery: Bool
        let inputVoltage: Double?
        let runtimeSeconds: Int?
        let batteryVoltage: Double?
    }

    enum SimulationKind: String { case rehearsal, drill }

    final class Simulation {
        let kind: SimulationKind
        let outage: SimulatedOutage
        let guardian: OutageGuard
        let startedAt: Date
        var safeSince: TimeInterval?
        var lineSince: TimeInterval?
        init(kind: SimulationKind, outage: SimulatedOutage, guardian: OutageGuard) {
            self.kind = kind; self.outage = outage; self.guardian = guardian; startedAt = Date()
        }
    }

    static let sampleInterval: TimeInterval = 10
    static let historyWindow: TimeInterval = 60 * 60
    static let tickInterval: TimeInterval = 2
    static let hidFreshFor: TimeInterval = 15

    let settings = Settings.shared
    let log = Log.shared
    let power = PowerSources()
    let hid = UPSHID()
    let volumes: VolumeRegistry
    /// The live guard: real environment, real readings.
    private(set) var live: OutageGuard
    private(set) var simulation: Simulation?
    /// The guard whose status the menu shows: the simulation's while one runs, else the live one.
    var shown: OutageGuard { simulation?.guardian ?? live }

    /// The merged picture of the UPS right now: IOKit's entry, with the HID's finer figures.
    private(set) var reading = UPSReading.absent()
    private(set) var iops = UPSReading.absent()
    private(set) var internalBattery: PowerSources.InternalBattery?
    private(set) var hidReport: UPSHID.Report?
    private(set) var hidReadAt: TimeInterval?
    private(set) var samples: [Sample] = []
    /// Set once any UPS has been seen this run, so "no UPS" can be told apart from "not yet read".
    private(set) var upsSeen = false
    /// When the power sources were last read (every tick, plus on every change event).
    private(set) var lastPollAt: TimeInterval?
    /// While the menu is open the HID is read every tick, so what is on screen is seconds old.
    var menuOpen = false {
        didSet { if menuOpen, !oldValue { hidDue = 0; poll(reason: nil) } }
    }
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var hidDue: TimeInterval = 0
    private var sampleDue: TimeInterval = 0
    private var hidInFlight = false
    private let hidQueue = DispatchQueue(label: "com.njoubert.nimbusupsbar.hid", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private lazy var environment = RealEnvironment(monitor: self)

    init() {
        volumes = VolumeRegistry(remembered: Settings.shared.knownVolumes)
        live = OutageGuard(environment: RealEnvironment.placeholder, policy: Settings.shared.policy)
        live = OutageGuard(environment: environment, policy: settings.policy)
        live.onChange = { [weak self] in self?.onChange?() }
        volumes.onChange = { [weak self] in self?.volumesChanged() }
        power.onChange = { [weak self] in self?.poll(reason: "power source change") }
        hid.onDeviceChange = { [weak self] attached in
            self?.log.append(attached ? "UPS attached over USB HID" : "UPS detached from USB HID")
            self?.hidDue = 0
            self?.poll(reason: attached ? "UPS attached" : "UPS detached")
        }
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.live.policy = self.settings.policy
            self.simulation?.guardian.policy = self.settings.policy
            self.onChange?()
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidDue = 0; self?.poll(reason: "wake") }
        })
    }

    func start() {
        guard timer == nil else { return }
        log.append("Nimbus UPS Bar started: \(Bundle.main.bundlePath); policy \(policyText)")
        power.start()
        let t = Timer(timeInterval: UPSMonitor.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(reason: nil) }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll(reason: "start")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        power.stop()
        PowerActions.holdAwake(false)
    }

    var policyText: String {
        let p = settings.policy
        return "grace \(Duration.text(p.graceSeconds)), hard after \(Duration.text(p.hardAfterSeconds)) or \(p.hardAtPercent) % or \(Duration.text(TimeInterval(p.hardAtRuntimeSeconds))) left, "
            + "\(p.quitApps ? "ask apps to quit" : "never quit apps"), then \(p.afterSafe.title.lowercased()); "
            + "volumes: \(settings.volumeMode == .allExternal ? "all external" : "\(settings.selectedVolumeUUIDs.count) selected")"
    }

    // MARK: Polling

    /// One look at everything. `reason` is logged when it is an event rather than the timer.
    func poll(reason: String?) {
        let now = monotonicNow()
        let snap = PowerSources.read(now: now)
        iops = snap.ups
        internalBattery = snap.internalBattery
        if snap.ups.present { upsSeen = true }
        lastPollAt = now
        let busy = snap.ups.onBattery || simulation != nil || menuOpen
        if now >= hidDue, !hidInFlight, hid.isAttached {
            hidDue = now + (busy ? UPSMonitor.tickInterval : UPSMonitor.sampleInterval)
            readHID(now: now)
        }
        reading = merge(iops: iops, hid: hidReport, hidAt: hidReadAt, now: now)
        if now >= sampleDue || snap.ups.onBattery != samples.last?.onBattery {
            sampleDue = now + (busy ? UPSMonitor.tickInterval : UPSMonitor.sampleInterval)
            record(reading, now: now)
        }
        tickGuards(now: now)
        onChange?()
    }

    private func readHID(now: TimeInterval) {
        hidInFlight = true
        let hid = self.hid
        hidQueue.async {
            let report = hid.read(now: now)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hidInFlight = false
                    if let report {
                        self.hidReport = report
                        self.hidReadAt = monotonicNow()
                        self.reading = self.merge(iops: self.iops, hid: report, hidAt: self.hidReadAt, now: self.hidReadAt!)
                        self.onChange?()
                    }
                }
            }
        }
    }

    /// IOKit's entry decides whether a UPS exists and what state it is in; a fresh HID report
    /// supplies the finer figures and takes over charge and runtime (seconds, not minutes).
    private func merge(iops: UPSReading, hid: UPSHID.Report?, hidAt: TimeInterval?, now: TimeInterval) -> UPSReading {
        guard iops.present else { return iops }
        guard let hid, let at = hidAt, now - at < UPSMonitor.hidFreshFor else { return iops }
        var r = iops
        if let c = hid.reading.chargePercent { r.chargePercent = c }
        if let s = hid.reading.runtimeSeconds { r.runtimeSeconds = s }
        r = r.merging(hid.reading)
        r.flags = hid.reading.flags.union(iops.onBattery ? [.discharging] : [.acPresent])
        return r
    }

    private func record(_ r: UPSReading, now: TimeInterval) {
        samples.append(Sample(t: now, date: Date(), loadWatts: r.present ? r.loadWatts : nil, charge: r.present ? r.chargePercent : nil,
                              onBattery: r.present && r.onBattery, inputVoltage: r.present ? r.inputVoltage : nil,
                              runtimeSeconds: r.present ? r.runtimeSeconds : nil, batteryVoltage: r.present ? r.batteryVoltage : nil))
        let cutoff = now - UPSMonitor.historyWindow - UPSMonitor.sampleInterval
        if let i = samples.firstIndex(where: { $0.t >= cutoff }), i > 0 { samples.removeFirst(i) }
    }

    private func tickGuards(now: TimeInterval) {
        if let sim = simulation {
            if sim.kind == .drill, reading.present, reading.onBattery {
                log.append("real transfer to battery during a drill: the drill is abandoned and the live guard takes over")
                endSimulation(reason: "a real outage started")
                live.tick(reading)
                return
            }
            let simReading = sim.outage.reading(realNow: now, monotonicStamp: now)
            sim.guardian.tick(simReading)
            advanceSimulation(sim, now: now)
            if sim.kind == .rehearsal { live.tick(reading) }
        } else {
            live.tick(reading)
        }
    }

    private func volumesChanged() {
        for v in volumes.mounted { settings.remember(v) }
        tickGuards(now: monotonicNow())
        onChange?()
    }

    // MARK: Owner actions

    func unmountNow() { shown.unmountNow() }
    func postpone(seconds: TimeInterval) { shown.postpone(seconds: seconds) }
    func skipQuittingApps() { shown.skipQuittingAppsThisOutage() }
    func remountNow() { shown.remountNow() }

    /// A manual unmount from the menu, outside the guard's bookkeeping: nothing remounts it.
    func unmount(_ v: VolumeState) {
        log.append("owner unmounts \(v.name) from the menu")
        volumes.unmount(v) { [weak self] result in
            switch result {
            case .success: self?.log.append("unmounted \(v.name)")
            case .failure(let e): self?.log.append("unmount of \(v.name) failed: \(e.message)")
            }
        }
    }

    func mount(_ v: VolumeState) {
        log.append("owner mounts \(v.name) from the menu")
        volumes.mount(v) { [weak self] result in
            switch result {
            case .success: self?.log.append("mounted \(v.name)")
            case .failure(let e): self?.log.append("mount of \(v.name) failed: \(e.message)")
            }
        }
    }

    func runSelfTest() -> Bool {
        switch hid.startQuickSelfTest() {
        case .success:
            log.append("battery self-test started (quick test, about 11 s)")
            hidDue = 0
            return true
        case .failure(let e):
            log.append("battery self-test could not be started: \(e.message)")
            return false
        }
    }

    // MARK: Simulation

    static let rehearsalSpeed: Double = 10
    static let drillSpeed: Double = 5

    /// A rehearsal: the real volumes and holders, a pretend UPS, and nothing touched. The live
    /// guard keeps running underneath it.
    func startRehearsal() {
        guard simulation == nil else { return }
        let env = RehearsalEnvironment(base: environment, speed: UPSMonitor.rehearsalSpeed)
        start(kind: .rehearsal, env: env, speed: UPSMonitor.rehearsalSpeed)
    }

    /// A drill: real quits, real unmounts, real remounts, driven by a pretend UPS. Only from
    /// line power; a real outage abandons it.
    func startDrill() {
        guard simulation == nil, !(reading.present && reading.onBattery) else { return }
        let env = DrillEnvironment(base: environment, speed: UPSMonitor.drillSpeed)
        start(kind: .drill, env: env, speed: UPSMonitor.drillSpeed)
    }

    private func start(kind: SimulationKind, env: GuardEnvironment, speed: Double) {
        let now = monotonicNow()
        // A pretend battery short enough that the decline shows, long enough that the time
        // limits (not the runtime limit) are what fire with the default policy.
        let runtime = min(reading.runtimeSeconds ?? 40 * 60, 40 * 60)
        let outage = SimulatedOutage(template: reading.present ? reading : nil, initialRuntime: runtime, speed: speed, realNow: now)
        let g = OutageGuard(environment: env, policy: settings.policy)
        g.onChange = { [weak self] in self?.onChange?() }
        simulation = Simulation(kind: kind, outage: outage, guardian: g)
        log.append("\(kind.rawValue) started at \(Int(speed))× speed: pretend outage, battery good for \(Duration.text(TimeInterval(runtime)))")
        g.tick(UPSReading(present: true, name: outage.name, onBattery: false, chargePercent: 100, runtimeSeconds: runtime, timestamp: now))
        hidDue = 0
        poll(reason: nil)
    }

    private func advanceSimulation(_ sim: Simulation, now: TimeInterval) {
        let st = sim.guardian.status
        if !sim.outage.powerRestored {
            if st.phase == .safe {
                if sim.safeSince == nil { sim.safeSince = now }
                // Hold "safe" for a moment so it can be seen, then bring the power back.
                if now - (sim.safeSince ?? now) >= 20 / sim.outage.speed {
                    sim.outage.restorePower(realNow: now)
                    log.append("\(sim.kind.rawValue): pretend power restored")
                }
            } else if !sim.outage.reading(realNow: now, monotonicStamp: now).present {
                sim.outage.restorePower(realNow: now)
                log.append("\(sim.kind.rawValue): the pretend UPS ran flat; pretend power restored")
            }
        } else if st.phase == .line {
            if sim.lineSince == nil { sim.lineSince = now }
            if now - (sim.lineSince ?? now) >= 3 { endSimulation(reason: "finished") }
        }
        if Date().timeIntervalSince(sim.startedAt) > 15 * 60 { endSimulation(reason: "timed out after 15 minutes") }
    }

    func endSimulation(reason: String = "ended from the menu") {
        guard let sim = simulation else { return }
        let st = sim.guardian.status
        var left: [String] = []
        if sim.kind == .drill {
            left = st.volumes.filter(\.unmountedByGuard).map(\.volume.name)
        }
        log.append("\(sim.kind.rawValue) \(reason)\(left.isEmpty ? "" : "; still unmounted: \(left.joined(separator: ", ")) (use the volume's Mount item)")")
        if sim.kind == .rehearsal, let env = (sim.guardian as AnyObject) as? OutageGuard, env === sim.guardian {
            // Nothing to undo: a rehearsal touched nothing.
        }
        simulation = nil
        PowerActions.holdAwake(false)
        live.tick(reading)
        onChange?()
    }

    // MARK: Freshness

    struct Freshness {
        /// Seconds since the figures on screen were read.
        var age: TimeInterval
        /// How often they are being read right now.
        var interval: TimeInterval
        /// "USB HID" when the detail read is working, "macOS" when only the power-source entry is.
        var source: String
    }

    /// How old what the menu shows is, and the current cadence.
    var freshness: Freshness? {
        let now = monotonicNow()
        let busy = reading.onBattery || simulation != nil || menuOpen
        let interval = busy ? UPSMonitor.tickInterval : UPSMonitor.sampleInterval
        if let at = hidReadAt, hid.isAttached, now - at < UPSMonitor.hidFreshFor * 4 {
            return Freshness(age: now - at, interval: interval, source: "USB HID")
        }
        if let at = lastPollAt { return Freshness(age: now - at, interval: UPSMonitor.tickInterval, source: "macOS") }
        return nil
    }

    // MARK: Health

    var health: [Health.Item] {
        Health.assess(reading: reading, hidAge: hidReadAt.map { monotonicNow() - $0 }, hidAttached: hid.isAttached,
                      upsSeen: upsSeen, internalBattery: internalBattery, protectedMounted: protectedMountedCount)
    }

    var protectedMountedCount: Int { volumes.mounted.filter { settings.isProtected($0) }.count }
}

/// The real desk, for the live guard. Not main-actor-isolated at the type level (the protocol
/// is not), so every method hops onto the main actor, which is the thread it is always on.
final class RealEnvironment: GuardEnvironment {
    private weak var monitor: UPSMonitor?
    init(monitor: UPSMonitor?) { self.monitor = monitor }
    nonisolated(unsafe) static let placeholder = RealEnvironment(monitor: nil)

    var now: TimeInterval { monotonicNow() }

    func protectedVolumes() -> [VolumeState] {
        MainActor.assumeIsolated {
            guard let m = monitor else { return [] }
            return m.volumes.sorted.filter { m.settings.isProtected($0) }
        }
    }

    func holders(of volume: VolumeState) -> [Holder] {
        guard let mp = volume.mountPoint else { return [] }
        return Holders.list(mountPoint: mp)
    }

    func requestQuit(_ holder: Holder) {
        MainActor.assumeIsolated {
            if !Holders.requestQuit(holder) { Log.shared.append("could not send a quit to \(holder.shortName) (pid \(holder.pid))") }
        }
    }

    func unmount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        MainActor.assumeIsolated {
            guard let m = monitor else { completion(.failure(GuardError("monitor gone"))); return }
            m.volumes.unmount(volume, completion: completion)
        }
    }

    func mount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        MainActor.assumeIsolated {
            guard let m = monitor else { completion(.failure(GuardError("monitor gone"))); return }
            m.volumes.mount(volume, completion: completion)
        }
    }

    func setAwakeHold(_ on: Bool) { MainActor.assumeIsolated { PowerActions.holdAwake(on) } }

    func notify(title: String, body: String) { MainActor.assumeIsolated { Notifications.shared.post(title: title, body: body) } }

    func perform(_ action: Policy.AfterSafe) {
        MainActor.assumeIsolated {
            switch action {
            case .keepRunning: break
            case .sleep: PowerActions.sleep()
            case .shutDown: PowerActions.shutDown()
            }
        }
    }

    func log(_ line: String) { MainActor.assumeIsolated { Log.shared.append(line) } }
}
