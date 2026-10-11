// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One look at the UPS, however it was obtained: the IOKit power-source entry macOS keeps for
/// it, the raw HID report behind that entry, or a simulated outage. Everything optional is
/// something a given source may not know; `present == false` means no UPS was found at all.
public struct UPSReading: Equatable, Sendable {
    public var present: Bool
    public var name: String?
    public var onBattery: Bool
    /// 0–100. Nil when the UPS gives no figure.
    public var chargePercent: Int?
    /// The UPS's own estimate of how long the battery lasts at the current load.
    public var runtimeSeconds: Int?
    /// Percent of the UPS's rated output, and the same as watts (percent × rated watts).
    public var loadPercent: Int?
    public var loadWatts: Double?
    public var ratedWatts: Double?
    public var ratedVA: Double?
    public var inputVoltage: Double?
    public var outputVoltage: Double?
    public var batteryVoltage: Double?
    public var batteryNominalVoltage: Double?
    public var flags: Flags
    /// The UPS's own low-battery limits: it declares the battery "low" at either of these.
    public var lowChargeLimitPercent: Int?
    public var lowRuntimeLimitSeconds: Int?
    public var warningChargeLimitPercent: Int?
    /// Result of the last battery self-test, in the UPS's words (`SelfTest`).
    public var selfTest: SelfTest?
    /// Line-voltage window outside which the UPS switches to battery.
    public var lowTransferVoltage: Double?
    public var highTransferVoltage: Double?
    public var serialNumber: String?
    public var manufacturer: String?
    /// Monotonic seconds when this reading was taken.
    public var timestamp: TimeInterval

    public struct Flags: OptionSet, Equatable, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let acPresent = Flags(rawValue: 1 << 0)
        public static let charging = Flags(rawValue: 1 << 1)
        public static let discharging = Flags(rawValue: 1 << 2)
        public static let fullyCharged = Flags(rawValue: 1 << 3)
        public static let belowCapacityLimit = Flags(rawValue: 1 << 4)
        public static let runtimeLimitExpired = Flags(rawValue: 1 << 5)
        public static let overload = Flags(rawValue: 1 << 6)
        public static let needsReplacement = Flags(rawValue: 1 << 7)
        public static let shutdownImminent = Flags(rawValue: 1 << 8)
        public static let boost = Flags(rawValue: 1 << 9)
        public static let buck = Flags(rawValue: 1 << 10)
    }

    /// The HID Power Device `Test` usage as CyberPower reports it (the NUT mapping, which is
    /// the one validated against real units).
    public enum SelfTest: Int, Equatable, Sendable, CaseIterable {
        case passed = 1, warning = 2, error = 3, aborted = 4, inProgress = 5, notRun = 6

        public var text: String {
            switch self {
            case .passed: return "passed"
            case .warning: return "done with a warning"
            case .error: return "failed"
            case .aborted: return "aborted"
            case .inProgress: return "in progress"
            case .notRun: return "not run"
            }
        }
    }

    public init(present: Bool, name: String? = nil, onBattery: Bool = false, chargePercent: Int? = nil,
                runtimeSeconds: Int? = nil, loadPercent: Int? = nil, loadWatts: Double? = nil,
                ratedWatts: Double? = nil, ratedVA: Double? = nil, inputVoltage: Double? = nil,
                outputVoltage: Double? = nil, batteryVoltage: Double? = nil, batteryNominalVoltage: Double? = nil,
                flags: Flags = [], lowChargeLimitPercent: Int? = nil, lowRuntimeLimitSeconds: Int? = nil,
                warningChargeLimitPercent: Int? = nil, selfTest: SelfTest? = nil,
                lowTransferVoltage: Double? = nil, highTransferVoltage: Double? = nil,
                serialNumber: String? = nil, manufacturer: String? = nil, timestamp: TimeInterval = 0) {
        self.present = present
        self.name = name
        self.onBattery = onBattery
        self.chargePercent = chargePercent
        self.runtimeSeconds = runtimeSeconds
        self.loadPercent = loadPercent
        self.loadWatts = loadWatts
        self.ratedWatts = ratedWatts
        self.ratedVA = ratedVA
        self.inputVoltage = inputVoltage
        self.outputVoltage = outputVoltage
        self.batteryVoltage = batteryVoltage
        self.batteryNominalVoltage = batteryNominalVoltage
        self.flags = flags
        self.lowChargeLimitPercent = lowChargeLimitPercent
        self.lowRuntimeLimitSeconds = lowRuntimeLimitSeconds
        self.warningChargeLimitPercent = warningChargeLimitPercent
        self.selfTest = selfTest
        self.lowTransferVoltage = lowTransferVoltage
        self.highTransferVoltage = highTransferVoltage
        self.serialNumber = serialNumber
        self.manufacturer = manufacturer
        self.timestamp = timestamp
    }

    /// No UPS at all.
    public static func absent(at t: TimeInterval = 0) -> UPSReading {
        UPSReading(present: false, timestamp: t)
    }

    /// Take the fields the HID report knows and the IOKit entry does not (load, voltages,
    /// limits, flags), keeping the IOKit entry's view of state, charge and runtime where the
    /// HID side has none. `other` wins only where this reading is empty.
    public func merging(_ other: UPSReading?) -> UPSReading {
        guard let o = other, o.present else { return self }
        var r = self
        r.name = r.name ?? o.name
        r.chargePercent = r.chargePercent ?? o.chargePercent
        r.runtimeSeconds = r.runtimeSeconds ?? o.runtimeSeconds
        r.loadPercent = r.loadPercent ?? o.loadPercent
        r.loadWatts = r.loadWatts ?? o.loadWatts
        r.ratedWatts = r.ratedWatts ?? o.ratedWatts
        r.ratedVA = r.ratedVA ?? o.ratedVA
        r.inputVoltage = r.inputVoltage ?? o.inputVoltage
        r.outputVoltage = r.outputVoltage ?? o.outputVoltage
        r.batteryVoltage = r.batteryVoltage ?? o.batteryVoltage
        r.batteryNominalVoltage = r.batteryNominalVoltage ?? o.batteryNominalVoltage
        r.flags = r.flags.union(o.flags)
        r.lowChargeLimitPercent = r.lowChargeLimitPercent ?? o.lowChargeLimitPercent
        r.lowRuntimeLimitSeconds = r.lowRuntimeLimitSeconds ?? o.lowRuntimeLimitSeconds
        r.warningChargeLimitPercent = r.warningChargeLimitPercent ?? o.warningChargeLimitPercent
        r.selfTest = r.selfTest ?? o.selfTest
        r.lowTransferVoltage = r.lowTransferVoltage ?? o.lowTransferVoltage
        r.highTransferVoltage = r.highTransferVoltage ?? o.highTransferVoltage
        r.serialNumber = r.serialNumber ?? o.serialNumber
        r.manufacturer = r.manufacturer ?? o.manufacturer
        return r
    }
}

/// A volume the guard may have to unmount: identified by its volume UUID, never by its
/// `diskN` number (those change) or its name alone (two drives can share one).
public struct VolumeState: Equatable, Hashable, Sendable {
    public var uuid: String
    public var name: String
    /// `disk9s1`, when the disk is attached.
    public var bsdName: String?
    /// `/Volumes/Flitslig`, when mounted.
    public var mountPoint: String?
    /// The disk is connected (mounted or not). An unmounted-but-attached volume can be
    /// remounted; a detached one cannot.
    public var isAttached: Bool
    /// What the drive is, for the menu: "Lexar SSD NM790 4TB · PCI-Express".
    public var detail: String

    public var isMounted: Bool { mountPoint != nil }

    public init(uuid: String, name: String, bsdName: String? = nil, mountPoint: String? = nil,
                isAttached: Bool = true, detail: String = "") {
        self.uuid = uuid
        self.name = name
        self.bsdName = bsdName
        self.mountPoint = mountPoint
        self.isAttached = isAttached
        self.detail = detail
    }
}

/// A process with a file open on a protected volume. Apps (processes that live inside an
/// `.app` bundle) can be asked to quit; daemons such as `smbd` or Spotlight only get logged.
public struct Holder: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var executable: String
    /// The enclosing `.app` bundle's display name, nil for daemons and bare executables.
    public var appName: String?
    public var bundleID: String?

    public var isApp: Bool { appName != nil }
    /// What the quit bookkeeping is keyed on: one ask per app per outage, however many of
    /// its processes hold files.
    public var appKey: String { bundleID ?? appName ?? "\(pid)" }
    public var shortName: String { appName ?? (executable as NSString).lastPathComponent }

    public init(pid: Int32, executable: String, appName: String? = nil, bundleID: String? = nil) {
        self.pid = pid
        self.executable = executable
        self.appName = appName
        self.bundleID = bundleID
    }
}

public struct GuardError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
