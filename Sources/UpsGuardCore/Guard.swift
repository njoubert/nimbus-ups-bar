// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The outage state machine. Fed one `UPSReading` per tick, it decides what to do with the
/// protected volumes and does it through the `GuardEnvironment`. It knows nothing about
/// IOKit, Disk Arbitration or AppKit, which is what makes it testable with fakes.
///
/// Phases, measured from the first reading on battery:
///
/// | Phase        | Meaning |
/// |--------------|---------|
/// | `line`       | Mains present (or no UPS at all). Nothing to do. |
/// | `holding`    | On battery inside the grace period. Notified, Mac held awake, nothing touched. |
/// | `soft`       | Grace over. Apps holding files are asked to quit; a volume unmounts as soon as no app holds it. |
/// | `hard`       | A hard limit hit (time, charge, runtime, the UPS vanishing, or the owner). Every volume is force-unmounted regardless. |
/// | `safe`       | Every protected volume is unmounted. Sleep hold released; the after-safe policy runs once. |
/// | `restoring`  | Mains back; volumes the guard unmounted are being remounted. |
///
/// Force is used for every unmount, because `smbd` dissents a plain unmount of any volume
/// with a share point on it. Force only overrides dissenters and open files; the filesystem is
/// flushed completely either way. The courtesy to apps is the *wait* in the soft phase, not a
/// gentler unmount.
public final class OutageGuard {

    public enum Phase: String, Equatable, Sendable {
        case line, holding, soft, hard, safe, restoring

        public var title: String {
            switch self {
            case .line: return "Line power"
            case .holding: return "On battery"
            case .soft: return "Closing apps"
            case .hard: return "Unmounting"
            case .safe: return "Drives safe"
            case .restoring: return "Remounting"
            }
        }

        /// True for every phase that belongs to an outage in progress.
        public var isOutage: Bool { self != .line && self != .restoring }
    }

    public struct VolumeReport: Equatable, Sendable {
        public var volume: VolumeState
        /// Apps that hold files and are not on the never-quit list: what the soft phase waits for.
        public var appHolders: [Holder]
        /// Everything else holding files: daemons, never-quit apps. Logged, never waited for.
        public var otherHolders: [Holder]
        public var inFlight: Bool
        public var unmountedByGuard: Bool
        public var lastError: String?
        /// When the holders were last looked up (nil: never).
        public var holdersAt: TimeInterval?
    }

    public struct Status: Equatable, Sendable {
        public var phase: Phase = .line
        public var upsPresent = false
        public var reading = UPSReading.absent()
        public var outageStart: TimeInterval?
        /// Seconds on battery so far (0 outside an outage).
        public var elapsed: TimeInterval = 0
        /// Countdown to the soft stage while holding, to the hard limit until safe.
        public var untilSoft: TimeInterval?
        public var untilHard: TimeInterval?
        public var volumes: [VolumeReport] = []
        /// App names the soft phase is waiting for.
        public var waitingFor: [String] = []
        public var postponedBy: TimeInterval = 0
        public var quitAppsThisOutage = true
        /// Duration of the most recent completed outage, if any.
        public var lastOutageSeconds: TimeInterval?
        public var hardReasons: [String] = []
    }

    public private(set) var status = Status()
    public var policy: Policy { didSet { policy = policy.normalized } }
    /// Fired after every tick and after every completed action, on the ticking thread.
    public var onChange: (() -> Void)?

    private let env: GuardEnvironment
    private var lastReading = UPSReading.absent()
    private var outageStart: TimeInterval?
    private var phase: Phase = .line
    private var asked: [String: TimeInterval] = [:]
    private var inFlight: Set<String> = []
    private var unmountedByGuard: [String: VolumeState] = [:]
    private var volumeErrors: [String: String] = [:]
    private var holders: [String: (at: TimeInterval, list: [Holder])] = [:]
    private var lastMountAttempt: [String: TimeInterval] = [:]
    private var userHard = false
    private var postponed: TimeInterval = 0
    private var noQuitThisOutage = false
    private var afterSafeDone = false
    private var awakeHeld = false
    private var lastProgressLog: TimeInterval = 0
    private var lastWaiting: [String] = []
    private var lastOutageSeconds: TimeInterval?
    private var hardReasons: [String] = []
    /// How often a failed remount is retried.
    static let mountRetry: TimeInterval = 30
    /// Re-entrancy: an unmount or mount completion that lands while a tick is running (the
    /// fakes, and Disk Arbitration on a fast path) asks for one more evaluation at the end of
    /// the tick rather than nesting one inside it.
    private var ticking = false
    private var retick = false

    public init(environment: GuardEnvironment, policy: Policy) {
        self.env = environment
        self.policy = policy.normalized
    }

    // MARK: Ticking

    /// Feed the latest reading. Call on every power-source change, every volume change, and
    /// on a timer (a couple of seconds on battery, tens of seconds on line power).
    public func tick(_ reading: UPSReading) {
        if ticking { retick = true; return }
        ticking = true
        defer { ticking = false }
        var rounds = 0
        repeat {
            retick = false
            evaluate(reading)
            rounds += 1
        } while retick && rounds < 4
    }

    private func evaluate(_ reading: UPSReading) {
        let now = env.now
        lastReading = reading
        let volumes = env.protectedVolumes()
        let mounted = volumes.filter(\.isMounted)
        // A UPS that disappears mid-outage has almost certainly run its battery down and
        // switched off (the USB connection goes with it). That is the hardest of hard limits.
        let upsGone = !reading.present && outageStart != nil
        let inOutage = (reading.present && reading.onBattery) || upsGone

        if inOutage {
            if outageStart == nil { beginOutage(now: now, reading: reading, mounted: mounted) }
            let elapsed = now - (outageStart ?? now)
            if now - lastProgressLog >= 60 {
                lastProgressLog = now
                env.log("on battery \(Duration.text(elapsed)): \(describe(reading)); mounted: \(mounted.isEmpty ? "none" : mounted.map(\.name).joined(separator: ", "))")
            }
            if mounted.isEmpty && inFlight.isEmpty {
                if phase != .safe {
                    env.log(unmountedByGuard.isEmpty ? "nothing mounted to protect" : "every protected volume is unmounted")
                    phase = .safe
                }
                hold(false)
                maybeAfterSafe(elapsed: elapsed)
            } else {
                let usable = elapsed >= policy.ignoreReadingsSeconds
                var reasons: [String] = []
                if upsGone { reasons.append("the UPS has gone away (battery exhausted?)") }
                if userHard { reasons.append("unmount requested from the menu") }
                if elapsed >= policy.hardAfterSeconds + postponed { reasons.append("\(Duration.text(elapsed)) on battery") }
                if usable, let pct = reading.chargePercent, pct <= policy.hardAtPercent { reasons.append("charge at \(pct) %") }
                if usable, let rt = reading.runtimeSeconds, rt <= policy.hardAtRuntimeSeconds { reasons.append("runtime down to \(Duration.text(TimeInterval(rt)))") }
                if usable, reading.flags.contains(.shutdownImminent) { reasons.append("the UPS says shutdown is imminent") }
                hardReasons = reasons
                if !reasons.isEmpty {
                    if phase != .hard {
                        phase = .hard
                        refreshHolders(mounted, now: now)
                        env.log("hard limit (\(reasons.joined(separator: "; "))): unmounting \(mounted.map(\.name).joined(separator: ", ")) regardless of apps")
                        env.notify(title: "Unmounting now", body: "\(reasons.first ?? "Hard limit"). \(mounted.map(\.name).joined(separator: ", ")) unmounting regardless of open apps.")
                    }
                    for v in mounted where !inFlight.contains(v.uuid) { unmount(v) }
                } else if elapsed >= policy.graceSeconds + postponed {
                    let quitting = policy.quitApps && !noQuitThisOutage
                    if phase != .soft {
                        phase = .soft
                        env.log("grace period over (\(Duration.text(elapsed)) on battery): \(quitting ? "asking apps to quit, then unmounting" : "unmounting volumes no app is using (apps are not asked to quit)")")
                    }
                    refreshHolders(mounted, now: now)
                    var waiting: [String] = []
                    for v in mounted where !inFlight.contains(v.uuid) {
                        let apps = appHolders(v)
                        if quitting {
                            var askedNow: [String] = []
                            for h in apps where asked[h.appKey] == nil {
                                asked[h.appKey] = now
                                askedNow.append(h.shortName)
                                env.requestQuit(h)
                            }
                            if !askedNow.isEmpty {
                                env.log("asked to quit: \(askedNow.joined(separator: ", ")) (holding \(v.name))")
                                env.notify(title: "Closing apps", body: "Asked \(askedNow.joined(separator: ", ")) to quit so \(v.name) can unmount.")
                            }
                        }
                        if apps.isEmpty {
                            let others = otherHolders(v)
                            env.log("no app holds \(v.name)\(others.isEmpty ? "" : " (ignoring \(others.map(\.shortName).joined(separator: ", ")))"): unmounting")
                            unmount(v)
                        } else {
                            waiting += apps.map(\.shortName)
                        }
                    }
                    waiting = Array(Set(waiting)).sorted()
                    if waiting != lastWaiting {
                        if !waiting.isEmpty { env.log("waiting for \(waiting.joined(separator: ", ")) to quit before unmounting") }
                        lastWaiting = waiting
                    }
                } else {
                    phase = .holding
                }
            }
        } else {
            if outageStart != nil { endOutage(now: now, reading: reading) }
            hardReasons = []
            // Remount whatever we unmounted, now that mains is back and the disks are still here.
            for v in volumes where unmountedByGuard[v.uuid] != nil {
                if v.isMounted {
                    unmountedByGuard.removeValue(forKey: v.uuid)
                    volumeErrors.removeValue(forKey: v.uuid)
                    env.log("\(v.name) is mounted again")
                } else if v.isAttached, !inFlight.contains(v.uuid),
                          now - (lastMountAttempt[v.uuid] ?? -.infinity) >= Self.mountRetry {
                    lastMountAttempt[v.uuid] = now
                    mount(v)
                }
            }
            phase = inFlight.isEmpty ? .line : .restoring
        }
        publish(now: now, volumes: volumes)
    }

    // MARK: Owner actions

    /// The menu's "Unmount now": go straight to the hard limit.
    public func unmountNow() {
        guard outageStart != nil else { return }
        userHard = true
        env.log("owner asked for an immediate unmount")
        tick(lastReading)
    }

    /// Push the soft stage and the time-based hard limit out by `seconds`. The charge and
    /// runtime limits still apply: postponing cannot talk the battery into lasting longer.
    public func postpone(seconds: TimeInterval) {
        guard outageStart != nil else { return }
        postponed += seconds
        env.log("owner postponed by \(Duration.text(seconds)) (total \(Duration.text(postponed)))")
        tick(lastReading)
    }

    /// Leave the apps alone for this outage: volumes unmount only at the hard limit, or when
    /// their apps happen to let go.
    public func skipQuittingAppsThisOutage() {
        guard outageStart != nil else { return }
        noQuitThisOutage = true
        env.log("owner asked not to quit apps this outage")
        tick(lastReading)
    }

    /// Retry the remount of anything the guard unmounted, now.
    public func remountNow() {
        lastMountAttempt = [:]
        tick(lastReading)
    }

    /// Re-read who holds the protected volumes (for the menu), outside the phases that do it
    /// on their own.
    public func refreshHolders() {
        let now = env.now
        let volumes = env.protectedVolumes()
        refreshHolders(volumes.filter(\.isMounted), now: now)
        publish(now: now, volumes: volumes)
    }

    // MARK: Transitions

    private func beginOutage(now: TimeInterval, reading: UPSReading, mounted: [VolumeState]) {
        outageStart = now
        asked = [:]
        userHard = false
        postponed = 0
        noQuitThisOutage = false
        afterSafeDone = false
        lastWaiting = []
        lastProgressLog = now
        phase = .holding
        env.log("transfer to battery: \(describe(reading)); mounted: \(mounted.isEmpty ? "none" : mounted.map(\.name).joined(separator: ", "))")
        let what = mounted.isEmpty ? "No protected volume is mounted."
            : "\(mounted.map(\.name).joined(separator: ", ")) unmount\(mounted.count == 1 ? "s" : "") in \(Duration.text(policy.graceSeconds)) unless power returns."
        env.notify(title: "Power outage", body: "\(describeShort(reading)). \(what)")
        if !mounted.isEmpty { hold(true) }
    }

    private func endOutage(now: TimeInterval, reading: UPSReading) {
        let elapsed = now - (outageStart ?? now)
        lastOutageSeconds = elapsed
        env.log("outage over after \(Duration.text(elapsed)): \(reading.present ? "line power is back" : "no UPS seen")")
        env.notify(title: "Power restored", body: "After \(Duration.text(elapsed)). \(describeShort(reading))."
                   + (unmountedByGuard.isEmpty ? "" : " Remounting \(unmountedByGuard.values.map(\.name).sorted().joined(separator: ", "))."))
        hold(false)
        outageStart = nil
        asked = [:]
        lastWaiting = []
        lastMountAttempt = [:]
    }

    private func maybeAfterSafe(elapsed: TimeInterval) {
        guard !afterSafeDone, policy.afterSafe != .keepRunning else { return }
        // A blip short enough that nothing was going to be unmounted must not sleep the Mac
        // either: the after-safe action waits out the grace period like everything else.
        guard elapsed >= policy.graceSeconds + postponed else { return }
        afterSafeDone = true
        env.log("volumes are safe: \(policy.afterSafe.title.lowercased())")
        env.perform(policy.afterSafe)
    }

    private func hold(_ on: Bool) {
        guard on != awakeHeld else { return }
        awakeHeld = on
        env.setAwakeHold(on)
    }

    // MARK: Volumes

    private func refreshHolders(_ mounted: [VolumeState], now: TimeInterval) {
        for v in mounted { holders[v.uuid] = (now, env.holders(of: v)) }
        for k in holders.keys where !mounted.contains(where: { $0.uuid == k }) { holders.removeValue(forKey: k) }
    }

    private func appHolders(_ v: VolumeState) -> [Holder] {
        (holders[v.uuid]?.list ?? []).filter { $0.isApp && !policy.isNeverQuit($0) }
    }

    private func otherHolders(_ v: VolumeState) -> [Holder] {
        (holders[v.uuid]?.list ?? []).filter { !$0.isApp || policy.isNeverQuit($0) }
    }

    private func unmount(_ v: VolumeState) {
        inFlight.insert(v.uuid)
        env.unmount(v) { [weak self] result in
            guard let self else { return }
            self.inFlight.remove(v.uuid)
            switch result {
            case .success:
                self.unmountedByGuard[v.uuid] = v
                self.volumeErrors.removeValue(forKey: v.uuid)
                self.holders.removeValue(forKey: v.uuid)
                self.env.log("unmounted \(v.name) (\(v.bsdName ?? "?"))")
                self.env.notify(title: "\(v.name) unmounted", body: "Safe to lose power. The Mac keeps running on its own battery.")
            case .failure(let e):
                self.volumeErrors[v.uuid] = e.message
                self.env.log("unmount of \(v.name) failed: \(e.message)")
            }
            self.completed()
        }
    }

    private func mount(_ v: VolumeState) {
        inFlight.insert(v.uuid)
        env.mount(v) { [weak self] result in
            guard let self else { return }
            self.inFlight.remove(v.uuid)
            switch result {
            case .success:
                self.unmountedByGuard.removeValue(forKey: v.uuid)
                self.volumeErrors.removeValue(forKey: v.uuid)
                self.env.log("remounted \(v.name) (\(v.bsdName ?? "?"))")
                self.env.notify(title: "\(v.name) remounted", body: "Power is back and the volume is available again.")
            case .failure(let e):
                self.volumeErrors[v.uuid] = e.message
                self.env.log("remount of \(v.name) failed: \(e.message); retrying in \(Int(Self.mountRetry)) s")
            }
            self.completed()
        }
    }

    /// An action finished: look again straight away, so "safe" or "line" is reached the
    /// moment the last volume lands rather than on the next timer tick.
    private func completed() {
        if ticking { retick = true } else { tick(lastReading) }
    }

    // MARK: Status

    private func publish(now: TimeInterval, volumes: [VolumeState]) {
        var s = Status()
        s.phase = outageStart == nil ? (inFlight.isEmpty ? .line : .restoring) : phase
        s.upsPresent = lastReading.present
        s.reading = lastReading
        s.outageStart = outageStart
        s.elapsed = outageStart.map { now - $0 } ?? 0
        if let start = outageStart {
            let elapsed = now - start
            if phase == .holding { s.untilSoft = max(0, policy.graceSeconds + postponed - elapsed) }
            if phase != .safe { s.untilHard = max(0, policy.hardAfterSeconds + postponed - elapsed) }
        }
        s.volumes = volumes.map { v in
            VolumeReport(volume: v,
                         appHolders: v.isMounted ? appHolders(v) : [],
                         otherHolders: v.isMounted ? otherHolders(v) : [],
                         inFlight: inFlight.contains(v.uuid),
                         unmountedByGuard: unmountedByGuard[v.uuid] != nil,
                         lastError: volumeErrors[v.uuid],
                         holdersAt: holders[v.uuid]?.at)
        }
        s.waitingFor = lastWaiting
        s.postponedBy = postponed
        s.quitAppsThisOutage = policy.quitApps && !noQuitThisOutage
        s.lastOutageSeconds = lastOutageSeconds
        s.hardReasons = hardReasons
        status = s
        onChange?()
    }

    private func describe(_ r: UPSReading) -> String {
        guard r.present else { return "no UPS" }
        var parts: [String] = []
        if let n = r.name { parts.append(n) }
        parts.append(r.onBattery ? "on battery" : "on line")
        if let p = r.chargePercent { parts.append("\(p) %") }
        if let t = r.runtimeSeconds { parts.append("runtime \(Duration.text(TimeInterval(t)))") }
        if let w = r.loadWatts { parts.append("load \(Int(w.rounded())) W") }
        if let v = r.batteryVoltage { parts.append(String(format: "battery %.1f V", v)) }
        return parts.joined(separator: ", ")
    }

    private func describeShort(_ r: UPSReading) -> String {
        guard r.present else { return "No UPS seen" }
        var parts: [String] = []
        if let p = r.chargePercent { parts.append("UPS at \(p) %") }
        if let t = r.runtimeSeconds { parts.append("about \(Duration.text(TimeInterval(t))) left") }
        return parts.isEmpty ? "UPS on battery" : parts.joined(separator: ", ")
    }
}

/// "45 s", "2 min 05 s", "1 h 30 min": the one way durations are written everywhere.
public enum Duration {
    public static func text(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 {
            let sec = s % 60
            return sec == 0 ? "\(s / 60) min" : String(format: "%d min %02d s", s / 60, sec)
        }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(m) min"
    }

    /// "1:52" for a countdown in the menu bar, "12 min" above ten minutes.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 600 { return "\(s / 60) min" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
