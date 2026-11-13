// render-demo.swift — Screen-Studio-style demo videos from KlaD screenshots.
//
//   swift Scripts/render-demo.swift tour  <raw-dir> <light|dark> <out.mp4>
//   swift Scripts/render-demo.swift still <image.png> <light|dark> <out.png>
//   swift Scripts/render-demo.swift recording <capture.mov> <light|dark> <out.mp4>
//       (a live capture from Scripts/record-demo.swift; reads <capture>.json)
//
// Screenshots come from Scripts/capture-demo.sh (2880×1800 window captures of
// the fictional --demo Mac). The camera eases in and out toward the cursor,
// clicks press the cursor and ripple, and app states crossfade.

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Canvas

let canvas = CGSize(width: 1920, height: 1200)
let fps = 30.0

struct Theme {
    let top: (CGFloat, CGFloat, CGFloat)
    let bottom: (CGFloat, CGFloat, CGFloat)
    let glow: (CGFloat, CGFloat, CGFloat, CGFloat)
    let ripple: (CGFloat, CGFloat, CGFloat)

    static let light = Theme(top: (0.80, 0.84, 1.00), bottom: (0.99, 0.86, 0.80),
                             glow: (1.0, 1.0, 1.0, 0.55), ripple: (0.0, 0.48, 1.0))
    static let dark = Theme(top: (0.10, 0.08, 0.22), bottom: (0.02, 0.13, 0.18),
                            glow: (0.45, 0.30, 0.95, 0.35), ripple: (0.25, 0.62, 1.0))
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot read \(path)")
    }
    return image
}

/// Where the window screenshot sits on the canvas (before camera zoom).
struct Placement {
    let scale: CGFloat
    let origin: CGPoint
    init(image: CGImage) { self.init(size: CGSize(width: image.width, height: image.height)) }
    init(size: CGSize) {
        let maxW = canvas.width * 0.86, maxH = canvas.height * 0.86
        scale = min(maxW / size.width, maxH / size.height)
        let w = size.width * scale, h = size.height * scale
        origin = CGPoint(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2 + 8)
    }
    func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
}

// MARK: - Easing & keyframes

func easeInOut(_ t: Double) -> Double {
    let x = max(0, min(1, t))
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}

struct Key<V> { let t: Double; let v: V }

func interpolate(_ keys: [Key<CGPoint>], at t: Double) -> CGPoint {
    guard let first = keys.first else { return .zero }
    if t <= first.t { return first.v }
    for (a, b) in zip(keys, keys.dropFirst()) where t <= b.t {
        let k = CGFloat(easeInOut((t - a.t) / max(0.0001, b.t - a.t)))
        // A gentle arc, like a hand moving a mouse.
        let mid = CGPoint(x: (a.v.x + b.v.x) / 2, y: (a.v.y + b.v.y) / 2 - abs(b.v.x - a.v.x) * 0.08)
        let u = 1 - k
        return CGPoint(x: u * u * a.v.x + 2 * u * k * mid.x + k * k * b.v.x,
                       y: u * u * a.v.y + 2 * u * k * mid.y + k * k * b.v.y)
    }
    return keys.last!.v
}

struct Camera { var zoom: CGFloat; var focus: CGPoint }

func interpolate(_ keys: [Key<Camera>], at t: Double) -> Camera {
    guard let first = keys.first else { return Camera(zoom: 1, focus: CGPoint(x: canvas.width / 2, y: canvas.height / 2)) }
    if t <= first.t { return first.v }
    for (a, b) in zip(keys, keys.dropFirst()) where t <= b.t {
        let k = CGFloat(easeInOut((t - a.t) / max(0.0001, b.t - a.t)))
        return Camera(zoom: a.v.zoom + (b.v.zoom - a.v.zoom) * k,
                      focus: CGPoint(x: a.v.focus.x + (b.v.focus.x - a.v.focus.x) * k,
                                     y: a.v.focus.y + (b.v.focus.y - a.v.focus.y) * k))
    }
    return keys.last!.v
}

// MARK: - Storyboard

struct Storyboard {
    var duration: Double
    var shots: [Key<String>]          // image name shown from t (crossfades in)
    var cursor: [Key<CGPoint>]        // in screenshot pixels
    var clicks: [Double]
    var camera: [Key<Camera>]         // focus in screenshot pixels
}

/// A tour of the app. Coordinates are in 2880×1800 screenshot pixels.
func tour() -> Storyboard {
    let projects = CGPoint(x: 1008, y: 1134), center = CGPoint(x: 918, y: 1039)
    let treemapButton = CGPoint(x: 1440, y: 52), recommendations = CGPoint(x: 203, y: 560)
    let uninstall = CGPoint(x: 182, y: 365), vlcButton = CGPoint(x: 2448, y: 1157)
    let whole = CGPoint(x: 1440, y: 900)
    func cam(_ t: Double, _ z: CGFloat, _ p: CGPoint) -> Key<Camera> { Key(t: t, v: Camera(zoom: z, focus: p)) }
    return Storyboard(
        duration: 21,
        shots: [Key(t: 0, v: "sunburst"), Key(t: 2.15, v: "sunburst-focus"), Key(t: 4.45, v: "sunburst"),
                Key(t: 6.55, v: "treemap"), Key(t: 11.25, v: "recommendations"), Key(t: 15.45, v: "uninstaller")],
        cursor: [Key(t: 0, v: CGPoint(x: 2350, y: 1650)), Key(t: 0.6, v: CGPoint(x: 2300, y: 1600)),
                 Key(t: 1.9, v: projects), Key(t: 3.4, v: projects), Key(t: 4.2, v: center), Key(t: 5.0, v: center),
                 Key(t: 6.2, v: treemapButton), Key(t: 7.0, v: treemapButton), Key(t: 8.2, v: CGPoint(x: 760, y: 640)),
                 Key(t: 9.4, v: CGPoint(x: 1180, y: 700)), Key(t: 10.9, v: recommendations), Key(t: 12.6, v: recommendations),
                 Key(t: 13.4, v: CGPoint(x: 1500, y: 690)), Key(t: 14.2, v: CGPoint(x: 1500, y: 1250)),
                 Key(t: 15.1, v: uninstall), Key(t: 16.6, v: uninstall), Key(t: 17.8, v: vlcButton), Key(t: 21, v: vlcButton)],
        clicks: [2.1, 4.4, 6.5, 11.2, 15.4],
        camera: [cam(0, 1, whole), cam(0.8, 1, whole), cam(2.0, 1.55, center), cam(4.6, 1.55, center),
                 cam(5.6, 1, whole), cam(6.9, 1, whole), cam(7.9, 1.3, CGPoint(x: 1000, y: 1000)), cam(9.6, 1.3, CGPoint(x: 1000, y: 1000)),
                 cam(10.5, 1, whole), cam(11.6, 1, whole), cam(12.6, 1.4, CGPoint(x: 1400, y: 900)), cam(14.3, 1.4, CGPoint(x: 1400, y: 1000)),
                 cam(15.0, 1, whole), cam(15.8, 1, whole), cam(16.8, 1.45, CGPoint(x: 1900, y: 800)), cam(19.6, 1.45, CGPoint(x: 1950, y: 850)),
                 cam(20.6, 1, whole)]
    )
}

// MARK: - Drawing

func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
    // Context is flipped (top-left origin); images must be drawn un-flipped.
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

func drawBackdrop(_ ctx: CGContext, _ theme: Theme) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [CGColor(red: theme.top.0, green: theme.top.1, blue: theme.top.2, alpha: 1),
                  CGColor(red: theme.bottom.0, green: theme.bottom.1, blue: theme.bottom.2, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: canvas.width, y: canvas.height), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: theme.glow.0, green: theme.glow.1, blue: theme.glow.2, alpha: theme.glow.3),
        CGColor(red: theme.glow.0, green: theme.glow.1, blue: theme.glow.2, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: canvas.width * 0.3, y: canvas.height * 0.15), startRadius: 0,
                           endCenter: CGPoint(x: canvas.width * 0.3, y: canvas.height * 0.15), endRadius: canvas.width * 0.6, options: [])
}

/// Behind the window, under its shadow (matches the window background).
nonisolated(unsafe) var windowFill = CGColor(gray: 0.96, alpha: 1)

func drawWindow(_ ctx: CGContext, _ image: CGImage, _ placement: Placement, alpha: CGFloat, shadow: Bool) {
    let rect = CGRect(x: placement.origin.x, y: placement.origin.y,
                      width: CGFloat(image.width) * placement.scale, height: CGFloat(image.height) * placement.scale)
    // macOS window corners (about 21 pt): shadow from the shape, then the window clipped to it.
    let radius = 21 * 2 * placement.scale
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 70, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        ctx.setFillColor(windowFill)
        ctx.addPath(shape); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.interpolationQuality = .high
    drawImage(ctx, image, in: rect, alpha: alpha)
    ctx.restoreGState()
}

/// The macOS arrow cursor, tip at `p`.
func drawCursor(_ ctx: CGContext, at p: CGPoint, size: CGFloat, pressed: CGFloat) {
    let s = size / 20 * (1 - 0.14 * pressed)
    let points: [CGPoint] = [(0, 0), (0, 17.2), (4.1, 13.4), (6.9, 19.9), (9.7, 18.7), (7.0, 12.3), (12.4, 12.3)]
        .map { CGPoint(x: p.x + $0.0 * s, y: p.y + $0.1 * s) }
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 3 * s), blur: 6 * s, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(path); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(1.6 * s)
    ctx.addPath(path); ctx.strokePath()
    ctx.restoreGState()
}

func drawRipple(_ ctx: CGContext, at p: CGPoint, progress: Double, theme: Theme, scale: CGFloat) {
    let k = CGFloat(1 - pow(1 - progress, 3))
    let radius = (10 + 46 * k) * scale
    let alpha = 0.55 * (1 - CGFloat(progress))
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: theme.ripple.0, green: theme.ripple.1, blue: theme.ripple.2, alpha: alpha * 0.35))
    ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    ctx.setStrokeColor(CGColor(red: theme.ripple.0, green: theme.ripple.1, blue: theme.ripple.2, alpha: alpha))
    ctx.setLineWidth(3 * scale)
    ctx.strokeEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    ctx.restoreGState()
}

func makeContext(data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext {
    let ctx = CGContext(data: data, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: canvas.height)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func renderFrame(_ ctx: CGContext, t: Double, board: Storyboard, images: [String: CGImage], placement: Placement, theme: Theme) {
    let cam = interpolate(board.camera, at: t)
    let focus = placement.toCanvas(cam.focus)
    // Keep the zoomed canvas filling the frame.
    let half = CGSize(width: canvas.width / 2 / cam.zoom, height: canvas.height / 2 / cam.zoom)
    let fx = min(max(focus.x, half.width), canvas.width - half.width)
    let fy = min(max(focus.y, half.height), canvas.height - half.height)

    ctx.saveGState()
    ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
    ctx.scaleBy(x: cam.zoom, y: cam.zoom)
    ctx.translateBy(x: -fx, y: -fy)

    drawBackdrop(ctx, theme)
    let index = board.shots.lastIndex { $0.t <= t } ?? 0
    let current = images[board.shots[index].v]!
    let fade = 0.28
    if index > 0, t - board.shots[index].t < fade {
        let k = CGFloat(easeInOut((t - board.shots[index].t) / fade))
        drawWindow(ctx, images[board.shots[index - 1].v]!, placement, alpha: 1, shadow: true)
        drawWindow(ctx, current, placement, alpha: k, shadow: false)
    } else {
        drawWindow(ctx, current, placement, alpha: 1, shadow: true)
    }

    let cursor = placement.toCanvas(interpolate(board.cursor, at: t))
    var pressed: CGFloat = 0
    for click in board.clicks where t >= click - 0.12 && t < click + 0.6 {
        let local = t - click
        if local < 0.14 { pressed = CGFloat(easeInOut((local + 0.12) / 0.12)) } else { pressed = max(0, 1 - CGFloat((local - 0.14) / 0.12)) }
        if local >= 0 && local < 0.55 { drawRipple(ctx, at: cursor, progress: local / 0.55, theme: theme, scale: 1 / max(1, cam.zoom * 0.8)) }
    }
    drawCursor(ctx, at: cursor, size: 30 / max(1, cam.zoom * 0.75), pressed: pressed)
    ctx.restoreGState()
}

// MARK: - Output

func writeVideo(board: Storyboard, images: [String: CGImage], theme: Theme, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 7_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(canvas.width), kCVPixelBufferHeightKey as String: Int(canvas.height),
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let placement = Placement(image: images.values.first!)
    let frames = Int(board.duration * fps)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(2_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { fatalError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = makeContext(data: CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        renderFrame(ctx, t: Double(frame) / fps, board: board, images: images, placement: placement, theme: theme)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { fatalError("writer failed: \(String(describing: writer.error))") }
}

func writeStill(image: CGImage, theme: Theme, to path: String) {
    let ctx = makeContext(data: nil, bytesPerRow: 0)
    drawBackdrop(ctx, theme)
    drawWindow(ctx, image, Placement(image: image), alpha: 1, shadow: true)
    let out = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Live recordings

struct Timeline: Decodable {
    let window: [Double]
    let pixels: [Double]
    let duration: Double
    let cursor: [[Double]]
    let clicks: [Double]
    let camera: [[Double]]
}

func cursorPosition(_ samples: [[Double]], at t: Double) -> CGPoint {
    guard let first = samples.first else { return .zero }
    if t <= first[0] { return CGPoint(x: first[1], y: first[2]) }
    var lo = 0, hi = samples.count - 1
    while lo < hi - 1 { let mid = (lo + hi) / 2; if samples[mid][0] <= t { lo = mid } else { hi = mid } }
    let a = samples[lo], b = samples[hi]
    let k = b[0] > a[0] ? max(0, min(1, (t - a[0]) / (b[0] - a[0]))) : 1
    return CGPoint(x: a[1] + (b[1] - a[1]) * k, y: a[2] + (b[2] - a[2]) * k)
}

/// Frames of a video, decoded in order, kept as CGImages with alpha.
final class FrameReader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    var current: CGImage?
    var pending: (time: Double, image: CGImage)?
    var start: Double?

    init(url: URL) throws {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task { track = try? await asset.loadTracks(withMediaType: .video).first; semaphore.signal() }
        semaphore.wait()
        guard let track else { fatalError("no video track in \(url.path)") }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
    }

    private func next() -> (Double, CGImage)? {
        guard let buffer = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if start == nil { start = time }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(pixels)!, count: bytesPerRow * height)
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return (time - start!, image)
    }

    /// The newest frame at or before `t` (seconds from the first frame).
    func frame(at t: Double) -> CGImage? {
        if current == nil, let first = next() { current = first.1 }
        while true {
            if pending == nil { pending = next().map { (time: $0.0, image: $0.1) } }
            guard let candidate = pending, candidate.time <= t else { break }
            current = candidate.image
            pending = nil
        }
        return current
    }
}

func renderRecording(capture: String, theme: Theme, to path: String) throws {
    let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: (capture as NSString).deletingPathExtension + ".json")))
    let frames = try FrameReader(url: URL(fileURLWithPath: capture))
    let pixelSize = CGSize(width: timeline.pixels[0], height: timeline.pixels[1])
    let pointScale = pixelSize.width / timeline.window[0]            // points → capture pixels
    let placement = Placement(size: pixelSize)
    let camera = timeline.camera.map { Key(t: $0[0], v: Camera(zoom: $0[1], focus: CGPoint(x: $0[2] * pointScale, y: $0[3] * pointScale))) }
        .sorted { $0.t < $1.t }
    let videoFPS = 60.0

    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(canvas.width), kCVPixelBufferHeightKey as String: Int(canvas.height),
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let count = Int(timeline.duration * videoFPS)
    for index in 0..<count {
        let t = Double(index) / videoFPS
        guard let image = frames.frame(at: t) else { break }
        while !input.isReadyForMoreMediaData { usleep(2_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { fatalError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = makeContext(data: CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))

        let cam = camera.isEmpty ? Camera(zoom: 1, focus: CGPoint(x: pixelSize.width / 2, y: pixelSize.height / 2)) : interpolate(camera, at: t)
        let focus = placement.toCanvas(cam.focus)
        let half = CGSize(width: canvas.width / 2 / cam.zoom, height: canvas.height / 2 / cam.zoom)
        let fx = min(max(focus.x, half.width), canvas.width - half.width)
        let fy = min(max(focus.y, half.height), canvas.height - half.height)
        ctx.saveGState()
        ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        ctx.scaleBy(x: cam.zoom, y: cam.zoom)
        ctx.translateBy(x: -fx, y: -fy)
        drawBackdrop(ctx, theme)
        drawWindow(ctx, image, placement, alpha: 1, shadow: true)

        let pointer = cursorPosition(timeline.cursor, at: t)
        let cursor = placement.toCanvas(CGPoint(x: pointer.x * pointScale, y: pointer.y * pointScale))
        var pressed: CGFloat = 0
        for click in timeline.clicks where t >= click - 0.12 && t < click + 0.6 {
            let local = t - click
            pressed = local < 0.14 ? CGFloat(easeInOut((local + 0.12) / 0.12)) : max(0, 1 - CGFloat((local - 0.14) / 0.12))
            if local >= 0 && local < 0.55 { drawRipple(ctx, at: cursor, progress: local / 0.55, theme: theme, scale: 1 / max(1, cam.zoom * 0.8)) }
        }
        drawCursor(ctx, at: cursor, size: 30 / max(1, cam.zoom * 0.75), pressed: pressed)
        ctx.restoreGState()

        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(videoFPS)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { fatalError("writer failed: \(String(describing: writer.error))") }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 5 else {
    print("usage: render-demo.swift tour <raw-dir> <light|dark> <out.mp4> | still <image> <light|dark> <out.png>")
    exit(2)
}
let theme = args[3] == "dark" ? Theme.dark : Theme.light
windowFill = args[3] == "dark" ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.96, alpha: 1)
switch args[1] {
case "tour":
    let board = tour()
    var images: [String: CGImage] = [:]
    for name in Set(board.shots.map(\.v)) { images[name] = loadImage("\(args[2])/\(name)-\(args[3]).png") }
    try writeVideo(board: board, images: images, theme: theme, to: args[4])
case "recording":
    try renderRecording(capture: args[2], theme: theme, to: args[4])
case "still":
    writeStill(image: loadImage(args[2]), theme: theme, to: args[4])
default:
    print("unknown mode \(args[1])"); exit(2)
}
print(args[4])
