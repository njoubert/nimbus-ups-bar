// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit.hid
import UpsGuardCore

/// The UPS over USB HID, read directly. macOS's own power-source entry carries only state,
/// charge and runtime; the HID Power Device report behind it also has the load, the input,
/// output and battery voltages, the UPS's own low-battery limits, the self-test result and
/// a dozen flags. `ioupsd` keeps the device open too; a second, shared open is allowed and
/// a full read of every element takes about 30 ms on this hardware.
///
/// Elements are keyed by the collection they sit in as well as their usage, because the same
/// usage (`Voltage`, 0x84/0x30) appears under Input, Output and the battery's PowerSummary.
public final class UPSHID: @unchecked Sendable {

    public struct Field: Equatable {
        public let section: String
        public let label: String
        public let value: String
        public let raw: Int
        /// Where it came from: the enclosing collection, the usage page, the usage.
        public let key: Key
    }

    public struct Report: Equatable {
        public var reading: UPSReading
        public var fields: [Field]
        public var readMillis: Int
        public init(reading: UPSReading, fields: [Field] = [], readMillis: Int = 0) {
            self.reading = reading; self.fields = fields; self.readMillis = readMillis
        }
    }

    /// One element: the enclosing collection's usage on page 0x84 (0x1A input, 0x1C output,
    /// 0x24 summary…), the usage page, the usage.
    public struct Key: Hashable, Codable {
        public let section: UInt32
        public let page: UInt32
        public let usage: UInt32
        public init(section: UInt32, page: UInt32, usage: UInt32) { self.section = section; self.page = page; self.usage = usage }
    }

    /// Everything the device returned, undecoded: what `fetch()` reads over USB and what
    /// `decode(_:now:)` turns into a `Report`. Serialised by `--dump-hid-raw` as the fixture
    /// the decode is tested against; a second UPS model is a second fixture.
    ///
    /// `values` holds one entry per element macOS parsed out of the report descriptor (every
    /// type, duplicates included), with the element's metadata and the value as read, or the
    /// IOReturn of a read that failed. A full capture (`fetch(full: true)`, the Inspector and
    /// `--dump-hid-raw`) adds the collections, the bytes of every report fetched with
    /// GET_REPORT, the report descriptor, and every IORegistry property of the device; a
    /// routine read leaves those nil and reads only the input and feature elements the decode
    /// needs. Every field beyond section/page/usage/value is optional, so older fixtures load.
    public struct RawReport: Codable, Equatable {
        public struct Value: Codable, Equatable {
            public var section: UInt32
            public var page: UInt32
            public var usage: UInt32
            public var value: Int
            /// macOS's element cookie: unique per element, which (section, page, usage) is not.
            public var cookie: UInt32?
            /// "input-misc", "input-button", "input-axis", "input-scancodes", "input-null",
            /// "output", "feature".
            public var type: String?
            public var reportID: UInt32?
            public var reportSize: UInt32?
            public var reportCount: UInt32?
            public var logicalMin: Int?
            public var logicalMax: Int?
            public var physicalMin: Int?
            public var physicalMax: Int?
            public var unit: UInt32?
            public var unitExponent: UInt32?
            public var isArray: Bool?
            /// The value's bytes as the device sent them, hex; the integer above is IOKit's
            /// reading of these.
            public var bytes: String?
            /// The IOReturn of a read that failed (then `value` is 0 and meaningless).
            public var error: Int32?

            public init(section: UInt32, page: UInt32, usage: UInt32, value: Int) {
                self.section = section; self.page = page; self.usage = usage; self.value = value
            }
        }
        public struct Collection: Codable, Equatable {
            public var cookie: UInt32
            public var page: UInt32
            public var usage: UInt32
            /// HID collection type: 0 physical, 1 application, 2 logical, 3 report, …
            public var collectionType: UInt32
            public var parentCookie: UInt32?
            public init(cookie: UInt32, page: UInt32, usage: UInt32, collectionType: UInt32, parentCookie: UInt32?) {
                self.cookie = cookie; self.page = page; self.usage = usage; self.collectionType = collectionType; self.parentCookie = parentCookie
            }
        }
        /// One GET_REPORT: the report's bytes as returned (report ID first when the device numbers
        /// its reports), or the IOReturn when the device refused.
        public struct Report: Codable, Equatable {
            public var type: String
            public var id: UInt32
            public var bytes: String?
            public var error: Int32?
            public init(type: String, id: UInt32, bytes: String?, error: Int32?) {
                self.type = type; self.id = id; self.bytes = bytes; self.error = error
            }
        }
        public var product: String?
        public var manufacturer: String?
        public var serial: String?
        public var values: [Value]
        public var readMillis: Int
        public var collections: [Collection]?
        public var reports: [Report]?
        /// The HID report descriptor, hex: the device's own statement of every field above.
        public var descriptor: String?
        /// Every IORegistry property of the device, each as text (data as hex).
        public var properties: [String: String]?

        public init(product: String?, manufacturer: String?, serial: String?, values: [Value], readMillis: Int = 0) {
            self.product = product; self.manufacturer = manufacturer; self.serial = serial; self.values = values; self.readMillis = readMillis
        }
    }

    /// An element as found at attach time, with everything about it that does not change.
    private struct Element {
        let key: Key
        let element: IOHIDElement
        let template: RawReport.Value
        let isOutput: Bool
    }

    private let manager: IOHIDManager
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var elements: [Element] = []
    private var collections: [RawReport.Collection] = []
    private var deviceInfo: (product: String?, manufacturer: String?, serial: String?) = (nil, nil, nil)
    /// Main thread; true when a UPS arrived, false when it went. `atStart` is true for the UPS
    /// that was already plugged in when this process started looking: IOKit reports it as an
    /// arrival too, and that is not news.
    public var onDeviceChange: ((_ attached: Bool, _ atStart: Bool) -> Void)?
    /// The registry ids of the devices already present when the manager opened.
    private var presentAtOpen: Set<UInt64> = []

    public var isAttached: Bool { lock.withLock { device != nil } }

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // HID Power Device page, usage UPS.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 0x84, kIOHIDDeviceUsageKey: 0x04] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<UPSHID>.fromOpaque(ctx).takeUnretainedValue().attach(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<UPSHID>.fromOpaque(ctx).takeUnretainedValue().detach(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        // The matching callback fires for these too, once the run loop turns.
        if let present = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            presentAtOpen = Set(present.compactMap(UPSHID.registryID))
        }
    }

    private static func registryID(_ dev: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(dev), &id) == KERN_SUCCESS ? id : nil
    }

    // MARK: Device lifecycle (main run loop)

    private func attach(_ dev: IOHIDDevice) {
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        var list: [Element] = []
        var colls: [RawReport.Collection] = []
        if let all = IOHIDDeviceCopyMatchingElements(dev, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for e in all {
                let t = IOHIDElementGetType(e)
                let cookie = UInt32(IOHIDElementGetCookie(e))
                if t == kIOHIDElementTypeCollection {
                    colls.append(RawReport.Collection(cookie: cookie, page: IOHIDElementGetUsagePage(e), usage: IOHIDElementGetUsage(e),
                                                      collectionType: UInt32(IOHIDElementGetCollectionType(e).rawValue),
                                                      parentCookie: IOHIDElementGetParent(e).map { UInt32(IOHIDElementGetCookie($0)) }))
                    continue
                }
                let k = Key(section: UPSHID.section(of: e), page: IOHIDElementGetUsagePage(e), usage: IOHIDElementGetUsage(e))
                var v = RawReport.Value(section: k.section, page: k.page, usage: k.usage, value: 0)
                v.cookie = cookie
                v.type = UPSHID.typeName(t)
                v.reportID = IOHIDElementGetReportID(e)
                v.reportSize = IOHIDElementGetReportSize(e)
                v.reportCount = IOHIDElementGetReportCount(e)
                v.logicalMin = IOHIDElementGetLogicalMin(e)
                v.logicalMax = IOHIDElementGetLogicalMax(e)
                v.physicalMin = IOHIDElementGetPhysicalMin(e)
                v.physicalMax = IOHIDElementGetPhysicalMax(e)
                v.unit = IOHIDElementGetUnit(e)
                v.unitExponent = IOHIDElementGetUnitExponent(e)
                v.isArray = IOHIDElementIsArray(e)
                list.append(Element(key: k, element: e, template: v, isOutput: t == kIOHIDElementTypeOutput))
            }
        }
        func prop(_ key: String) -> String? { IOHIDDeviceGetProperty(dev, key as CFString) as? String }
        lock.withLock {
            device = dev
            elements = list
            collections = colls
            deviceInfo = (prop(kIOHIDProductKey), prop(kIOHIDManufacturerKey), prop(kIOHIDSerialNumberKey))
        }
        let atStart = UPSHID.registryID(dev).map { presentAtOpen.remove($0) != nil } ?? false
        DispatchQueue.main.async { self.onDeviceChange?(true, atStart) }
    }

    private static func typeName(_ t: IOHIDElementType) -> String {
        switch t {
        case kIOHIDElementTypeInput_Misc: return "input-misc"
        case kIOHIDElementTypeInput_Button: return "input-button"
        case kIOHIDElementTypeInput_Axis: return "input-axis"
        case kIOHIDElementTypeInput_ScanCodes: return "input-scancodes"
        case kIOHIDElementTypeInput_NULL: return "input-null"
        case kIOHIDElementTypeOutput: return "output"
        case kIOHIDElementTypeFeature: return "feature"
        default: return "type-\(t.rawValue)"
        }
    }

    private func detach(_ dev: IOHIDDevice) {
        lock.withLock {
            guard device == dev else { return }
            device = nil
            elements = []
            collections = []
        }
        DispatchQueue.main.async { self.onDeviceChange?(false, false) }
    }

    /// The nearest enclosing collection on the Power Device page that names a *part* of the
    /// UPS: Input, Output, Battery, the PowerSummary, a converter or a flow. 0 when none.
    private static func section(of e: IOHIDElement) -> UInt32 {
        var cur = IOHIDElementGetParent(e)
        while let c = cur {
            if IOHIDElementGetUsagePage(c) == 0x84 {
                let u = IOHIDElementGetUsage(c)
                if [0x10, 0x12, 0x16, 0x18, 0x1A, 0x1C, 0x1E, 0x20, 0x24].contains(Int(u)) { return u }
            }
            cur = IOHIDElementGetParent(c)
        }
        return 0
    }

    // MARK: Reading

    /// Every element, raw, straight from the device. Safe to call from any thread; blocks on
    /// USB (~30 ms for a routine read). nil when no UPS is attached.
    ///
    /// A routine read gets the input and feature elements the decode uses, as it always has.
    /// A `full` read gets every element, every report by GET_REPORT, the descriptor and the
    /// device's properties: a few times the USB traffic, for the Inspector and the fixture,
    /// never on the guard's clock.
    public func fetch(full: Bool = false) -> RawReport? {
        let (dev, els, colls, info) = lock.withLock { (device, elements, collections, deviceInfo) }
        guard let dev else { return nil }
        let t0 = Date()
        var values: [RawReport.Value] = []
        // A routine read is the element list the decode has always read: the first input or
        // feature element of each (section, page, usage), 58 on the CP1500. A full read is
        // every element, outputs, duplicates and placeholders included.
        var seen = Set<Key>()
        for e in els where full || (UPSHID.decodedTypes.contains(e.template.type ?? "") && seen.insert(e.key).inserted) {
            // "With update": go to the device for every element. The plain call returns the
            // cached value for Input-type elements, and the ones the UPS does not push on its
            // own (self-test result, beeper, transfer voltages) then read as 0 until somebody
            // else happens to request them.
            var v = e.template
            let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, e.element, 0, 0)
            var holder: Unmanaged<IOHIDValue> = Unmanaged.passUnretained(placeholder)
            let r = IOHIDDeviceGetValueWithOptions(dev, e.element, &holder, 0x00020000 /* kIOHIDDeviceGetValueWithUpdate */)
            if r == kIOReturnSuccess {
                let hv = holder.takeUnretainedValue()
                v.value = Int(IOHIDValueGetIntegerValue(hv))
                let n = IOHIDValueGetLength(hv)
                v.bytes = UPSHID.hex(IOHIDValueGetBytePtr(hv), n)
            } else {
                v.error = Int32(bitPattern: UInt32(bitPattern: r))
            }
            values.append(v)
        }
        guard values.contains(where: { $0.error == nil }) else { return nil }
        var raw = RawReport(product: info.product, manufacturer: info.manufacturer, serial: info.serial, values: values,
                            readMillis: Int(Date().timeIntervalSince(t0) * 1000))
        if full {
            raw.collections = colls
            raw.reports = UPSHID.reports(dev, elements: els)
            if let d = IOHIDDeviceGetProperty(dev, kIOHIDReportDescriptorKey as CFString) as? Data {
                raw.descriptor = d.map { String(format: "%02x", $0) }.joined()
            }
            raw.properties = UPSHID.properties(dev)
            raw.readMillis = Int(Date().timeIntervalSince(t0) * 1000)
        }
        return raw
    }

    /// GET_REPORT for every (type, report ID) the elements name: the device's own bytes.
    private static func reports(_ dev: IOHIDDevice, elements: [Element]) -> [RawReport.Report] {
        var wanted: [(IOHIDReportType, String, UInt32)] = []
        for e in elements {
            let t = IOHIDElementGetType(e.element)
            let rt: (IOHIDReportType, String)
            switch t {
            case kIOHIDElementTypeFeature: rt = (kIOHIDReportTypeFeature, "feature")
            case kIOHIDElementTypeOutput: rt = (kIOHIDReportTypeOutput, "output")
            default: rt = (kIOHIDReportTypeInput, "input")
            }
            let id = IOHIDElementGetReportID(e.element)
            if !wanted.contains(where: { $0.1 == rt.1 && $0.2 == id }) { wanted.append((rt.0, rt.1, id)) }
        }
        wanted.sort { ($0.1, $0.2) < ($1.1, $1.2) }
        return wanted.map { (type, name, id) in
            var buf = [UInt8](repeating: 0, count: 512)
            var len = CFIndex(buf.count)
            let r = IOHIDDeviceGetReport(dev, type, CFIndex(id), &buf, &len)
            guard r == kIOReturnSuccess else { return RawReport.Report(type: name, id: id, bytes: nil, error: Int32(bitPattern: UInt32(bitPattern: r))) }
            return RawReport.Report(type: name, id: id, bytes: buf.prefix(len).map { String(format: "%02x", $0) }.joined(), error: nil)
        }
    }

    /// The device's IORegistry properties, each as text: strings as they are, numbers as
    /// numbers, data as hex, and dictionaries and arrays as compact JSON (keys sorted, data
    /// inside as hex), so a nested property reads on one line and parses back.
    private static func properties(_ dev: IOHIDDevice) -> [String: String] {
        let service = IOHIDDeviceGetService(dev)
        var out: Unmanaged<CFMutableDictionary>?
        guard service != 0, IORegistryEntryCreateCFProperties(service, &out, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = out?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict.mapValues(propertyText)
    }

    static func propertyText(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let d as Data: return d.map { String(format: "%02x", $0) }.joined()
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default:
            let clean = jsonSafe(v)
            if JSONSerialization.isValidJSONObject(clean),
               let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) { return text }
            return "\(v)"
        }
    }

    private static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let s as String: return s
        case let d as Data: return d.map { String(format: "%02x", $0) }.joined()
        case let n as NSNumber: return n
        case let a as [Any]: return a.map(jsonSafe)
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        default: return "\(v)"
        }
    }

    private static func hex(_ p: UnsafePointer<UInt8>, _ n: CFIndex) -> String {
        (0..<max(0, n)).map { String(format: "%02x", p[$0]) }.joined()
    }

    /// `fetch()` then `decode`: the report the monitor uses. nil when no UPS is attached.
    public func read(now: TimeInterval) -> Report? {
        fetch().map { UPSHID.decode($0, now: now) }
    }

    /// The raw element values as a reading and as labelled fields. Pure: the quirks (battery
    /// volts in tenths, AC-present versus discharging, the self-test codes, the summary-or-
    /// battery section fallback, load from percent when no wattage is reported) are all here.
    public static func decode(_ raw: RawReport, now: TimeInterval) -> Report {
        var map: [Key: Int] = [:]
        var fields: [Field] = []
        for v in raw.values {
            // The decode reads what it always read: the input and feature elements that carry
            // a value. Failed reads, outputs and the input-null placeholders are recorded for
            // the Inspector but are not readings; a repeated (section, page, usage), which this
            // UPS sends once as a feature and once as an input, keeps its first value.
            if v.error != nil { continue }
            if let t = v.type, !UPSHID.decodedTypes.contains(t) { continue }
            let key = Key(section: v.section, page: v.page, usage: v.usage)
            if map[key] != nil { continue }
            map[key] = v.value
            // String-index usages (iProduct, iSerial, chemistry…) are USB string table slots,
            // not values; the device properties carry the strings themselves.
            if UPSHID.stringIndexes.contains(key.page << 8 | key.usage) { continue }
            fields.append(Field(section: UPSHID.sectionName(key.section), label: UPSHID.label(key), value: UPSHID.format(key, v.value), raw: v.value, key: key))
        }

        func get(_ section: UInt32, _ page: UInt32, _ usage: UInt32) -> Int? { map[Key(section: section, page: page, usage: usage)] }
        /// A battery-page or summary value that may live under PowerSummary (0x24) or Battery (0x12).
        func batt(_ page: UInt32, _ usage: UInt32) -> Int? { get(0x24, page, usage) ?? get(0x12, page, usage) }
        let input: UInt32 = 0x1A, output: UInt32 = 0x1C

        var r = UPSReading(present: true, timestamp: now)
        r.name = raw.product
        r.manufacturer = raw.manufacturer
        r.serialNumber = raw.serial
        if let ac = batt(0x85, 0xD0) { r.onBattery = ac == 0; if ac != 0 { r.flags.insert(.acPresent) } }
        else if let d = batt(0x85, 0x45) { r.onBattery = d != 0 }
        r.chargePercent = batt(0x85, 0x66)
        if let s = batt(0x85, 0x68), s > 0 { r.runtimeSeconds = s }
        r.loadPercent = get(output, 0x84, 0x35)
        if let w = get(output, 0x84, 0x44), w > 0 { r.ratedWatts = Double(w) }
        if let va = get(output, 0x84, 0x43), va > 0 { r.ratedVA = Double(va) }
        if let w = get(output, 0x84, 0x34), w > 0 { r.loadWatts = Double(w) }
        else if let p = r.loadPercent, let rated = r.ratedWatts { r.loadWatts = Double(p) / 100 * rated }
        if let v = get(input, 0x84, 0x30) { r.inputVoltage = Double(v) }
        if let v = get(output, 0x84, 0x30) { r.outputVoltage = Double(v) }
        if let v = batt(0x84, 0x30) { r.batteryVoltage = UPSHID.batteryVolts(v) }
        if let v = batt(0x84, 0x40) { r.batteryNominalVoltage = UPSHID.batteryVolts(v) }
        let flagMap: [(UInt32, UInt32, UPSReading.Flags)] = [
            (0x85, 0x44, .charging), (0x85, 0x45, .discharging), (0x85, 0x46, .fullyCharged),
            (0x85, 0x42, .belowCapacityLimit), (0x85, 0x43, .runtimeLimitExpired),
            (0x85, 0x4B, .needsReplacement), (0x84, 0x69, .shutdownImminent),
        ]
        for (page, usage, flag) in flagMap where (batt(page, usage) ?? 0) != 0 { r.flags.insert(flag) }
        if (get(output, 0x84, 0x65) ?? 0) != 0 { r.flags.insert(.overload) }
        if (get(output, 0x84, 0x69) ?? 0) != 0 { r.flags.insert(.shutdownImminent) }
        if (get(output, 0x84, 0x6E) ?? 0) != 0 { r.flags.insert(.boost) }
        if (get(output, 0x84, 0x6F) ?? 0) != 0 { r.flags.insert(.buck) }
        r.lowChargeLimitPercent = batt(0x85, 0x29)
        r.lowRuntimeLimitSeconds = batt(0x85, 0x2A)
        r.warningChargeLimitPercent = batt(0x85, 0x8C)
        if let t = get(output, 0x84, 0x58) ?? get(0x24, 0x84, 0x58) { r.selfTest = UPSReading.SelfTest(rawValue: t) }
        if let v = get(output, 0x84, 0x53) { r.lowTransferVoltage = Double(v) }
        if let v = get(output, 0x84, 0x54) { r.highTransferVoltage = Double(v) }
        return Report(reading: r, fields: fields, readMillis: raw.readMillis)
    }

    /// CyberPower reports battery volts in tenths once the figure has two digits (271 for a
    /// 24 V pack at 27.1 V; 240 for the nominal), the same quirk NUT corrects for.
    public static func batteryVolts(_ raw: Int) -> Double {
        raw >= 100 ? Double(raw) / 10 : Double(raw)
    }

    // MARK: Writing

    /// Start the UPS's quick battery self-test: the UPS tests its battery for about eleven
    /// seconds (the line-present flag stays set throughout) and leaves the result in `Test`.
    /// The one write this app ever makes to the UPS.
    ///
    /// CyberPower declares `Test` as an Input element, which `IOHIDDeviceSetValue` refuses
    /// (`kIOReturnUnsupported`); the device accepts a SET_REPORT of that report ID as a
    /// feature report, which is what NUT sends. The buffer carries the report ID as its first
    /// byte, the convention IOKit (and hidapi) use for numbered reports.
    public func startQuickSelfTest() -> Result<Void, GuardError> {
        let (dev, els) = lock.withLock { (device, elements) }
        guard let dev else { return .failure(GuardError("no UPS over USB HID")) }
        guard let e = els.first(where: { $0.key.page == 0x84 && $0.key.usage == 0x58 && !$0.isOutput })?.element else {
            return .failure(GuardError("this UPS has no Test field"))
        }
        let rid = IOHIDElementGetReportID(e)
        var buf: [UInt8] = [UInt8(truncatingIfNeeded: rid), 1]   // 1 = quick test (NUT's cps mapping)
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, CFIndex(rid), &buf, buf.count)
        return r == kIOReturnSuccess ? .success(()) : .failure(GuardError(String(format: "SET_REPORT %d refused: 0x%08x", rid, r)))
    }

    // MARK: Naming and formatting

    public static func sectionName(_ s: UInt32) -> String {
        switch s {
        case 0x1A: return "Input"
        case 0x1C: return "Output"
        case 0x24: return "Battery"
        case 0x12: return "Battery"
        case 0x16: return "Converter"
        case 0x1E: return "Flow"
        case 0x10: return "Power supply"
        default: return "Other"
        }
    }

    private static let powerNames: [UInt32: String] = [
        0x30: "Voltage", 0x31: "Current", 0x32: "Frequency", 0x33: "Apparent power", 0x34: "Active power",
        0x35: "Load", 0x36: "Temperature", 0x40: "Nominal voltage", 0x42: "Nominal frequency",
        0x43: "Rated apparent power", 0x44: "Rated active power", 0x53: "Low transfer voltage",
        0x54: "High transfer voltage", 0x55: "Delay before reboot", 0x56: "Delay before startup",
        0x57: "Delay before shutdown", 0x58: "Self-test", 0x5A: "Beeper", 0x60: "Present", 0x61: "Good",
        0x62: "Internal failure", 0x65: "Overload", 0x66: "Overcharged", 0x67: "Over temperature",
        0x68: "Shutdown requested", 0x69: "Shutdown imminent", 0x6B: "Switched on", 0x6C: "Switchable",
        0x6D: "Used", 0x6E: "Boost (raising low line voltage)", 0x6F: "Buck (trimming high line voltage)",
        0x73: "Communication lost", 0xFD: "Manufacturer string index", 0xFE: "Product string index",
        0xFF: "Serial string index",
    ]
    private static let batteryNames: [UInt32: String] = [
        0x29: "Low-battery limit (charge)", 0x2A: "Low-battery limit (runtime)", 0x2C: "Capacity mode",
        0x42: "Below low-battery charge limit", 0x43: "Below low-battery runtime limit", 0x44: "Charging",
        0x45: "Discharging", 0x46: "Fully charged", 0x47: "Fully discharged", 0x4B: "Battery needs replacement",
        0x66: "Charge", 0x67: "Full-charge capacity", 0x68: "Runtime to empty", 0x69: "Average runtime to empty",
        0x83: "Design capacity", 0x85: "Manufacture date", 0x89: "Chemistry string index", 0x8B: "Rechargeable",
        0x8C: "Warning charge limit", 0x8D: "Capacity granularity 1", 0x8E: "Capacity granularity 2",
        0x8F: "OEM information string index", 0xD0: "Line power present", 0xD1: "Battery present",
    ]
    /// The element types the decode reads (the element list before it kept everything).
    static let decodedTypes: Set<String> = ["feature", "input-misc", "input-button"]
    public static let stringIndexes: Set<UInt32> = [0x84FD, 0x84FE, 0x84FF, 0x8589, 0x858F]
    private static let booleans: Set<UInt32> = [0x60, 0x61, 0x62, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x73]
    private static let batteryBooleans: Set<UInt32> = [0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x4B, 0x8B, 0xD0, 0xD1]

    public static func label(_ k: Key) -> String {
        switch k.page {
        case 0x84: return powerNames[k.usage] ?? String(format: "Power device usage 0x%02X", k.usage)
        case 0x85: return batteryNames[k.usage] ?? String(format: "Battery usage 0x%02X", k.usage)
        default: return String(format: "Vendor usage 0x%04X/0x%02X", k.page, k.usage)
        }
    }

    public static func format(_ k: Key, _ v: Int) -> String {
        switch (k.page, k.usage) {
        case (0x84, 0x30), (0x84, 0x40), (0x84, 0x53), (0x84, 0x54):
            // Battery-section volts carry the tenths quirk; line volts are whole volts.
            let volts = (k.section == 0x24 || k.section == 0x12) ? batteryVolts(v) : Double(v)
            return volts == volts.rounded() ? "\(Int(volts)) V" : String(format: "%.1f V", volts)
        case (0x84, 0x31): return "\(v) A"
        case (0x84, 0x32), (0x84, 0x42): return "\(v) Hz"
        case (0x84, 0x33), (0x84, 0x43): return "\(v) VA"
        case (0x84, 0x34), (0x84, 0x44): return "\(v) W"
        case (0x84, 0x35): return "\(v) %"
        case (0x84, 0x55), (0x84, 0x56), (0x84, 0x57): return v < 0 ? "not set" : "\(v) s"
        case (0x84, 0x58): return UPSReading.SelfTest(rawValue: v)?.text ?? "\(v)"
        case (0x84, 0x5A): return [1: "disabled", 2: "enabled", 3: "muted"][v] ?? "\(v)"
        case (0x84, let u) where booleans.contains(u): return v != 0 ? "yes" : "no"
        case (0x85, 0x29), (0x85, 0x66), (0x85, 0x67), (0x85, 0x83), (0x85, 0x8C), (0x85, 0x8D), (0x85, 0x8E): return "\(v) %"
        case (0x85, 0x2A), (0x85, 0x68), (0x85, 0x69): return v <= 0 ? "\(v)" : Duration.text(TimeInterval(v))
        case (0x85, 0x2C): return [0: "mAh", 1: "mWh", 2: "percent", 3: "boolean"][v] ?? "\(v)"
        case (0x85, let u) where batteryBooleans.contains(u): return v != 0 ? "yes" : "no"
        default: return "\(v)"
        }
    }
}
