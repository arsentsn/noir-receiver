// The Blinds (B7 "Freeze-Frame") — the Noir Player logo, geometry lifted verbatim from the
// Android launcher vectors (ic_launcher_foreground.xml and ic_launcher_monochrome.xml):
// seven bars, three closed to 0.30 of the full weight and four open, clipped to a play
// triangle. One source of truth for both the popover's placeholder and the .icns renderer
// (RenderIcon.swift).
//
// It replaced B8 "Ramp", whose seven bars eased in from a 1.2 hairline to an 8 slab. Two
// cuts rather than one is the same change: see `branding/identity-system.html` §02.

import AppKit

enum BlindsGlyph {
    /// Which of the mark's two cuts to draw.
    ///
    /// The mark is one mark; the cut compensates for a ground that starves it. `display` is
    /// everything on a dark ground at every size — the .icns, the launcher, the splash.
    /// `compensated` opens the three closed bars from 2.4 to 3.5 for the two cases where the
    /// thin bars otherwise disappear: tint (a template image, whose ink the system replaces)
    /// and any light ground. It is a contrast rule, not a size rule — a big icon on a light
    /// ground needs it and a small one on black does not.
    enum Cut {
        case display
        case compensated

        /// Bar y-ranges in the vector's 0–100, y-down glyph space. Centres are 14…86 at a
        /// pitch of 12 for both; only the closed weight differs.
        var bars: [(CGFloat, CGFloat)] {
            let closed: CGFloat = self == .display ? 2.4 : 3.5
            return [14, 26, 38].map { ($0 - closed / 2, $0 + closed / 2) }
                + [50, 62, 74, 86].map { ($0 - 4, $0 + 4) }
        }

        /// The glyph-space point to put on the drawing rect's centre.
        ///
        /// The mark's own ink centroid with the same 4-unit downward eye-tune the Android
        /// launcher carries — the heavy bottom bars pull the centroid low and left, so bbox
        /// centering reads left-heavy. Both pairs come from `scripts/mark-lab.py --place`,
        /// which reproduces the translates in the Android drawables; the cuts do not share
        /// one, because moving 1.1 units of weight into three bars moves the centroid.
        var anchor: CGPoint {
            switch self {
            case .display: return CGPoint(x: 42.70, y: 55.87 - 4)
            case .compensated: return CGPoint(x: 42.37, y: 54.41 - 4)
            }
        }
    }

    /// Play-triangle clip, same space: (18,10) (18,90) (88,50).
    private static var clip: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 18, y: 10))
        p.addLine(to: CGPoint(x: 18, y: 90))
        p.addLine(to: CGPoint(x: 88, y: 50))
        p.closeSubpath()
        return p
    }

    /// Draws the glyph into a y-up context, ink-centred on `rect`'s centre,
    /// scaled so 100 glyph units span min(rect dimensions) × `scale`.
    /// Fill color must be set by the caller.
    static func draw(in ctx: CGContext, rect: CGRect, scale: CGFloat = 1.0,
                     cut: Cut = .display, grade: CGColor? = nil) {
        let s = min(rect.width, rect.height) / 100 * scale
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: s, y: -s)                 // -s: glyph space is y-down
        ctx.translateBy(x: -cut.anchor.x, y: -cut.anchor.y)
        ctx.addPath(clip)
        ctx.clip()
        if let ink = grade {
            // Clip to the bars and lay one ramp across all seven, rather than filling each —
            // a per-bar gradient would restart the ramp inside every bar and read as seven
            // marks. Both clips intersect, so the triangle still cuts the right edge.
            let bars = CGMutablePath()
            for (y0, y1) in cut.bars {
                bars.addRect(CGRect(x: 0, y: y0, width: 100, height: y1 - y0))
            }
            ctx.addPath(bars)
            ctx.clip()
            let ramp = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [ink,
                         ink.copy(alpha: gradeKneeAlpha)!,
                         ink.copy(alpha: gradeBaseAlpha)!] as CFArray,
                locations: [0, gradeKnee, 1])!
            ctx.drawLinearGradient(ramp, start: CGPoint(x: 0, y: gradeTop),
                                   end: CGPoint(x: 0, y: gradeBottom), options: [])
        } else {
            for (y0, y1) in cut.bars {
                ctx.fill(CGRect(x: 0, y: y0, width: 100, height: y1 - y0))
            }
        }
        ctx.restoreGState()
    }

    // The tonal grade — `branding/identity-system.html` §05, and the third copy of one curve.
    //
    // The rule it follows (decided 2026-09-04): the grade appears wherever the mark supplies its
    // own colour, and is absent wherever something else does. So the .icns passes `grade:` — ink
    // on its own black squircle — while the popover placeholder and the menu-bar equalizer do
    // not: both are template images the system re-colours, and a ramp in a template is not ours
    // to draw. That is why this is a parameter and not a property of the glyph.
    //
    // Alpha on the caller's ink, not §05's literal greys, because the greys only work on black
    // against a white mark and this ink is #F0F1F3.
    //
    // **Three copies of the curve exist and this is the one nothing can check.** Kotlin's is
    // `AppDrawer.kt`'s `markGrade` and the drawables' is in `ic_launcher_foreground.xml` — those
    // two are bound together by `MarkGradeXmlTest`, which reads the constants out of the Kotlin
    // and asserts them against the XML. The store PNGs are *not* a fourth copy: the website's
    // `render-brand-icons.mjs` reads the stops out of the launcher vector, so they can go stale
    // but not disagree. Swift is outside all of it, so these five numbers are the ones to check
    // by hand if the curve ever moves — `identity-system.html` §10's "the manifest has no test"
    // is now mostly about this file.
    private static let gradeTop: CGFloat = 10
    private static let gradeBottom: CGFloat = 90
    private static let gradeKnee: CGFloat = 0.45
    private static let gradeKneeAlpha: CGFloat = 0.99
    private static let gradeBaseAlpha: CGFloat = 0.66
}
