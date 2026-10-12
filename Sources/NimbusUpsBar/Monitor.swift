// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import NimbusUpsBarKit
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
        var lineSince: TimeInterval?
        init(kind: SimulationKind, outage: SimulatedOutage, guardian: OutageGuard) {
            self.kind = kind; self.outage = outage; self.guardian = guardian; startedAt = Date()
        }
    }

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
    /// The undecoded elements behind `hidReport`, for the Inspector.
    private(set) var hidRaw: UPSHID.RawReport?
    /// Counters for the Inspector's Readings section, since launch.
    private(set) var stats = Stats()
    struct Stats {
        var polls = 0
        var powerSourceEvents = 0
        var lastPowerSourceEventAt: TimeInterval?
        var hidReads = 0
        var hidEmpty = 0
        var hidAbandoned = 0
        var hidDropped = 0
        let startedAt = Date()
    }
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
    /// Read the UPS now, whatever the cadence, and capture everything (the Inspector's Refresh).
    func readNow() { fullNext = true; hidDue = 0; poll(reason: nil) }
    private var fullNext = false

    /// The Inspector is on screen: every HID read is the full capture (every element, every
    /// report), live or paused, so what it shows is always complete.
    var inspectorVisible = false

    /// The Inspector is on screen with live updates: read as often as on battery, so its values move.
    var inspectorOpen = false {
        didSet { if inspectorOpen, !oldValue { hidDue = 0; poll(reason: nil) } }
    }
    var onChange: (() -> Void)?
    /// Posted with every `onChange`, for listeners beyond the one closure (the Inspector).
    static let didUpdate = Notification.Name("com.njoubert.nimbusupsbar.monitorUpdated")

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: UPSMonitor.didUpdate, object: self)
    }

    private var timer: Timer?
    private var hidDue: TimeInterval = 0
    private var sampleDue: TimeInterval = 0
    /// When the HID read now in flight was started (nil: none). A read that has not come
    /// back after `hidAbandonAfter` (a stalled USB transaction) is written off so the next
    /// poll may start another; its result, if it ever lands, is dropped by sequence number.
    private var hidStartedAt: TimeInterval?
    private var hidSequence = 0
    static let hidAbandonAfter: TimeInterval = 10
    /// The live guard is not ticked before this moment: Disk Arbitration replays the mounted
    /// volumes a beat after registration, and a guard that looks before the replay sees an
    /// empty desk (and, resumed mid-outage with a sleep policy, would act on it).
    private var armedAt: TimeInterval = .infinity
    /// The live guard is ticking: `start()` was called and the arming delay has passed. A
    /// command-line look (`--inspect-json`, the dumps) never arms it.
    var isArmed: Bool { armedAt == 0 }
    static let armDelay: TimeInterval = 3
    /// The wall-clock start of the outage the live guard is in, so a relaunch mid-outage (a
    /// crash restart, an update, toggling the agent) carries the clock on instead of
    /// starting the grace period again.
    static let outageStartKey = "outageStartedAt"
    private var persistedOutage = false
    private let hidQueue = DispatchQueue(label: "com.njoubert.nimbusupsbar.hid", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private lazy var environment = RealEnvironment(monitor: self)

    init() {
        volumes = VolumeRegistry(remembered: Settings.shared.knownVolumes)
        live = OutageGuard(environment: RealEnvironment.placeholder, policy: Settings.shared.policy)
        live = OutageGuard(environment: environment, policy: settings.policy)
        live.onChange = { [weak self] in self?.changed() }
        volumes.onChange = { [weak self] in self?.volumesChanged() }
        power.onChange = { [weak self] in self?.poll(reason: "power source change") }
        hid.onDeviceChange = { [weak self] attached, atStart in
            // The UPS that was plugged in all along arrives too as the app starts; only a real
            // plug or unplug is logged (Events showed an "attached" at every launch).
            if !atStart { self?.log.append(attached ? "UPS attached over USB HID" : "UPS detached from USB HID") }
            self?.hidDue = 0
            self?.poll(reason: attached ? "UPS attached" : "UPS detached")
        }
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.live.policy = self.settings.policy
            self.simulation?.guardian.policy = self.settings.policy
            if self.timer != nil, self.timer?.timeInterval != self.settings.busyReadInterval { self.startTimer() }
            self.changed()
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidDue = 0; self?.poll(reason: "wake") }
        })
    }

    func start() {
        guard timer == nil else { return }
        log.append("Nimbus UPS Bar started: \(Bundle.main.bundlePath); policy \(policyText)")
        armedAt = monotonicNow() + UPSMonitor.armDelay
        if let began = UserDefaults.standard.object(forKey: UPSMonitor.outageStartKey) as? Date {
            let ago = Date().timeIntervalSince(began)
            if ago >= 0, ago < 12 * 3600 {
                live.resumeElapsed = ago
                log.append("the previous copy was mid-outage (began \(Duration.text(ago)) ago): resuming its clock if the UPS is still on battery")
            } else {
                UserDefaults.standard.removeObject(forKey: UPSMonitor.outageStartKey)
            }
        }
        power.start()
        startTimer()
        poll(reason: "start")
    }

    /// The tick: the guard's clock, and the read cadence when busy. Rebuilt when that setting changes.
    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: settings.busyReadInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(reason: nil) }
        }
        t.tolerance = min(0.5, settings.busyReadInterval / 4)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        power.stop()
        PowerActions.holdAwake(false)
    }

    var policyText: String {
        settings.policy.summary + "; volumes: \(settings.volumeMode == .allExternal ? "all external" : "\(settings.selectedVolumeUUIDs.count) selected")"
    }

    /// The read cadence right now: the busy interval on battery, in a simulation, and while the
    /// menu is open; the line-power interval otherwise.
    var currentReadInterval: TimeInterval {
        let busy = reading.onBattery || simulation != nil || menuOpen || inspectorOpen
        return busy ? settings.busyReadInterval : settings.lineReadInterval
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
        stats.polls += 1
        if reason == "power source change" { stats.powerSourceEvents += 1; stats.lastPowerSourceEventAt = now }
        let busy = snap.ups.onBattery || simulation != nil || menuOpen || inspectorOpen
        let hidBusy = hidStartedAt.map { now - $0 < UPSMonitor.hidAbandonAfter } ?? false
        if now >= hidDue, !hidBusy, hid.isAttached {
            hidDue = now + (busy ? settings.busyReadInterval : settings.lineReadInterval)
            readHID(now: now)
        }
        reading = merge(iops: iops, hid: hidReport, hidAt: hidReadAt, now: now)
        if now >= sampleDue || snap.ups.onBattery != samples.last?.onBattery {
            sampleDue = now + (busy ? settings.busyReadInterval : settings.lineReadInterval)
            record(reading, now: now)
        }
        tickGuards(now: now)
        changed()
    }

    private func readHID(now: TimeInterval) {
        if let s = hidStartedAt {
            stats.hidAbandoned += 1
            log.append("a HID read started \(Duration.text(now - s)) ago has not returned; starting another")
        }
        hidStartedAt = now
        hidSequence += 1
        let seq = hidSequence
        let hid = self.hid
        // Everything (outputs, every report, the descriptor, the properties) only while the
        // Inspector is on screen, live or paused; otherwise the guard's own reads stay light.
        let full = inspectorVisible || fullNext
        fullNext = false
        hidQueue.async { [weak self] in
            let raw = hid.fetch(full: full)
            let report = raw.map { UPSHID.decode($0, now: now) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard seq == self.hidSequence else { self.stats.hidDropped += 1; return }
                    self.hidStartedAt = nil
                    self.stats.hidReads += 1
                    if report == nil { self.stats.hidEmpty += 1 }
                    if let report {
                        self.hidRaw = raw
                        self.hidReport = report
                        self.hidReadAt = monotonicNow()
                        self.reading = self.merge(iops: self.iops, hid: report, hidAt: self.hidReadAt, now: self.hidReadAt!)
                        self.changed()
                    }
                }
            }
        }
    }

    private func merge(iops: UPSReading, hid: UPSHID.Report?, hidAt: TimeInterval?, now: TimeInterval) -> UPSReading {
        ReadingMerge.merge(iops: iops, hid: hid?.reading, hidAt: hidAt, now: now, freshFor: settings.hidFreshFor)
    }

    private func record(_ r: UPSReading, now: TimeInterval) {
        samples.append(Sample(t: now, date: Date(), loadWatts: r.present ? r.loadWatts : nil, charge: r.present ? r.chargePercent : nil,
                              onBattery: r.present && r.onBattery, inputVoltage: r.present ? r.inputVoltage : nil,
                              runtimeSeconds: r.present ? r.runtimeSeconds : nil, batteryVoltage: r.present ? r.batteryVoltage : nil))
        let cutoff = now - settings.historyWindow - settings.lineReadInterval
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
            if sim.kind == .rehearsal { tickLive(now: now) }
        } else {
            tickLive(now: now)
        }
    }

    private func tickLive(now: TimeInterval) {
        guard now >= armedAt else { return }
        if armedAt.isFinite, armedAt > 0 { armedAt = 0; log.append("guard armed: \(volumes.mounted.count) external volume\(volumes.mounted.count == 1 ? "" : "s") mounted") }
        live.tick(reading)
        let inOutage = live.status.outageStart != nil
        if inOutage != persistedOutage {
            persistedOutage = inOutage
            if inOutage { UserDefaults.standard.set(Date(timeIntervalSinceNow: -live.status.elapsed), forKey: UPSMonitor.outageStartKey) }
            else { UserDefaults.standard.removeObject(forKey: UPSMonitor.outageStartKey) }
        }
    }

    private func volumesChanged() {
        for v in volumes.mounted { settings.remember(v) }
        tickGuards(now: monotonicNow())
        changed()
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
    func startRehearsal(_ scenario: SimulatedOutage.Scenario = .drain) {
        guard simulation == nil else { return }
        let env = RehearsalEnvironment(base: environment, speed: UPSMonitor.rehearsalSpeed)
        start(kind: .rehearsal, env: env, speed: UPSMonitor.rehearsalSpeed, scenario: scenario)
    }

    /// A drill: real quits, real unmounts, real remounts, driven by a pretend UPS. Only from
    /// line power; a real outage abandons it.
    func startDrill() {
        guard simulation == nil, !(reading.present && reading.onBattery) else { return }
        let env = DrillEnvironment(base: environment, speed: UPSMonitor.drillSpeed)
        start(kind: .drill, env: env, speed: UPSMonitor.drillSpeed)
    }

    private func start(kind: SimulationKind, env: GuardEnvironment, speed: Double, scenario: SimulatedOutage.Scenario = .drain) {
        let now = monotonicNow()
        // A pretend battery short enough that the decline shows, long enough that the time
        // limits (not the runtime limit) are what fire with the default policy.
        let runtime = min(reading.runtimeSeconds ?? 40 * 60, 40 * 60)
        let outage = SimulatedOutage(template: reading.present ? reading : nil, initialRuntime: runtime, speed: speed, realNow: now, scenario: scenario)
        let g = OutageGuard(environment: env, policy: settings.policy)
        g.onChange = { [weak self] in self?.changed() }
        simulation = Simulation(kind: kind, outage: outage, guardian: g)
        log.append("\(kind.rawValue) started at \(Int(speed))× speed: \(scenario.title.lowercased()), battery good for \(Duration.text(TimeInterval(outage.initialRuntime)))")
        g.tick(UPSReading(present: true, name: outage.name, onBattery: false, chargePercent: 100, runtimeSeconds: runtime, timestamp: now))
        hidDue = 0
        poll(reason: nil)
    }

    private func advanceSimulation(_ sim: Simulation, now: TimeInterval) {
        let st = sim.guardian.status
        if !sim.outage.powerRestored {
            if let what = sim.outage.advance(phase: st.phase, realNow: now) { log.append("\(sim.kind.rawValue): \(what)") }
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
        simulation = nil
        // The sleep assertion is process-wide and a drill's guard shares it with the live
        // guard, which may be mid-outage right now: release it only when nothing live needs it.
        if ![.holding, .soft, .hard].contains(live.status.phase) { PowerActions.holdAwake(false) }
        live.tick(reading)
        changed()
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
        if let at = hidReadAt, hid.isAttached, now - at < settings.hidStaleAfter {
            return Freshness(age: now - at, interval: currentReadInterval, source: "USB HID")
        }
        if let at = lastPollAt { return Freshness(age: now - at, interval: settings.busyReadInterval, source: "macOS") }
        return nil
    }

    // MARK: Health

    var health: [Health.Item] {
        Health.assess(reading: reading, hidAge: hidReadAt.map { monotonicNow() - $0 }, hidAttached: hid.isAttached,
                      upsSeen: upsSeen, internalBattery: internalBattery, protectedMounted: protectedMountedCount,
                      staleAfter: settings.hidStaleAfter)
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
            switch Holders.requestQuit(holder) {
            case .sent: break
            case .notSent: Log.shared.append("could not send a quit to \(holder.shortName) (pid \(holder.pid))")
            case .notAnApp: Log.shared.append("cannot ask \(holder.shortName) (pid \(holder.pid)) to quit: not a running application")
            }
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

    func perform(_ action: Policy.MacAction) {
        MainActor.assumeIsolated {
            switch action {
            case .sleep: PowerActions.sleep()
            case .shutDown: PowerActions.shutDown()
            }
        }
    }

    func log(_ line: String) { MainActor.assumeIsolated { Log.shared.append(line) } }
}
