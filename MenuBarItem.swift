// What the status item shows besides the mark: the song, scrolling when it does not fit, and a
// thin line for how far into it the phone is. Drawn into the same template image as the mark, so
// the menu bar colours all of it the way it colours every other item — light bar, dark bar,
// inactive display — with nothing here deciding a colour.

import AppKit

/// How much the status item says. The mark is always there; `song` adds the title beside it.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, song
    var id: String { rawValue }

    var label: String {
        switch self {
        case .icon: return "Icon"
        case .song: return "Song"
        }
    }

    var detail: String {
        switch self {
        case .icon:
            return "Just the mark."
        case .song:
            return "The mark, then the title and artist. A long one scrolls while music plays, "
                 + "unless Animation is Still."
        }
    }
}

/// The scroll of a line too long for its space, shared by the popover's title and the menu bar's.
/// One copy, so the two scroll at the same pace.
enum Marquee {
    /// Points per second. Slow enough to read, quick enough not to feel stuck.
    static let speed: CGFloat = 30
    /// Blank between the tail and the repeat, so the loop reads as a gap not a jump.
    static let gap: CGFloat = 34
    /// Time to read the beginning before it starts moving.
    static let leadIn: Double = 1.2
}

/// One frame of the status item.
struct MenuBarFrame {
    var levels: [CGFloat]
    var blend: CGFloat
    var connected: Bool
    /// "Title · Artist" in the song style while something is playing; nil shows the mark alone.
    var text: String?
    /// How far the text has scrolled, in points, or nil to sit still and truncate.
    var scroll: CGFloat?
    /// 0...1 into the song, or nil for no line.
    var progress: CGFloat?
}

enum MenuBarLayout {
    static let markSide: CGFloat = 18
    /// The mark shrinks when the line goes under it, so the two fit a 22pt bar without touching.
    static let markSideOverLine: CGFloat = 16
    static let textGap: CGFloat = 6
    /// Widest the song gets. Past this it scrolls (or truncates): a menu bar has neighbours.
    static let maxTextWidth: CGFloat = 160
    static let lineThickness: CGFloat = 1.5
    /// The edge fade of a scrolling title, so it leaves and arrives rather than being cut.
    static let fade: CGFloat = 10

    static var font: NSFont { NSFont.menuBarFont(ofSize: 0) }

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The image's width for a frame: the mark alone, or the mark and the space the text takes.
    static func width(textWidth: CGFloat?) -> CGFloat {
        guard let textWidth else { return markSide }
        return markSide + textGap + min(textWidth, maxTextWidth)
    }
}

/// Renders a frame as a template image `height` tall — the menu bar's own thickness, so the line
/// can sit at its bottom edge. `textWidth` is the caller's cached measurement of `frame.text`.
func menuBarImage(_ frame: MenuBarFrame, height: CGFloat, textWidth: CGFloat?) -> NSImage {
    typealias L = MenuBarLayout
    let text = frame.text
    let measured = text == nil ? nil : textWidth
    let width = L.width(textWidth: measured)
    let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.setFillColor(NSColor.black.cgColor)

        // The mark. Under a line (icon style only — the song's line runs under the text) it is
        // drawn smaller and nudged up, so neither touches the bar's edge nor the other.
        let lineUnderMark = text == nil && frame.progress != nil
        let side = lineUnderMark ? L.markSideOverLine : L.markSide
        let markRect = CGRect(x: (L.markSide - side) / 2,
                              y: (rect.height - side) / 2 - (lineUnderMark ? 1.5 : 0),
                              width: side, height: side)
        drawEqMark(in: ctx, rect: markRect, levels: frame.levels, blend: frame.blend,
                   connected: frame.connected)

        // A point off the bar's bottom edge: any higher and a descender in the title touches it.
        let lineY = rect.height - 1 - L.lineThickness
        if let text, let measured {
            let area = CGRect(x: L.markSide + L.textGap, y: 0,
                              width: min(measured, L.maxTextWidth), height: rect.height)
            let font = L.font
            let lineHeight = ceil(font.ascender - font.descender)
            // Optically centred, and lifted a little when a line has to fit underneath.
            let top = (rect.height - lineHeight) / 2 - (frame.progress != nil ? 2 : 0)
            drawSong(text, in: ctx, area: area, top: top, textWidth: measured, scroll: frame.scroll)
            if let progress = frame.progress {
                drawLine(in: ctx, from: area.minX, to: area.maxX, y: lineY, progress: progress)
            }
        } else if let progress = frame.progress {
            drawLine(in: ctx, from: markRect.minX + 1, to: markRect.maxX - 1, y: lineY,
                     progress: progress)
        }
        return true
    }
    image.isTemplate = true
    return image
}

private func drawSong(_ text: String, in ctx: CGContext, area: CGRect, top: CGFloat,
                      textWidth: CGFloat, scroll: CGFloat?) {
    typealias L = MenuBarLayout
    let font = L.font
    guard let scroll, textWidth > area.width else {
        // Still: a proper ellipsis rather than a glyph cut in half at the edge.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: CGRect(x: area.minX, y: top, width: area.width,
                                           height: ceil(font.ascender - font.descender) + 2),
                                withAttributes: [.font: font, .paragraphStyle: style])
        return
    }
    ctx.saveGState()
    ctx.clip(to: area)
    // A layer of its own, so the fades below erase only the text and not the mark beside it.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let x = area.minX - scroll
    (text as NSString).draw(at: CGPoint(x: x, y: top), withAttributes: attrs)
    (text as NSString).draw(at: CGPoint(x: x + textWidth + Marquee.gap, y: top), withAttributes: attrs)
    ctx.setBlendMode(.destinationOut)
    let colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors,
                                 locations: [0, 1]) {
        // The leading fade grows in with the first few points of travel, so the lead-in shows
        // the title's first letters whole and the fade never pops on.
        let lead = min(L.fade, scroll)
        if lead > 0 {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: area.minX, y: 0),
                                   end: CGPoint(x: area.minX + lead, y: 0), options: [])
        }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: area.maxX, y: 0),
                               end: CGPoint(x: area.maxX - L.fade, y: 0), options: [])
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// A track at a third of the ink and the elapsed part at full ink. Template images keep only
/// alpha, so this is the one way to draw two tones that the menu bar will still recolour.
private func drawLine(in ctx: CGContext, from x0: CGFloat, to x1: CGFloat, y: CGFloat,
                      progress: CGFloat) {
    let t = MenuBarLayout.lineThickness
    let track = CGRect(x: x0, y: y, width: x1 - x0, height: t)
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(CGPath(roundedRect: track, cornerWidth: t / 2, cornerHeight: t / 2, transform: nil))
    ctx.fillPath()
    let done = (x1 - x0) * min(max(progress, 0), 1)
    guard done > 0 else { return }
    ctx.setFillColor(NSColor.black.cgColor)
    let filled = CGRect(x: x0, y: y, width: max(done, t), height: t)
    ctx.addPath(CGPath(roundedRect: filled, cornerWidth: t / 2, cornerHeight: t / 2, transform: nil))
    ctx.fillPath()
}
