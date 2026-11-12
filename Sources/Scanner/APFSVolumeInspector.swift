// APFSVolumeInspector.swift — KlaDScanner
//
// Explains where space actually is at the volume / container level:
//   • URLResourceKey capacities: total, available now, available for
//     "important" usage (includes purgeable) and "opportunistic" usage.
//   • statfs(2): file system type, BSD device, mount point.
//   • getattrlist(ATTR_VOL_CAPABILITIES): clone mapping, sealed, case sensitivity.
//   • `diskutil apfs list -plist`: the container ceiling, unallocated space and
//     every sibling volume (VM swap, Preboot, Recovery, Update…) — the usual
//     hiding place of "System Data".
//   • `tmutil listlocalsnapshots`: local snapshots pinning blocks.
// Every subprocess runs with a hard timeout off the main actor.

import Darwin
import Foundation
import KlaDModels

public final class APFSVolumeInspector: VolumeInspecting {
    public init() {}

    public func report(forPath path: String) async -> VolumeSpaceReport? {
        let resolved = ScanSession.resolve(path)
        var fs = statfs()
        guard statfs(resolved, &fs) == 0 else { return nil }
        let fsType = Self.string(from: &fs.f_fstypename)
        let mountPoint = Self.string(from: &fs.f_mntonname)
        let mountedFrom = Self.string(from: &fs.f_mntfromname)        // "/dev/disk3s1" or "/dev/disk3s3s1"
        let bsdDevice = mountedFrom.hasPrefix("/dev/") ? String(mountedFrom.dropFirst(5)) : nil

        let url = URL(fileURLWithPath: resolved)
        let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ])
        let blockSize = UInt64(fs.f_bsize)
        let total = UInt64(values?.volumeTotalCapacity ?? 0) > 0
            ? UInt64(values?.volumeTotalCapacity ?? 0) : UInt64(fs.f_blocks) * blockSize
        let available = UInt64(values?.volumeAvailableCapacity ?? 0) > 0
            ? UInt64(values?.volumeAvailableCapacity ?? 0) : UInt64(fs.f_bavail) * blockSize
        let important = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        let opportunistic = UInt64(max(0, values?.volumeAvailableCapacityForOpportunisticUsage ?? 0))

        let capabilities = Self.volumeCapabilities(mountPoint: mountPoint)

        var report = VolumeSpaceReport(
            volumePath: resolved,
            volumeName: values?.volumeName ?? (mountPoint as NSString).lastPathComponent,
            fileSystemType: fsType,
            deviceIdentifier: bsdDevice,
            totalCapacity: total,
            availableCapacity: available,
            availableForImportantUsage: max(important, available),
            availableForOpportunisticUsage: opportunistic,
            supportsCloneMapping: capabilities.cloneMapping,
            supportsPrivateSize: Self.probePrivateSize(at: resolved),
            isCaseSensitive: capabilities.caseSensitive,
            isSealedSystemVolume: capabilities.sealed,
            capturedAt: Date()
        )

        if fsType == "apfs" {
            async let container = Self.containerInfo(forDevice: bsdDevice)
            async let snapshots = Self.localSnapshots(mountPoint: mountPoint)
            if let info = await container {
                report.containerReference = info.reference
                report.containerCapacity = info.capacity
                report.containerFree = info.free
                report.containerVolumes = info.volumes
            }
            report.localSnapshotNames = await snapshots
        }
        return report
    }

    // MARK: - Capabilities

    private struct Capabilities {
        var cloneMapping = false
        var sealed = false
        var caseSensitive = false
    }

    private static func volumeCapabilities(mountPoint: String) -> Capabilities {
        // ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES on the mount point.
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.volattr = 0x8000_0000 | 0x0002_0000
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlist(mountPoint, &list, raw.baseAddress, raw.count, 0)
        }
        guard rc == 0 else { return Capabilities() }
        return buffer.withUnsafeBytes { raw -> Capabilities in
            // u_int32_t length; vol_capabilities_attr_t { capabilities[4]; valid[4]; }
            let format = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let validFormat = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            func has(_ bit: UInt32) -> Bool { (format & bit) != 0 && (validFormat & bit) != 0 }
            return Capabilities(
                cloneMapping: has(0x0400_0000),  // VOL_CAP_FMT_CLONE_MAPPING
                sealed: has(0x0200_0000),        // VOL_CAP_FMT_SEALED
                caseSensitive: has(0x0000_0100)  // VOL_CAP_FMT_CASE_SENSITIVE
            )
        }
    }

    /// Whether ATTR_CMNEXT_PRIVATESIZE is answered for `path`.
    static func probePrivateSize(at path: String) -> Bool {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = BSDAttr.cmnReturnedAttrs
        list.forkattr = BSDAttr.extPrivateSize
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, UInt32(BSDAttr.optAttrCmnExtended) | UInt32(FSOPT_NOFOLLOW))
        }
        guard rc == 0 else { return false }
        return buffer.withUnsafeBytes { raw in
            // length(4) + returned attribute_set_t: forkattr at +16
            (raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self) & BSDAttr.extPrivateSize) != 0
        }
    }

    // MARK: - Container (diskutil)

    private struct ContainerInfo {
        var reference: String
        var capacity: UInt64
        var free: UInt64
        var volumes: [APFSVolumeUsage]
    }

    private static func containerInfo(forDevice device: String?) async -> ContainerInfo? {
        guard let device else { return nil }
        let result = await ProcessRunner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 8)
        guard result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]]
        else { return nil }

        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            let identifiers = volumes.compactMap { $0["DeviceIdentifier"] as? String }
            // "disk3s3s1" (sealed snapshot) belongs to volume "disk3s3".
            guard identifiers.contains(where: { device == $0 || device.hasPrefix($0 + "s") }) else { continue }
            let usages = volumes.map { volume in
                APFSVolumeUsage(
                    deviceIdentifier: volume["DeviceIdentifier"] as? String ?? "?",
                    name: volume["Name"] as? String ?? "Untitled",
                    roles: volume["Roles"] as? [String] ?? [],
                    capacityInUse: uint64(volume["CapacityInUse"]),
                    mountPoint: nil
                )
            }
            return ContainerInfo(
                reference: container["ContainerReference"] as? String ?? "?",
                capacity: uint64(container["CapacityCeiling"]),
                free: uint64(container["CapacityFree"]),
                volumes: usages.sorted { $0.capacityInUse > $1.capacityInUse }
            )
        }
        return nil
    }

    private static func uint64(_ value: Any?) -> UInt64 {
        if let n = value as? NSNumber { return n.uint64Value }
        if let i = value as? Int { return UInt64(max(0, i)) }
        return 0
    }

    // MARK: - Snapshots (tmutil)

    private static func localSnapshots(mountPoint: String) async -> [String] {
        let result = await ProcessRunner.run("/usr/bin/tmutil", ["listlocalsnapshots", mountPoint], timeout: 6)
        guard result.succeeded, let text = String(data: result.stdout, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Snapshots for") }
    }

    // MARK: - Helpers

    private static func string<T>(from tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}

// MARK: - ProcessRunner

/// Runs a subprocess (never a shell) with a hard timeout, off the caller's actor.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        public var timedOut: Bool
        public var succeeded: Bool { status == 0 && !timedOut }
        public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        var finished = false
        var timedOut = false
    }

    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice
            let box = Box()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                box.lock.lock(); box.stdout.append(chunk); box.lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                box.lock.lock(); box.stderr.append(chunk); box.lock.unlock()
            }

            let finish: @Sendable (Int32) -> Void = { status in
                box.lock.lock()
                guard !box.finished else { box.lock.unlock(); return }
                box.finished = true
                box.lock.unlock()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain anything left in the pipes.
                let restOut = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let restErr = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                box.lock.lock()
                box.stdout.append(restOut)
                box.stderr.append(restErr)
                let result = Result(status: status, stdout: box.stdout, stderr: box.stderr, timedOut: box.timedOut)
                box.lock.unlock()
                continuation.resume(returning: result)
            }

            process.terminationHandler = { finished in
                finish(finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                finish(-1)
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.lock.lock()
                let done = box.finished
                if !done { box.timedOut = true }
                box.lock.unlock()
                if !done { kill(pid, SIGKILL) }
            }
        }
    }
}
