// record-demo.swift — records a real, live KlaD session for the README.
//
//   record-demo <out.mov> <timeline.json>
//
// KlaD must already be open (Scripts/record-demo.sh does that) with --demo data.
// This drives the real mouse through a scripted tour (needs Accessibility),
// records only KlaD's window with ScreenCaptureKit (system cursor hidden,
// window transparency kept), and logs cursor, clicks and camera moves on the
// same host clock as the video frames. Scripts/render-demo.swift then adds the
// backdrop, eased zoom, a large cursor and click ripples.

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

// MARK: - Window

struct Target { let windowID: CGWindowID; let frame: CGRect }

func findKlaDWindow() -> Target? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "KlaD" && ($0[kCGWindowLayer as String] as? Int) == 0 }
    let frames = mine.compactMap { info -> Target? in
        guard let b = info[kCGWindowBounds as String] as? [String: Double], let id = info[kCGWindowNumber as String] as? Int,
              (b["Height"] ?? 0) > 200 else { return nil }
        return Target(windowID: CGWindowID(id), frame: CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!))
    }
    return frames.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

// MARK: - Recording

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let lock = NSLock()
    var firstFrameTime: Double?
    var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.92],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        lock.lock(); defer { lock.unlock() }
        let pts = buffer.presentationTimeStamp
        if firstFrameTime == nil {
            writer.startSession(atSourceTime: pts)
            firstFrameTime = pts.seconds
        }
        if input.isReadyForMoreMediaData, input.append(buffer) { frames += 1 }
    }

    func finish() {
        lock.lock()
        input.markAsFinished()
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}

// MARK: - Mouse + timeline

final class Director {
    let origin: CGPoint            // window top-left, global points
    let source = CGEventSource(stateID: .hidSystemState)
    var position: CGPoint          // window points
    var cursor: [[Double]] = []    // [t, x, y]
    var clicks: [Double] = []
    var camera: [[Double]] = []    // [t, zoom, x, y]
    var cameraNow: (zoom: Double, x: Double, y: Double)

    init(window: CGRect, start: CGPoint) {
        origin = window.origin
        position = start
        cameraNow = (1, Double(window.width / 2), Double(window.height / 2))
        post(.mouseMoved, start)
    }

    private func post(_ type: CGEventType, _ p: CGPoint) {
        let global = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: global, mouseButton: .left)?.post(tap: .cghidEventTap)
        cursor.append([now(), Double(p.x), Double(p.y)])
    }

    func wait(_ seconds: Double) {
        let end = now() + seconds
        while now() < end {
            cursor.append([now(), Double(position.x), Double(position.y)])
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
    }

    /// Eased move along a slight arc, like a hand on a trackpad.
    func move(_ x: Double, _ y: Double, _ duration: Double) {
        let from = position, to = CGPoint(x: x, y: y)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - abs(to.x - from.x) * 0.10)
        let start = now()
        while true {
            let raw = min(1, (now() - start) / duration)
            let k = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
            let u = 1 - k
            let p = CGPoint(x: u * u * from.x + 2 * u * k * mid.x + k * k * to.x,
                            y: u * u * from.y + 2 * u * k * mid.y + k * k * to.y)
            post(.mouseMoved, p)
            position = p
            if raw >= 1 { break }
            Thread.sleep(forTimeInterval: 1.0 / 120)
        }
    }

    func click() {
        clicks.append(now())
        post(.leftMouseDown, position)
        Thread.sleep(forTimeInterval: 0.07)
        post(.leftMouseUp, position)
    }

    /// Camera eases to `zoom` around (x, y) over `duration`, while the tour continues.
    func zoom(_ zoom: Double, _ x: Double, _ y: Double, _ duration: Double) {
        let t = now()
        camera.append([t, cameraNow.zoom, cameraNow.x, cameraNow.y])
        camera.append([t + duration, zoom, x, y])
        cameraNow = (zoom, x, y)
    }
}

/// The tour, in window points (KlaD at 1440×900).
func tour(_ d: Director, size: CGSize) {
    let cx = Double(size.width / 2), cy = Double(size.height / 2)
    d.wait(0.7)
    // Sunburst: hover a few rings, then drill into Projects and back out.
    d.zoom(1.45, 459, 519, 1.3)
    d.move(540, 405, 1.0); d.wait(0.45)
    d.move(360, 420, 0.8); d.wait(0.45)
    d.move(504, 567, 0.8); d.wait(0.3)
    d.click(); d.wait(1.3)
    d.move(387, 468, 0.7); d.wait(0.6)
    d.move(459, 519, 0.6); d.wait(0.3)
    d.click(); d.wait(1.1)
    // Treemap.
    d.zoom(1, cx, cy, 1.0)
    d.move(720, 26, 1.1); d.wait(0.3)
    d.click(); d.wait(0.8)
    d.zoom(1.3, 450, 522, 1.0)
    d.move(357, 333, 0.9); d.wait(0.5)
    d.move(320, 459, 0.6); d.wait(0.4)
    d.move(308, 630, 0.7); d.wait(0.6)
    // Recommendations.
    d.zoom(1, cx, cy, 0.9)
    d.move(102, 280, 1.0); d.wait(0.25)
    d.click(); d.wait(0.6)
    d.zoom(1.35, 700, 450, 1.0)
    d.move(560, 300, 0.8); d.wait(0.2)
    d.move(560, 650, 1.6); d.wait(0.5)
    // Uninstaller.
    d.zoom(1, cx, cy, 0.9)
    d.move(91, 183, 1.0); d.wait(0.25)
    d.click(); d.wait(0.9)
    d.move(280, 346, 0.8); d.wait(0.25)
    d.click(); d.wait(0.3)
    d.zoom(1.4, 936, 330, 1.0); d.wait(1.0)
    d.move(1224, 579, 1.2); d.wait(1.6)
    d.zoom(1, cx, cy, 1.0); d.wait(1.4)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: record-demo <out.mov> <timeline.json>"); exit(2) }
guard CGPreflightPostEventAccess() else { print("error: Accessibility access is needed to move the mouse"); exit(1) }
if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
    print("error: the screen is locked"); exit(1)
}
guard let target = findKlaDWindow() else { print("error: KlaD's window isn't on screen"); exit(1) }

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let window = content.windows.first(where: { $0.windowID == target.windowID }),
      let klad = window.owningApplication,
      let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) }) else {
    print("error: ScreenCaptureKit can't see KlaD's window"); exit(1)
}
let scale = NSScreen.screens.first { $0.frame.width > 0 }?.backingScaleFactor ?? 2
let width = Int(target.frame.width * scale), height = Int(target.frame.height * scale)

let config = SCStreamConfiguration()
config.width = width
config.height = height
config.showsCursor = false
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.pixelFormat = kCVPixelFormatType_32BGRA
config.queueDepth = 8
// Capture KlaD's region of the whole display with every other window left out.
// Capturing KlaD's windows directly makes macOS badge its traffic lights.
config.sourceRect = CGRect(x: target.frame.minX - display.frame.minX, y: target.frame.minY - display.frame.minY,
                           width: target.frame.width, height: target.frame.height)
config.backgroundColor = .clear

let recorder = try Recorder(url: URL(fileURLWithPath: args[1]), width: width, height: height)
let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID != klad.processID }),
                      configuration: config, delegate: nil)
try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "klad.record"))

// Put the cursor in place and make KlaD key before recording starts.
let director = Director(window: target.frame, start: CGPoint(x: 1180, y: 760))
// Click an empty toolbar area until KlaD's window is key (active traffic
// lights). Being the frontmost app isn't enough: the window can be main but not key.
func windowIsKey() -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == klad.processID else { return false }
    var focused: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(klad.processID), kAXFocusedWindowAttribute as CFString, &focused)
    return focused != nil
}
// Always click once: `open` can leave the window main but not key.
director.move(1100, 18, 0.3); director.click(); director.wait(0.6)
for _ in 0..<4 where !windowIsKey() {
    director.move(1100, 18, 0.3); director.click(); director.wait(0.6)
}
guard windowIsKey() else { print("error: couldn't make KlaD's window key"); exit(1) }
director.move(1180, 760, 0.3); director.wait(0.8)
director.cursor = []; director.clicks = []

try await stream.startCapture()
let recordingStart = now()
director.wait(0.2)
if ProcessInfo.processInfo.environment["KLAD_RECORD_QUICK"] != nil { director.wait(1) } else { tour(director, size: target.frame.size) }
let end = now()
try await stream.stopCapture()
recorder.finish()

guard let t0 = recorder.firstFrameTime else { print("error: no frames were captured"); exit(1) }
let timeline: [String: Any] = [
    "window": [Double(target.frame.width), Double(target.frame.height)],
    "pixels": [width, height],
    "duration": end - t0,
    "cursor": director.cursor.map { [$0[0] - t0, $0[1], $0[2]] },
    "clicks": director.clicks.map { $0 - t0 },
    "camera": director.camera.map { [$0[0] - t0, $0[1], $0[2], $0[3]] },
]
try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: args[2]))
print("recorded \(recorder.frames) frames, \(String(format: "%.1f", end - recordingStart)) s → \(args[1])")
