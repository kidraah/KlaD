// klad-probe — headless scanner probe & benchmark
//
//   klad-probe verify <dir>                 parser ⇄ lstat cross-check
//   klad-probe scan <path> [--threads N] [--no-private] [--top N]
//   klad-probe volume <path>                volume / container report

import Foundation
import KlaDModels
import KlaDScanner

func formatBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bitPattern: value), countStyle: .file)
}

func usage() -> Never {
    print("""
    usage:
      klad-probe verify <dir>
      klad-probe scan <path> [--threads N] [--no-private] [--top N]
      klad-probe volume <path>
    """)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, args.count >= 2 else { usage() }
let target = (args[1] as NSString).expandingTildeInPath
DatalessMaterializationGuard.engageProcessWide()

func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

switch command {
case "verify":
    let report = ScannerDiagnostics.verifyAttributePacking(directory: target)
    print(report)
    exit(report.mismatchCount == 0 ? 0 : 1)

case "scan":
    let threads = Int(option("--threads") ?? "0") ?? 0
    let top = Int(option("--top") ?? "12") ?? 12
    let options = ScanOptions(rootPath: target, requestPrivateSize: !args.contains("--no-private"), concurrency: threads)
    let scanner = BulkAPFSScanner()
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Result<ScanResult, Error>?
    Task.detached {
        do {
            let result = try await scanner.scan(options) { progress in
                FileHandle.standardError.write(Data(String(format: "\r  %8llu files  %7llu dirs  %@  %.0f items/s   ",
                    progress.filesScanned, progress.directoriesScanned,
                    formatBytes(progress.allocatedBytes), progress.itemsPerSecond).utf8))
            }
            outcome = .success(result)
        } catch {
            outcome = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    FileHandle.standardError.write(Data("\n".utf8))
    switch outcome {
    case .success(let result):
        let m = result.root.metrics
        print("root:        \(result.root.path)")
        print("duration:    \(String(format: "%.2f s", result.duration))  (\(Int(Double(m.itemCount) / max(result.duration, 0.001))) items/s)")
        print("files/dirs:  \(m.fileCount) / \(m.directoryCount)")
        print("logical:     \(formatBytes(m.logicalBytes))  (\(m.logicalBytes))")
        print("allocated:   \(formatBytes(m.allocatedBytes))  (\(m.allocatedBytes))")
        print("private:     \(formatBytes(m.privateBytes))  (\(m.privateBytes))")
        print("shared:      \(formatBytes(m.sharedBytes))  (clones / snapshots / hard links)")
        print("cloud stubs: \(formatBytes(m.cloudStubBytes))")
        print("unreadable:  \(result.unreadableCount)  hardlink dups: \(result.hardLinkDuplicateCount)  PRIVATESIZE: \(result.privateSizeSupported)")
        for issue in result.issues.prefix(5) { print("  ! \(issue.path): \(issue.message)") }
        print("top \(top):")
        for child in result.root.children.prefix(top) {
            print("  \(formatBytes(child.metrics.allocatedBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) private \(formatBytes(child.metrics.privateBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(child.name)")
        }
    case .failure(let error):
        print("scan failed: \(error.localizedDescription)")
        exit(1)
    case .none:
        exit(1)
    }

case "volume":
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var report: VolumeSpaceReport?
    Task.detached {
        report = await APFSVolumeInspector().report(forPath: target)
        semaphore.signal()
    }
    semaphore.wait()
    guard let r = report else { print("no report"); exit(1) }
    print("volume:      \(r.volumeName) (\(r.fileSystemType), \(r.deviceIdentifier ?? "?"))")
    print("total:       \(formatBytes(r.totalCapacity))")
    print("used:        \(formatBytes(r.usedCapacity))")
    print("available:   \(formatBytes(r.availableCapacity))  (now)")
    print("important:   \(formatBytes(r.availableForImportantUsage))  ⇒ purgeable \(formatBytes(r.purgeableCapacity))")
    print("opportun.:   \(formatBytes(r.availableForOpportunisticUsage))")
    print("container:   \(r.containerReference ?? "?") ceiling \(formatBytes(r.containerCapacity ?? 0)) free \(formatBytes(r.containerFree ?? 0))")
    for v in r.containerVolumes {
        print("   - \(v.deviceIdentifier) \(v.name) \(v.roles) \(formatBytes(v.capacityInUse))")
    }
    print("snapshots:   \(r.localSnapshotNames.count)")
    print("caps:        cloneMapping=\(r.supportsCloneMapping) privateSize=\(r.supportsPrivateSize) sealed=\(r.isSealedSystemVolume) caseSensitive=\(r.isCaseSensitive)")

default:
    usage()
}
