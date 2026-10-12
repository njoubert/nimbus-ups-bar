// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The outage state machine. Fed one `UPSReading` per tick, it decides what to do with the
/// protected volumes and does it through the `GuardEnvironment`. It knows nothing about
/// IOKit, Disk Arbitration or AppKit, which is what makes it testable with fakes.
///
/// Phases, measured from the first reading on battery. Each stage begins on its own
/// `Trigger` in the policy (time on battery, runtime left, charge; whichever comes first):
///
/// | Phase        | Meaning |
/// |--------------|---------|
/// | `line`       | Mains present (or no UPS at all). Nothing to do. |
/// | `holding`    | On battery before the soft trigger. Notified, Mac held awake, nothing touched. |
/// | `soft`       | Soft trigger met. Apps holding files are asked to quit; a volume unmounts as soon as no app holds it. |
/// | `hard`       | Hard trigger met (or the UPS vanished, the owner asked, or the power-down trigger needs the volumes off). Every volume is force-unmounted regardless. |
/// | `safe`       | Every protected volume is unmounted. Sleep hold released; the power-down action runs once if due. |
/// | `restoring`  | Mains back; volumes the guard unmounted are being remounted. |
///
/// The power-down trigger (sleep or shut down) is a stage of its own: when it fires the
/// volumes are forced first and the action runs once they are safe. A shutdown also runs
/// `powerDownWait` later if one will not come off (the Mac unmounts what it can on the way
/// down); a sleep never does, because a sleeping Mac leaves the volume mounted when the UPS
/// dies, so the guard stays awake and keeps retrying. A UPS that goes missing on line power,
/// under the `unmount` policy, starts a *blind* outage: the volumes are forced and come back
/// once the UPS does.
///
/// The forced unmount has two backstops beyond its trigger: the UPS's own low-battery flags
/// (shutdown imminent, below its charge limit, its runtime limit expired), and, for a trigger
/// with no time condition, `Policy.hardStandIn` on battery once the UPS reports none of the
/// figures the trigger needs. Once begun, the hard stage stays begun for the outage, as the
/// soft stage does: a gauge bouncing across the limit does not pause the retries.
///
/// Force is used for every unmount, because `smbd` dissents a plain unmount of any volume
/// with a share point on it. Force only overrides dissenters and open files; the filesystem is
/// flushed completely either way. The courtesy to apps is the *wait* in the soft phase, not a
/// gentler unmount.
///
/// Two debounces keep a flaky signal from undoing the work: line power has to stay back for
/// `Policy.lineStableSeconds` before the outage is over (a brownout transfers every few
/// seconds), and the UPS has to be missing for `Policy.upsGoneSeconds` before it counts as gone
/// (a USB re-enumeration drops it for a moment). In both windows the limits are
/// judged against the last reading taken on battery. While the power is back but not yet
/// trusted, no stage begins on time (a stage due then begins if the power fails again);
/// charge and runtime still count. A reading taken inside `ignoreReadingsSeconds` stays
/// ignored however long the clock then runs.
///
/// A copy relaunched mid-outage picks up where the last one stopped through `resume`: the
/// outage's clock, the volumes it had unmounted (so they are remounted), and the apps it had
/// asked (so they are not asked again). `carryover` is what the running copy saves for that.
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
        /// Countdowns to the time conditions of the soft trigger (while holding) and the hard
        /// trigger (until safe); nil when that trigger has no time condition.
        public var untilSoft: TimeInterval?
        public var untilHard: TimeInterval?
        /// Countdown to the power-down trigger's time condition, while it has not run.
        public var untilPowerDown: TimeInterval?
        /// The power-down trigger has fired; the action runs once the volumes are safe.
        public var powerDownPending = false
        /// The UPS went missing on line power and the policy unmounted the volumes for it.
        public var blind = false
        /// Countdown to the first volume being forced because its apps did not quit in time
        /// (soft stage, only with a quit timeout in the policy).
        public var untilQuitTimeout: TimeInterval?
        /// The sooner of `untilHard` and `untilQuitTimeout`: when something is next forced.
        public var untilForce: TimeInterval? { [untilHard, untilQuitTimeout].compactMap { $0 }.min() }
        /// Line power is back; the outage stands down when this reaches zero, unless it fails again.
        public var untilStandDown: TimeInterval?
        /// The UPS has not been seen for this long (nil: it is there, or was never seen).
        public var upsAbsentFor: TimeInterval?
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
    /// Set before the first tick by an app that was relaunched mid-outage: the outage it
    /// finds itself in began this long ago, so the clock and the limits carry on from there
    /// rather than from zero. Consumed by the next transfer, dropped by the next line reading.
    public var resumeElapsed: TimeInterval?

    /// What a copy started after this one needs to carry on: the volumes this guard unmounted
    /// and has not remounted yet (whether or not an outage is still on), and, for the outage
    /// under way, the apps asked to quit (with when) and what the owner did and the guard
    /// already did (postponed, apps not to be quit, Unmount Now, slept or shut down). Empty
    /// when there is nothing unfinished.
    public var carryover: Carryover {
        var c = Carryover()
        for (uuid, v) in unmountedByGuard { c.unmounted[uuid] = v.name }
        if let start = outageStart {
            for (key, at) in asked { c.askedAt[key] = at - start }
            c.postponed = postponed
            c.noQuit = noQuitThisOutage
            c.unmountRequested = userHard
            c.poweredDown = powerDone
        } else if let r = resumeOutage {
            // Resumed but not ticked yet: still the previous copy's.
            c.askedAt = r.askedAt
            c.postponed = r.postponed
            c.noQuit = r.noQuit
            c.unmountRequested = r.unmountRequested
            c.poweredDown = r.poweredDown
        }
        return c
    }

    /// Before the first tick of a relaunched copy: the outage began `elapsed` ago (nil: not
    /// known to be in one), and `carryover` is what the previous copy left unfinished. The
    /// volumes are remounted once the power is back and trusted, as if this copy had unmounted
    /// them. The rest belongs to the outage: kept if it is resumed, dropped otherwise. A first
    /// reading on line power resumes it too, into a fresh stand-down: the previous copy may
    /// have stopped mid-stand-down, and a brownout must not get a remount for free.
    public func resume(elapsed: TimeInterval?, carryover: Carryover) {
        resumeElapsed = elapsed
        resumeOutage = carryover
        for (uuid, name) in carryover.unmounted where unmountedByGuard[uuid] == nil {
            unmountedByGuard[uuid] = VolumeState(uuid: uuid, name: name, isAttached: false)
        }
    }

    private let env: GuardEnvironment
    private var lastReading = UPSReading.absent()
    private var lastBatteryReading = UPSReading.absent()
    /// When `lastBatteryReading` was taken: a reading is usable only if it was taken after
    /// `ignoreReadingsSeconds`, however long the outage then goes on.
    private var lastBatteryAt: TimeInterval = 0
    private var resumeOutage: Carryover?
    private var outageStart: TimeInterval?
    private var phase: Phase = .line
    private var softSince: TimeInterval?
    private var lineSince: TimeInterval?
    private var absentSince: TimeInterval?
    private var asked: [String: TimeInterval] = [:]
    private var inFlight: Set<String> = []
    private var unmountedByGuard: [String: VolumeState] = [:]
    private var volumeErrors: [String: String] = [:]
    private var holders: [String: (at: TimeInterval, list: [Holder])] = [:]
    private var lastMountAttempt: [String: TimeInterval] = [:]
    private var lastUnmountFailure: [String: TimeInterval] = [:]
    private var lastUnmountSuccess: [String: TimeInterval] = [:]
    private var userHard = false
    private var postponed: TimeInterval = 0
    private var noQuitThisOutage = false
    private var powerDone = false
    private var powerSince: TimeInterval?
    private var hardSince: TimeInterval?
    /// Why the hard stage began: what it says while the reason itself comes and goes.
    private var hardBecause: [String] = []
    /// The sleep was refused once this outage because a volume would not come off.
    private var sleepRefusalSaid = false
    /// The forced unmount has no time condition and the UPS reports none of its figures.
    private var hardStandingIn = false
    private var blind = false
    private var everSeen = false
    private var goneOnLineHandled = false
    private var awakeHeld = false
    private var lastProgressLog: TimeInterval = 0
    private var lastWaiting: [String] = []
    private var lastOutageSeconds: TimeInterval?
    private var hardReasons: [String] = []
    /// How often a failed remount is retried.
    public static let mountRetry: TimeInterval = 30
    /// How long a volume whose unmount failed is left alone before the next attempt, and how
    /// long a volume reported mounted right after a successful unmount is trusted to be on its
    /// way out (Disk Arbitration's description change can trail the completion).
    public static let unmountRetry: TimeInterval = 10
    /// How long after the power-down trigger fires the action runs anyway when a volume will
    /// not unmount: the Mac shutting down unmounts what it can itself; waiting on would only
    /// spend the battery.
    public static let powerDownWait: TimeInterval = 60
    /// Re-entrancy: an unmount or mount completion that lands while a tick is running (the
    /// fakes, and Disk Arbitration on a fast path) asks for one more evaluation at the end of
    /// the tick rather than nesting one inside it. Four rounds is the ceiling; the timer
    /// brings the next look soon enough.
    public static let maxRounds = 4
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
        } while retick && rounds < Self.maxRounds
    }

    private func evaluate(_ reading: UPSReading) {
        let now = env.now
        lastReading = reading
        let volumes = env.protectedVolumes()
        let mounted = volumes.filter(\.isMounted)

        // What kind of reading is this, in the light of the outage so far?
        let onBattery = reading.present && reading.onBattery
        let onLine = reading.present && !reading.onBattery
        if reading.present {
            if absentSince != nil, outageStart == nil, goneOnLineHandled { env.log("the UPS is back") }
            absentSince = nil
            everSeen = true
            goneOnLineHandled = false
        } else if everSeen, absentSince == nil { absentSince = now }
        if onBattery {
            lastBatteryReading = reading
            lastBatteryAt = now
            blind = false
            if let since = lineSince { env.log("line power failed again after \(Duration.text(now - since))") }
            lineSince = nil
        }
        // A UPS that disappears mid-outage has almost certainly run its battery down and
        // switched off (the USB connection goes with it): the hardest of hard limits, once it
        // has been gone long enough not to be a USB re-enumeration.
        let absentFor = absentSince.map { now - $0 }
        let gone = !reading.present && (absentFor ?? 0) >= policy.upsGoneSeconds
        // Missing on line power: say so once, and under the `unmount` policy start a blind
        // outage, so the volumes come off now rather than in an outage nobody will see.
        if gone, outageStart == nil, !goneOnLineHandled, policy.upsGoneOnLine != .nothing {
            goneOnLineHandled = true
            let what = "No word from the UPS for \(Duration.text(absentFor ?? 0)): a power cut now would go unnoticed. Check its USB cable."
            env.log("the UPS has not been seen for \(Duration.text(absentFor ?? 0)) on line power")
            if policy.upsGoneOnLine == .unmount {
                blind = true
                beginOutage(now: now, reading: reading, mounted: mounted)
            } else {
                env.notify(title: "UPS not seen", body: what)
            }
        }
        // Relaunched while the previous copy was in an outage, and the power is back: resume
        // the outage so it stands down (and remounts) only once the power has stayed back.
        if outageStart == nil, resumeElapsed != nil, onLine { beginOutage(now: now, reading: reading, mounted: mounted) }
        let upsGone = outageStart != nil && gone
        let absentBlip = outageStart != nil && !reading.present && !gone
        // Line power back: the outage stands down only once it has stayed back long enough.
        var standingDown = false
        if outageStart != nil, onLine {
            if lineSince == nil {
                lineSince = now
                env.log("line power is back; standing down in \(Duration.text(policy.lineStableSeconds)) unless it fails again")
            }
            standingDown = now - (lineSince ?? now) < policy.lineStableSeconds
        }
        let inOutage = onBattery || upsGone || absentBlip || standingDown

        if inOutage {
            if outageStart == nil { beginOutage(now: now, reading: reading, mounted: mounted) }
            let start = outageStart ?? now
            let elapsed = now - start
            // In a flap or a blip the limits are judged against the last reading on battery,
            // and that reading counts only if it was taken after the readings stopped being
            // ignored: a 10 s blip of junk must not be judged once the clock passes 15 s.
            let judged = onBattery ? reading : lastBatteryReading
            let judgedAt = onBattery ? now : lastBatteryAt
            if now - lastProgressLog >= 60 {
                lastProgressLog = now
                env.log("on battery \(Duration.text(elapsed)): \(describe(reading)); mounted: \(mounted.isEmpty ? "none" : mounted.map(\.name).joined(separator: ", "))")
            }
            let usable = judgedAt - start >= policy.ignoreReadingsSeconds
            // Power back but not yet trusted: no stage begins on time meanwhile.
            let countTime = !standingDown
            var reasons = policy.hardAt.reasons(elapsed: elapsed, postponed: postponed, reading: judged, usable: usable, countTime: countTime)
            if upsGone {
                if blind { reasons.insert("the UPS has not been seen for \(Duration.text(absentFor ?? 0)) on line power", at: 0) }
                else if policy.upsGoneInOutage == .forceUnmount { reasons.insert("the UPS has gone away (battery exhausted?)", at: 0) }
            }
            if userHard { reasons.append("unmount requested from the menu") }
            // The UPS's own alarms, whatever the policy's figures say.
            if usable, judged.flags.contains(.shutdownImminent) { reasons.append("the UPS says shutdown is imminent") }
            if usable, judged.flags.contains(.belowCapacityLimit) {
                reasons.append("the UPS says its charge is below its own low-battery limit" + (judged.lowChargeLimitPercent.map { " (\($0) %)" } ?? ""))
            }
            if usable, judged.flags.contains(.runtimeLimitExpired) {
                reasons.append("the UPS says its runtime is below its own low-battery limit" + (judged.lowRuntimeLimitSeconds.map { " (\(Duration.text(TimeInterval($0))))" } ?? ""))
            }
            // No time condition and nothing to judge the others by (a UPS reporting neither
            // figure, or one gone for good while carrying on): the stand-in time counts.
            hardStandingIn = policy.hardAt.cannotJudge(upsGone ? .absent() : judged)
            if hardStandingIn, countTime, elapsed >= Policy.hardStandIn + postponed {
                reasons.append("\(Duration.text(elapsed)) on battery with no runtime or charge figure from the UPS")
            }
            let softReasons = policy.softAt.reasons(elapsed: elapsed, postponed: postponed, reading: judged, usable: usable, countTime: countTime)
            // An unmount stage is (or was) due: the condition for "power down once safe".
            let unmountDue = softSince != nil || hardSince != nil || !softReasons.isEmpty || !reasons.isEmpty
            if !blind, !standingDown, !powerDone, powerSince == nil {
                var down = policy.powerDownAt.reasons(elapsed: elapsed, postponed: postponed, reading: judged, usable: usable)
                if upsGone, policy.upsGoneInOutagePowersDown { down.append("the UPS has gone away") }
                if !down.isEmpty {
                    powerSince = now
                    env.log("power-down trigger (\(down.joined(separator: "; "))): \(policy.powerDownAction.verb) once the volumes are off")
                    if !mounted.isEmpty {
                        env.notify(title: "About to \(policy.powerDownAction.verb)", body: "\(down.first ?? "Power-down trigger"). Unmounting \(mounted.map(\.name).joined(separator: ", ")) first.")
                    }
                }
            }
            if powerSince != nil { reasons.append("about to \(policy.powerDownAction.verb)") }

            if mounted.isEmpty && inFlight.isEmpty {
                hardReasons = reasons.isEmpty && hardSince != nil ? hardBecause : reasons
                if phase != .safe {
                    env.log(unmountedByGuard.isEmpty ? "nothing mounted to protect" : "every protected volume is unmounted")
                    phase = .safe
                }
                hold(false)
                if !standingDown, powerSince != nil || (policy.powerDownWhenSafe && !blind && unmountDue) {
                    powerDown(because: powerSince != nil ? "the volumes are safe" : "the volumes are safe (power down once safe)")
                }
            } else {
                // Every tick, not just at the transfer: a volume mounted mid-outage, or one
                // that Disk Arbitration reports only after a relaunch, needs the hold too.
                hold(true)
                if let since = powerSince, now - since >= Self.powerDownWait, !standingDown {
                    let names = mounted.map(\.name).joined(separator: ", ")
                    if policy.powerDownAction == .shutDown {
                        // Shutting down unmounts what it can on the way; waiting on only spends the battery.
                        powerDown(because: "\(names) still mounted \(Duration.text(now - since)) after the trigger")
                    } else if !powerDone, !sleepRefusalSaid {
                        // Sleep unmounts nothing: the volume would still be mounted when the UPS
                        // dies, the one outcome this app exists to prevent.
                        sleepRefusalSaid = true
                        env.log("not sleeping: \(names) still mounted \(Duration.text(now - since)) after the trigger, and a sleeping Mac would leave it mounted when the UPS runs out; staying awake and retrying the unmount")
                    }
                }
                // Once begun, the hard stage stays begun: a charge gauge bouncing across the
                // limit must not pause the retries (the soft stage latches the same way).
                if !reasons.isEmpty || hardSince != nil {
                    let why = reasons.isEmpty ? hardBecause : reasons
                    hardReasons = why
                    if phase != .hard {
                        phase = .hard
                        if hardSince == nil { hardSince = now; hardBecause = reasons }
                        refreshHolders(mounted, now: now)
                        env.log("hard limit (\(why.joined(separator: "; "))): unmounting \(mounted.map(\.name).joined(separator: ", ")) regardless of apps")
                        env.notify(title: "Unmounting now", body: "\(why.first ?? "Hard limit"). \(mounted.map(\.name).joined(separator: ", ")) unmounting regardless of open apps.")
                    }
                    for v in mounted where canUnmount(v, now: now) { unmount(v) }
                } else if softSince != nil || !softReasons.isEmpty {
                    hardReasons = []
                    // Once the soft stage has begun it stays begun: a postponement moves the
                    // hard limit out, it does not un-ask the apps.
                    let quitting = policy.quitApps && !noQuitThisOutage
                    if phase != .soft {
                        phase = .soft
                        softSince = now
                        env.log("soft stage (\(softReasons.joined(separator: "; "))): \(quitting ? "asking apps to quit, then unmounting" : "unmounting volumes no app is using (apps are not asked to quit)")")
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
                            if canUnmount(v, now: now) {
                                let others = otherHolders(v)
                                env.log("no app holds \(v.name)\(others.isEmpty ? "" : " (ignoring \(others.map(\.shortName).joined(separator: ", ")))"): unmounting")
                                unmount(v)
                            }
                        } else if quitting, countTime, let timeout = policy.quitTimeoutSeconds, quitDeadline(for: apps, timeout: timeout) <= now {
                            // (The quit timeout is a time condition too: it waits while the power looks back.)
                            if canUnmount(v, now: now) {
                                let names = apps.map(\.shortName).sorted().joined(separator: ", ")
                                env.log("\(names) did not quit within \(Duration.text(timeout)) of being asked: unmounting \(v.name) anyway")
                                env.notify(title: "Unmounting \(v.name)", body: "\(names) did not quit within \(Duration.text(timeout)). Unmounting anyway.")
                                unmount(v)
                            }
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
                    hardReasons = []
                    phase = .holding
                }
            }
        } else {
            if outageStart != nil { endOutage(now: now, reading: reading) }
            resumeElapsed = nil
            resumeOutage = nil
            hardReasons = []
            // Remount whatever we unmounted, now that mains is back and the disks are still here.
            // Only with a UPS on line power in view: with none (a blind outage carried across a
            // relaunch, before this copy has seen the UPS) nothing would watch the volumes.
            let mainsSeen = reading.present && !reading.onBattery
            for v in volumes where unmountedByGuard[v.uuid] != nil && (mainsSeen || v.isMounted) {
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
        publish(now: now, volumes: volumes, standingDown: standingDown, absentFor: absentFor)
    }

    // MARK: Owner actions

    /// The menu's "Unmount now": go straight to the hard limit.
    public func unmountNow() {
        guard outageStart != nil else { return }
        userHard = true
        env.log("owner asked for an immediate unmount")
        tick(lastReading)
    }

    /// Push the time conditions of every trigger out by `seconds`. The charge and runtime
    /// conditions still apply: postponing cannot talk the battery into lasting longer.
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

    /// Re-read who holds the protected volumes (for the Inspector), outside the phases that do
    /// it on their own: on line power and while holding the guard never looks.
    public func refreshHolders() {
        let now = env.now
        let volumes = env.protectedVolumes()
        refreshHolders(volumes.filter(\.isMounted), now: now)
        let standingDown = outageStart != nil && lineSince.map { now - $0 < policy.lineStableSeconds } == true
        publish(now: now, volumes: volumes, standingDown: standingDown, absentFor: absentSince.map { now - $0 })
    }

    // MARK: Transitions

    private func beginOutage(now: TimeInterval, reading: UPSReading, mounted: [VolumeState]) {
        let resumed = resumeElapsed
        resumeElapsed = nil
        outageStart = now - (resumed ?? 0)
        asked = [:]
        userHard = false
        postponed = 0
        noQuitThisOutage = false
        powerDone = false
        // A resumed outage keeps what the previous copy and the owner did in it.
        if resumed != nil, let start = outageStart, let r = resumeOutage {
            for (key, s) in r.askedAt { asked[key] = start + s }
            postponed = r.postponed
            noQuitThisOutage = r.noQuit
            userHard = r.unmountRequested
            powerDone = r.poweredDown
        }
        resumeOutage = nil
        powerSince = nil
        hardSince = nil
        hardBecause = []
        sleepRefusalSaid = false
        softSince = nil
        lineSince = nil
        if reading.present { absentSince = nil }
        lastUnmountFailure = [:]
        lastUnmountSuccess = [:]
        lastWaiting = []
        lastProgressLog = now
        // Only a reading on battery is a battery reading (a resume can begin on line power).
        lastBatteryReading = reading.present && reading.onBattery ? reading : .absent()
        lastBatteryAt = now
        phase = .holding
        let names = mounted.map(\.name).joined(separator: ", ")
        let when = policy.softAt.onBatteryFor.map { " in \(Duration.text(max(0, $0 - (resumed ?? 0))))" } ?? (policy.softAt.isNever ? "" : " when \(policy.softAt.summary) is reached")
        let what = mounted.isEmpty ? "No protected volume is mounted."
            : "\(names) unmount\(mounted.count == 1 ? "s" : "")\(when) unless power returns."
        if blind {
            env.log("blind outage: the UPS is missing on line power; mounted: \(mounted.isEmpty ? "none" : names)")
            env.notify(title: "UPS not seen", body: "No word from the UPS for \(Duration.text(policy.upsGoneSeconds)). "
                       + (mounted.isEmpty ? "Nothing is mounted to protect." : "Unmounting \(names); they remount when it is back."))
        } else if let resumed, !(reading.present && reading.onBattery) {
            // Relaunched after the power came back: the outage stands down from here.
            env.log("resuming an outage that began \(Duration.text(resumed)) ago (relaunched mid-outage); the power is back, so it stands down unless the power fails again")
        } else if let resumed {
            env.log("resuming an outage that began \(Duration.text(resumed)) ago (relaunched mid-outage): \(describe(reading)); mounted: \(mounted.isEmpty ? "none" : mounted.map(\.name).joined(separator: ", "))")
            env.notify(title: "Power outage (resumed)", body: "On battery for \(Duration.text(resumed)) already. \(describeShort(reading)). \(what)")
        } else {
            env.log("transfer to battery: \(describe(reading)); mounted: \(mounted.isEmpty ? "none" : mounted.map(\.name).joined(separator: ", "))")
            env.notify(title: "Power outage", body: "\(describeShort(reading)). \(what)")
        }
    }

    private func endOutage(now: TimeInterval, reading: UPSReading) {
        let elapsed = now - (outageStart ?? now)
        lastOutageSeconds = elapsed
        env.log("outage over after \(Duration.text(elapsed)): \(blind ? "the UPS is back" : reading.present ? "line power is back" : "no UPS seen")")
        env.notify(title: blind ? "UPS back" : "Power restored", body: "After \(Duration.text(elapsed)). \(describeShort(reading))."
                   + (unmountedByGuard.isEmpty ? "" : " Remounting \(unmountedByGuard.values.map(\.name).sorted().joined(separator: ", "))."))
        hold(false)
        outageStart = nil
        softSince = nil
        lineSince = nil
        absentSince = nil
        blind = false
        powerSince = nil
        hardSince = nil
        hardBecause = []
        sleepRefusalSaid = false
        asked = [:]
        lastWaiting = []
        lastMountAttempt = [:]
        lastUnmountFailure = [:]
        lastUnmountSuccess = [:]
    }

    private func powerDown(because why: String) {
        guard !powerDone else { return }
        powerDone = true
        env.log("\(why): \(policy.powerDownAction.title.lowercased())")
        env.perform(policy.powerDownAction)
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

    /// When a volume held by `apps` is forced under the quit timeout: `timeout` after the
    /// last of them was asked. An app not asked yet (it just appeared) has no deadline.
    private func quitDeadline(for apps: [Holder], timeout: TimeInterval) -> TimeInterval {
        apps.map { asked[$0.appKey].map { $0 + timeout } ?? .infinity }.max() ?? .infinity
    }

    /// Not in flight, not within the backoff after a failure, and not just unmounted (the
    /// registry may report it mounted for a moment longer than the completion).
    private func canUnmount(_ v: VolumeState, now: TimeInterval) -> Bool {
        if inFlight.contains(v.uuid) { return false }
        if let f = lastUnmountFailure[v.uuid], now - f < Self.unmountRetry { return false }
        if let s = lastUnmountSuccess[v.uuid], now - s < Self.unmountRetry { return false }
        return true
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
                self.lastUnmountFailure.removeValue(forKey: v.uuid)
                self.lastUnmountSuccess[v.uuid] = self.env.now
                self.holders.removeValue(forKey: v.uuid)
                self.env.log("unmounted \(v.name) (\(v.bsdName ?? "?"))")
                self.env.notify(title: "\(v.name) unmounted", body: "Safe to lose power. The Mac keeps running on its own battery.")
            case .failure(let e):
                let first = self.lastUnmountFailure[v.uuid] == nil
                self.lastUnmountFailure[v.uuid] = self.env.now
                self.volumeErrors[v.uuid] = e.message
                self.env.log("unmount of \(v.name) failed: \(e.message); retrying every \(Int(Self.unmountRetry)) s")
                if first {
                    self.env.notify(title: "\(v.name) will not unmount", body: "\(e.message). Retrying every \(Int(Self.unmountRetry)) s; its files are still at risk.")
                }
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
                // Another Mac that had it mounted over SMB keeps a stale mount (Finder: "the
                // original item can't be found") until it ejects and connects again (2026-10-11).
                self.env.notify(title: "\(v.name) remounted", body: "Power is back and the volume is available again. Other computers that had it mounted over the network must eject it and connect again.")
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

    private func publish(now: TimeInterval, volumes: [VolumeState], standingDown: Bool, absentFor: TimeInterval?) {
        var s = Status()
        s.phase = outageStart == nil ? (inFlight.isEmpty ? .line : .restoring) : phase
        s.upsPresent = lastReading.present
        s.reading = lastReading
        s.outageStart = outageStart
        s.elapsed = outageStart.map { now - $0 } ?? 0
        if let start = outageStart {
            let elapsed = now - start
            if phase == .holding { s.untilSoft = policy.softAt.untilTime(elapsed: elapsed, postponed: postponed) }
            if phase != .safe {
                s.untilHard = policy.hardAt.untilTime(elapsed: elapsed, postponed: postponed)
                    ?? (hardStandingIn ? max(0, Policy.hardStandIn + postponed - elapsed) : nil)
            }
            if !powerDone, powerSince == nil, !blind { s.untilPowerDown = policy.powerDownAt.untilTime(elapsed: elapsed, postponed: postponed) }
            s.powerDownPending = powerSince != nil && !powerDone
            if standingDown, let since = lineSince { s.untilStandDown = max(0, policy.lineStableSeconds - (now - since)) }
            if phase == .soft, policy.quitApps, !noQuitThisOutage, let timeout = policy.quitTimeoutSeconds {
                let deadlines = volumes.filter(\.isMounted).map { appHolders($0) }.filter { !$0.isEmpty }.map { quitDeadline(for: $0, timeout: timeout) }
                if let next = deadlines.min(), next.isFinite { s.untilQuitTimeout = max(0, next - now) }
            }
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
        s.upsAbsentFor = absentFor
        s.blind = blind
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

/// What one copy of the app leaves for the next when it stops mid-outage or mid-remount (a
/// crash restart by the agent, an update, toggling Run in Background): saved by the app on
/// every change, handed to `OutageGuard.resume` at launch.
public struct Carryover: Equatable, Sendable, Codable {
    /// Volumes the guard unmounted and has not remounted: UUID → name.
    public var unmounted: [String: String]
    /// The outage under way: apps asked to quit, their `appKey` → seconds into the outage.
    public var askedAt: [String: TimeInterval]
    /// …the owner's Postpone, in total; "Don't Quit Apps This Outage"; "Unmount Now".
    public var postponed: TimeInterval
    public var noQuit: Bool
    public var unmountRequested: Bool
    /// …and the Mac was already put to sleep or shut down (once per outage).
    public var poweredDown: Bool

    public init(unmounted: [String: String] = [:], askedAt: [String: TimeInterval] = [:], postponed: TimeInterval = 0,
                noQuit: Bool = false, unmountRequested: Bool = false, poweredDown: Bool = false) {
        self.unmounted = unmounted
        self.askedAt = askedAt
        self.postponed = postponed
        self.noQuit = noQuit
        self.unmountRequested = unmountRequested
        self.poweredDown = poweredDown
    }

    public var isEmpty: Bool { self == Carryover() }

    /// Every field optional on the way in, so a carryover saved by an older build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(unmounted: try c.decodeIfPresent([String: String].self, forKey: .unmounted) ?? [:],
                  askedAt: try c.decodeIfPresent([String: TimeInterval].self, forKey: .askedAt) ?? [:],
                  postponed: try c.decodeIfPresent(TimeInterval.self, forKey: .postponed) ?? 0,
                  noQuit: try c.decodeIfPresent(Bool.self, forKey: .noQuit) ?? false,
                  unmountRequested: try c.decodeIfPresent(Bool.self, forKey: .unmountRequested) ?? false,
                  poweredDown: try c.decodeIfPresent(Bool.self, forKey: .poweredDown) ?? false)
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

    /// "1:52" for a countdown under ten minutes; above, whole minutes written as `text`
    /// writes them ("12 min", "1 h 30 min"), so the bar and the Inspector agree.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 600 { return text(TimeInterval(s / 60 * 60)) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The reverse of `text`, for the settings fields: "90", "90 s", "2 min", "1.5 min",
    /// "1 h 30 min", "1h30m", "2:30" (minutes:seconds). A bare number is seconds. Nil when
    /// anything in the string is not a duration.
    public static func parse(_ text: String) -> TimeInterval? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let m = parts[0], let s = parts[1], m >= 0, s >= 0, s < 60 else { return nil }
            return m * 60 + s
        }
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        func flush() -> Bool {
            guard !number.isEmpty, let n = Double(number), n >= 0 else { return false }
            switch unit {
            case "", "s", "sec", "secs", "second", "seconds": total += n
            case "m", "min", "mins", "minute", "minutes": total += n * 60
            case "h", "hr", "hrs", "hour", "hours": total += n * 3600
            default: return false
            }
            number = ""; unit = ""
            return true
        }
        for c in t {
            if c.isNumber || c == "." {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(c)
            } else if c.isLetter {
                guard !number.isEmpty else { return nil }
                unit.append(c)
            } else if c == " " {
                continue
            } else {
                return nil
            }
        }
        guard flush() else { return nil }
        return total
    }
}
