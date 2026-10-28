// Renders AppIcon.icns for the bundle: the Blinds in white on the black macOS
// squircle (Big Sur grid: 824/1024 content, ~22.5% corner radius). Run by
// build.sh; compiled together with BlindsGlyph.swift, never into the app.

import AppKit

@main
struct RenderIcon {
    static func main() throws {
        let iconset = "AppIcon.iconset"
        try? FileManager.default.removeItem(atPath: iconset)
        try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

        // (filename base, point size, pixel scale)
        let entries: [(String, Int, Int)] = [
            ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
            ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
            ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
            ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
            ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
        ]
        for (name, pt, scale) in entries {
            let px = pt * scale
            let png = render(px: px)
            try png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset, "-o", "AppIcon.icns"]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else {
            fatalError("iconutil failed")
        }
        try? FileManager.default.removeItem(atPath: iconset)
        print("rendered AppIcon.icns")
    }

    static func render(px: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        let size = CGFloat(px)

        // Big Sur icon grid: content squircle is 824/1024 of the canvas.
        let inset = size * 100.0 / 1024.0
        let content = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let radius = content.width * 185.4 / 824.0
        ctx.addPath(CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath()

        // Same modest glyph scale as the Android launcher (0.50), same ink color — and since
        // 2026-09-04 the same tonal grade, because this is ink on its own black squircle rather
        // than a template the system re-colours. The popover and menu-bar marks stay flat for
        // exactly that reason; see BlindsGlyph's `grade` note.
        let ink = CGColor(red: 0xF0 / 255.0, green: 0xF1 / 255.0, blue: 0xF3 / 255.0, alpha: 1)
        ctx.setFillColor(ink)
        BlindsGlyph.draw(in: ctx, rect: content, scale: 0.50, grade: ink)

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
