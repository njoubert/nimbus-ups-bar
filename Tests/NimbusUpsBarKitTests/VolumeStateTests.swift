// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import DiskArbitration
import XCTest
@testable import NimbusUpsBarKit
import UpsGuardCore

/// `VolumeRegistry.state(from:)` over Disk Arbitration description dictionaries: which disks
/// count as external volumes worth protecting, and what is said about them.
final class VolumeStateTests: XCTestCase {

    func testProtectsAttachedOnlyUnlessChosen() {
        let flitslig = VolumeState(uuid: "B2D1", name: "Flitslig", bsdName: "disk9s1", mountPoint: "/Volumes/Flitslig")
        let leica = VolumeState(uuid: "F186", name: "LEICA M", isAttached: false, detail: "RW520 · USB · EXFAT · 128.43 GB")
        let unmounted = VolumeState(uuid: "AAAA", name: "Spare", bsdName: "disk10s1")
        // Every external volume: the attached ones, mounted or not; an ejected drive is not one.
        XCTAssertTrue(VolumeRegistry.protects(flitslig, allExternal: true, selected: []))
        XCTAssertTrue(VolumeRegistry.protects(unmounted, allExternal: true, selected: []), "unmounted by the guard, still attached: still its to remount")
        XCTAssertFalse(VolumeRegistry.protects(leica, allExternal: true, selected: ["F186"]))
        // A chosen few: those, attached or not.
        XCTAssertTrue(VolumeRegistry.protects(leica, allExternal: false, selected: ["F186"]))
        XCTAssertFalse(VolumeRegistry.protects(flitslig, allExternal: false, selected: ["F186"]))
    }

    func testRememberedDiskImagesAreDropped() {
        XCTAssertFalse(VolumeRegistry.keepRemembered(detail: "Disk Image · Virtual Interface · APFS · 17.75 GB"))
        XCTAssertTrue(VolumeRegistry.keepRemembered(detail: "RW520 · USB · EXFAT · 128.43 GB"))
        XCTAssertTrue(VolumeRegistry.keepRemembered(detail: ""))
    }

    /// The CP1500's neighbour on the desk: a Lexar NVMe in a Thunderbolt enclosure, mounted.
    func lexar(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var d: [String: Any] = [
            kDADiskDescriptionVolumeUUIDKey as String: CFUUIDCreateFromString(nil, "B2D16C3E-2857-443F-A983-9442CF1686AE" as CFString)!,
            kDADiskDescriptionVolumeNameKey as String: "Flitslig",
            kDADiskDescriptionVolumeMountableKey as String: true,
            kDADiskDescriptionVolumeNetworkKey as String: false,
            kDADiskDescriptionVolumeKindKey as String: "apfs",
            kDADiskDescriptionVolumePathKey as String: URL(fileURLWithPath: "/Volumes/Flitslig"),
            kDADiskDescriptionMediaBSDNameKey as String: "disk9s1",
            kDADiskDescriptionMediaContentKey as String: "41504653-0000-11AA-AA11-00306543ECAC",
            kDADiskDescriptionMediaSizeKey as String: Int64(4_000_000_000_000),
            kDADiskDescriptionDeviceInternalKey as String: false,
            kDADiskDescriptionDeviceModelKey as String: "Lexar SSD NM790 4TB ",
            kDADiskDescriptionDeviceProtocolKey as String: "PCI-Express",
        ]
        for (k, v) in changes {
            if let v { d[k] = v } else { d.removeValue(forKey: k) }
        }
        return d
    }

    func testExternalSSD() {
        let v = VolumeRegistry.state(from: lexar())
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.uuid, "B2D16C3E-2857-443F-A983-9442CF1686AE")
        XCTAssertEqual(v?.name, "Flitslig")
        XCTAssertEqual(v?.bsdName, "disk9s1")
        XCTAssertEqual(v?.mountPoint, "/Volumes/Flitslig")
        XCTAssertEqual(v?.isAttached, true)
        XCTAssertEqual(v?.isMounted, true)
        XCTAssertEqual(v?.detail, "Lexar SSD NM790 4TB · PCI-Express · APFS · 4 TB")
    }

    func testAttachedButNotMounted() {
        let v = VolumeRegistry.state(from: lexar([kDADiskDescriptionVolumePathKey as String: nil]))
        XCTAssertEqual(v?.isAttached, true)
        XCTAssertEqual(v?.isMounted, false)
        XCTAssertNil(v?.mountPoint)
    }

    func testInternalDiskIsNotExternal() {
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionDeviceInternalKey as String: true])))
    }

    func testNetworkShareIsNotExternal() {
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionVolumeNetworkKey as String: true])))
    }

    func testUnmountableIsSkipped() {
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionVolumeMountableKey as String: false])))
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionVolumeMountableKey as String: nil])))
    }

    func testHelperPartitionsAreSkipped() {
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionMediaContentKey as String: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"])), "EFI")
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionMediaContentKey as String: "426F6F74-0000-11AA-AA11-00306543ECAC"])), "Apple_Boot")
    }

    func testDiskImagesAreNotExternal() {
        // The iOS Simulator's volume: Disk Arbitration calls it external, it lives on the internal SSD.
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionDeviceProtocolKey as String: "Virtual Interface", kDADiskDescriptionDeviceModelKey as String: "Disk Image"])))
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionDeviceModelKey as String: "Disk Image "])), "the model alone")
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionDeviceProtocolKey as String: "Virtual Interface"])), "the protocol alone")
    }

    func testMissingUUIDIsSkipped() {
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionVolumeUUIDKey as String: nil])))
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionVolumeUUIDKey as String: ""])))
        XCTAssertNil(VolumeRegistry.state(from: lexar([kDADiskDescriptionVolumeUUIDKey as String: 42])), "the wrong type does not crash")
    }

    func testUUIDAsStringIsAccepted() {
        let v = VolumeRegistry.state(from: lexar([kDADiskDescriptionVolumeUUIDKey as String: "C3E2A1B0-0000-4000-8000-000000000001"]))
        XCTAssertEqual(v?.uuid, "C3E2A1B0-0000-4000-8000-000000000001")
    }

    func testDefaultsWhenDetailsAreMissing() {
        let d = lexar([kDADiskDescriptionVolumeNameKey as String: nil, kDADiskDescriptionDeviceModelKey as String: "  ",
                       kDADiskDescriptionDeviceProtocolKey as String: nil, kDADiskDescriptionVolumeKindKey as String: nil,
                       kDADiskDescriptionMediaSizeKey as String: nil, kDADiskDescriptionMediaBSDNameKey as String: nil])
        let v = VolumeRegistry.state(from: d)
        XCTAssertEqual(v?.name, "Untitled")
        XCTAssertEqual(v?.detail, "")
        XCTAssertNil(v?.bsdName)
    }
}
