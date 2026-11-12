// Generates Resources/AppIcon.icns — the KlaD sunburst mark on an obsidian squircle.
// Usage: swift Scripts/make-icon.swift Resources/AppIcon.icns
import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Squircle background (macOS icon grid: 824/1024 body).
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x141C2E), color(0x05070C)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    // Rings.
    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = body.width * 0.40
    let rings: [[(UInt32, CGFloat)]] = [
        [(0x06B6D4, 0.34), (0x8B5CF6, 0.22), (0x3B82F6, 0.18), (0xF59E0B, 0.14), (0x10B981, 0.12)],
        [(0x06B6D4, 0.2), (0x0EA5E9, 0.14), (0x8B5CF6, 0.16), (0xF97316, 0.12), (0x3B82F6, 0.1), (0xF59E0B, 0.1), (0x64748B, 0.18)],
        [(0x06B6D4, 0.12), (0x22D3EE, 0.08), (0x8B5CF6, 0.1), (0xA78BFA, 0.06), (0xF97316, 0.08), (0x3B82F6, 0.1), (0xF59E0B, 0.06), (0x10B981, 0.08), (0x64748B, 0.32)],
    ]
    for (index, ring) in rings.enumerated() {
        let inner = radius * (0.30 + CGFloat(index) * 0.235)
        let outer = inner + radius * 0.205
        var angle: CGFloat = .pi / 2
        for (hex, fraction) in ring {
            let span = fraction * 2 * .pi
            let path = CGMutablePath()
            path.addArc(center: center, radius: outer, startAngle: angle - 0.02, endAngle: angle - span + 0.02, clockwise: true)
            path.addArc(center: center, radius: inner, startAngle: angle - span + 0.02, endAngle: angle - 0.02, clockwise: false)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color(hex, 1 - CGFloat(index) * 0.16))
            ctx.fillPath()
            angle -= span
        }
    }
    let core = CGRect(x: center.x - radius * 0.2, y: center.y - radius * 0.2, width: radius * 0.4, height: radius * 0.4)
    ctx.setFillColor(color(0x070A10))
    ctx.fillEllipse(in: core)
    ctx.setStrokeColor(color(0x22D3EE, 0.8))
    ctx.setLineWidth(max(1, s / 256))
    ctx.strokeEllipse(in: core)
    ctx.restoreGState()
    // Hairline border.
    ctx.addPath(squircle)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(max(1, s / 512))
    ctx.strokePath()
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KlaD-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let outputURL = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(outputURL.path)" : "iconutil failed")
