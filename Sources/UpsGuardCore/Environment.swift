// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Everything the guard touches in the outside world, behind one protocol so the state
/// machine can be driven by fakes: a fake clock, fake volumes, fake holders, actions that
/// only log. The app's real implementation lives in `RealEnvironment`; the rehearsal wraps it
/// in `RehearsalEnvironment`, which never performs anything.
///
/// Every call happens on the thread the guard is ticked on (the main thread in the app).
/// Unmount and mount report back through a completion, which may run later; the guard treats
/// the volume as "in flight" until it does.
public protocol GuardEnvironment: AnyObject {
    /// Monotonic seconds. Never wall-clock time: NTP steps backwards and would stall a deadline.
    var now: TimeInterval { get }
    /// The volumes under protection, attached or not, mounted or not.
    func protectedVolumes() -> [VolumeState]
    /// Processes with files open on the volume, right now.
    func holders(of volume: VolumeState) -> [Holder]
    /// Ask an app to quit, as its Quit menu item would. Never kills.
    func requestQuit(_ holder: Holder)
    /// Unmount with force. Force only overrides dissenters (`smbd` dissents any volume with a
    /// share point on it) and open files; the filesystem is still flushed completely.
    func unmount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void)
    func mount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void)
    /// Keep the Mac from idle-sleeping while an unmount is pending (the "UPS Power" pmset
    /// profile sleeps it after a minute).
    func setAwakeHold(_ on: Bool)
    func notify(title: String, body: String)
    /// Sleep or shut down the Mac, per policy, once the volumes are safe.
    func perform(_ action: Policy.MacAction)
    func log(_ line: String)
}

/// A rehearsal: the guard runs against the real volumes and the real holders but changes
/// nothing. Time runs `speed` times faster so a five-minute outage plays out in a minute. An
/// unmount flips a shadow copy of the volume; an app asked to quit is treated as gone a few
/// simulated seconds later, so the soft path can be seen end to end.
public final class RehearsalEnvironment: GuardEnvironment {
    private let base: GuardEnvironment
    private let speed: Double
    private let start: TimeInterval
    private var shadow: [String: VolumeState] = [:]
    private var askedAt: [String: TimeInterval] = [:]
    /// How long a rehearsed app takes to quit, in simulated seconds.
    public var pretendQuitSeconds: TimeInterval = 5
    public private(set) var actions: [String] = []

    public init(base: GuardEnvironment, speed: Double) {
        self.base = base
        self.speed = max(1, speed)
        self.start = base.now
        for v in base.protectedVolumes() { shadow[v.uuid] = v }
    }

    public var now: TimeInterval { start + (base.now - start) * speed }

    public func protectedVolumes() -> [VolumeState] {
        // Volumes that appear during the rehearsal are picked up; ones we "unmounted" stay so.
        for v in base.protectedVolumes() where shadow[v.uuid] == nil { shadow[v.uuid] = v }
        return shadow.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func holders(of volume: VolumeState) -> [Holder] {
        guard let real = shadow[volume.uuid], real.isMounted else { return [] }
        return base.holders(of: real).filter { h in
            guard let t = askedAt[h.appKey] else { return true }
            return now - t < pretendQuitSeconds
        }
    }

    public func requestQuit(_ holder: Holder) {
        askedAt[holder.appKey] = now
        record("would ask \(holder.shortName) to quit")
    }

    public func unmount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        record("would force-unmount \(volume.name) (\(volume.bsdName ?? "not attached"))")
        if var v = shadow[volume.uuid] { v.mountPoint = nil; shadow[volume.uuid] = v }
        completion(.success(()))
    }

    public func mount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        record("would remount \(volume.name)")
        if var v = shadow[volume.uuid] { v.mountPoint = "/Volumes/\(v.name)"; shadow[volume.uuid] = v }
        completion(.success(()))
    }

    public func setAwakeHold(_ on: Bool) { record(on ? "would hold the Mac awake" : "would release the sleep hold") }

    public func notify(title: String, body: String) { base.notify(title: "Rehearsal: \(title)", body: body) }

    public func perform(_ action: Policy.MacAction) {
        record("would \(action.title.lowercased())")
    }

    public func log(_ line: String) { base.log("[rehearsal] " + line) }

    private func record(_ s: String) {
        actions.append(s)
        log("REHEARSAL: " + s)
    }
}

/// A drill: real quits, real unmounts and remounts, driven by a simulated UPS at `speed`.
/// The one thing it never does is sleep or shut down the Mac.
public final class DrillEnvironment: GuardEnvironment {
    private let base: GuardEnvironment
    private let speed: Double
    private let start: TimeInterval

    public init(base: GuardEnvironment, speed: Double) {
        self.base = base
        self.speed = max(1, speed)
        self.start = base.now
    }

    public var now: TimeInterval { start + (base.now - start) * speed }
    public func protectedVolumes() -> [VolumeState] { base.protectedVolumes() }
    public func holders(of volume: VolumeState) -> [Holder] { base.holders(of: volume) }
    public func requestQuit(_ holder: Holder) { base.requestQuit(holder) }
    public func unmount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        base.unmount(volume, completion: completion)
    }
    public func mount(_ volume: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        base.mount(volume, completion: completion)
    }
    public func setAwakeHold(_ on: Bool) { base.setAwakeHold(on) }
    public func notify(title: String, body: String) { base.notify(title: "Drill: \(title)", body: body) }
    public func perform(_ action: Policy.MacAction) {
        base.log("[drill] not performing \"\(action.title)\" during a drill")
    }
    public func log(_ line: String) { base.log("[drill] " + line) }
}
