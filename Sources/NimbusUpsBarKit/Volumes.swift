// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import DiskArbitration
import Foundation
import UpsGuardCore

/// Every external volume the Mac knows about, by volume UUID, kept current through Disk
/// Arbitration: disks appearing and disappearing, volumes mounting and unmounting. The
/// unmount and mount actions live here too, so the guard never shells out to `diskutil`.
///
/// "External" is Disk Arbitration's word: a mountable volume whose device is not internal and
/// is not a network share. The EFI and Apple_Boot helper partitions every GPT disk carries are
/// left out by their partition type, and disk images (which DA also calls external) by their
/// "Virtual Interface" protocol.
@MainActor
public final class VolumeRegistry {

    /// All external volumes seen since launch (plus the ones remembered from earlier runs),
    /// attached or not.
    public private(set) var volumes: [String: VolumeState] = [:]
    public var onChange: (() -> Void)?

    private let session: DASession
    private nonisolated static let efi = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    private nonisolated static let appleBoot = "426F6F74-0000-11AA-AA11-00306543ECAC"

    public init(remembered: [VolumeState]) {
        for v in remembered { volumes[v.uuid] = v }
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // Registering replays "appeared" for every disk already present, which is the initial
        // enumeration for free.
        DARegisterDiskAppearedCallback(session, kDADiskDescriptionMatchVolumeMountable.takeUnretainedValue(), { disk, ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated { Unmanaged<VolumeRegistry>.fromOpaque(ctx).takeUnretainedValue().update(disk, gone: false) }
        }, ctx)
        DARegisterDiskDisappearedCallback(session, kDADiskDescriptionMatchVolumeMountable.takeUnretainedValue(), { disk, ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated { Unmanaged<VolumeRegistry>.fromOpaque(ctx).takeUnretainedValue().update(disk, gone: true) }
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(session, kDADiskDescriptionMatchVolumeMountable.takeUnretainedValue(), kDADiskDescriptionWatchVolumePath.takeUnretainedValue(), { disk, _, ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated { Unmanaged<VolumeRegistry>.fromOpaque(ctx).takeUnretainedValue().update(disk, gone: false) }
        }, ctx)
    }

    /// The volumes currently mounted, for the menu.
    public var mounted: [VolumeState] { sorted.filter(\.isMounted) }
    public var sorted: [VolumeState] {
        volumes.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func update(_ disk: DADisk, gone: Bool) {
        guard let d = DADiskCopyDescription(disk) as? [String: Any] else { return }
        guard let state = VolumeRegistry.state(from: d) else { return }
        if gone {
            guard var v = volumes[state.uuid] else { return }
            v.isAttached = false
            v.bsdName = nil
            v.mountPoint = nil
            volumes[state.uuid] = v
        } else {
            volumes[state.uuid] = state
        }
        onChange?()
    }

    /// Which volumes the guard protects (and the menu and the Inspector list). With every
    /// external volume protected, only the attached ones: a drive seen once and since ejected
    /// is remembered for the Settings checklist, nothing more. With a chosen few, those, attached
    /// or not, so a chosen drive that is missing shows as missing.
    public nonisolated static func protects(_ v: VolumeState, allExternal: Bool, selected: Set<String>) -> Bool {
        allExternal ? v.isAttached : selected.contains(v.uuid)
    }

    /// A remembered volume worth keeping: not a disk image (remembered before they were
    /// filtered out, the iOS Simulator's runtime images among them).
    public nonisolated static func keepRemembered(detail: String) -> Bool {
        !detail.contains("Virtual Interface")
    }

    /// A `VolumeState` for an external, mountable volume; nil for everything else.
    public nonisolated static func state(from d: [String: Any]) -> VolumeState? {
        guard let uuid = volumeUUID(d[kDADiskDescriptionVolumeUUIDKey as String]) else { return nil }
        if (d[kDADiskDescriptionDeviceInternalKey as String] as? Bool) == true { return nil }
        if (d[kDADiskDescriptionVolumeNetworkKey as String] as? Bool) == true { return nil }
        if (d[kDADiskDescriptionVolumeMountableKey as String] as? Bool) != true { return nil }
        if let content = d[kDADiskDescriptionMediaContentKey as String] as? String, content == efi || content == appleBoot { return nil }
        // Disk images and simulator volumes are "external" to Disk Arbitration but live on the
        // internal SSD; losing mains does nothing to them.
        if let proto = d[kDADiskDescriptionDeviceProtocolKey as String] as? String, proto == "Virtual Interface" { return nil }
        if let model = d[kDADiskDescriptionDeviceModelKey as String] as? String, model.trimmingCharacters(in: .whitespaces) == "Disk Image" { return nil }
        let name = d[kDADiskDescriptionVolumeNameKey as String] as? String ?? "Untitled"
        let bsd = d[kDADiskDescriptionMediaBSDNameKey as String] as? String
        let path = (d[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
        var parts: [String] = []
        if let model = (d[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty { parts.append(model) }
        if let proto = d[kDADiskDescriptionDeviceProtocolKey as String] as? String { parts.append(proto) }
        if let kind = d[kDADiskDescriptionVolumeKindKey as String] as? String { parts.append(kind.uppercased()) }
        if let size = d[kDADiskDescriptionMediaSizeKey as String] as? Int64 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .decimal))
        }
        return VolumeState(uuid: uuid, name: name, bsdName: bsd, mountPoint: path, isAttached: true, detail: parts.joined(separator: " · "))
    }

    /// The volume UUID as a string: a CFUUID from Disk Arbitration, or a string (fixtures).
    /// Checked by type id rather than cast, because a force cast on data from the OS is how
    /// a daemon dies at 3 a.m.
    nonisolated static func volumeUUID(_ ref: Any?) -> String? {
        guard let ref else { return nil }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        let cf = ref as CFTypeRef
        guard CFGetTypeID(cf) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(nil, (cf as! CFUUID)) as String?
    }

    // MARK: Actions

    /// Unmount with force. `smbd` dissents a plain unmount of any volume with a share point on
    /// it, even with no client connected; force overrides dissenters and open files and still
    /// flushes the filesystem. Completes on the main thread.
    public func unmount(_ v: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        guard let bsd = v.bsdName, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
            completion(.failure(GuardError("\(v.name) is not attached"))); return
        }
        let box = Unmanaged.passRetained(CallbackBox(completion))
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionForce), { _, dissenter, ctx in
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx!).takeRetainedValue()
            box.completion(VolumeRegistry.result(dissenter))
        }, box.toOpaque())
    }

    public func mount(_ v: VolumeState, completion: @escaping (Result<Void, GuardError>) -> Void) {
        guard let bsd = v.bsdName, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
            completion(.failure(GuardError("\(v.name) is not attached"))); return
        }
        // Make sure the device we are about to mount is still the volume we unmounted: disk
        // numbers get reused when enclosures come and go.
        if let d = DADiskCopyDescription(disk) as? [String: Any], let s = VolumeRegistry.state(from: d), s.uuid != v.uuid {
            completion(.failure(GuardError("\(bsd) is now \(s.name), not \(v.name)"))); return
        }
        let box = Unmanaged.passRetained(CallbackBox(completion))
        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, ctx in
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx!).takeRetainedValue()
            box.completion(VolumeRegistry.result(dissenter))
        }, box.toOpaque())
    }

    private static func result(_ dissenter: DADissenter?) -> Result<Void, GuardError> {
        guard let dissenter else { return .success(()) }
        let status = DADissenterGetStatus(dissenter)
        if let s = DADissenterGetStatusString(dissenter) as String?, !s.isEmpty { return .failure(GuardError(s)) }
        let known: [Int: String] = [
            0xF8DA0001: "error", 0xF8DA0002: "busy (a process still holds it)", 0xF8DA0003: "bad argument",
            0xF8DA0004: "exclusive access held", 0xF8DA0005: "no resources", 0xF8DA0006: "not found",
            0xF8DA0007: "not mounted", 0xF8DA0008: "not permitted", 0xF8DA0009: "not privileged",
            0xF8DA000A: "not ready", 0xF8DA000B: "not writable", 0xF8DA000C: "unsupported",
        ]
        return .failure(GuardError(known[Int(UInt32(bitPattern: status))] ?? String(format: "Disk Arbitration status 0x%08X", UInt32(bitPattern: status))))
    }

    private final class CallbackBox {
        let completion: (Result<Void, GuardError>) -> Void
        init(_ c: @escaping (Result<Void, GuardError>) -> Void) { completion = c }
    }
}
