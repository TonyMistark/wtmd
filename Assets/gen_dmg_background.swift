// Generate the DMG window background.
//
// Visual concept follows docs/PRODUCT.md and Assets/gen_icon.py: "dashed line
// -> wtmd -> solid line". The same rule appears here in the middle of the
// window, starting dashed on the left and resolving into a solid stroke that
// ends in an arrowhead pointing at the Applications folder.
//
// Run:  swift Assets/gen_dmg_background.swift [output-dir]
// Writes: dmg-background.png (1x), dmg-background@2x.png, dmg-background.tiff
// (HiDPI, what the DMG actually ships) into the output directory.
//
// The .tiff is a multi-resolution image; without it the background looks soft
// on Retina displays.

import AppKit
import CoreText
import Foundation

// MARK: - design space

/// The DMG window's content area, in points. 660 x 440 is wide enough for the
/// icon pair with room to breathe, and short enough to stay a pleasant window.
let W: CGFloat = 660
let H: CGFloat = 440

// Icon slots, measured from the content area's top-left corner. These MUST
// match `DMG_ICON_SIZE` / `DMG_APP_CENTER_X` / `DMG_APPS_CENTER_X` /
// `DMG_ICON_ROW_Y` in make-dmg.sh — the Finder places the real icons there.
let iconSize: CGFloat = 128
let appCenterX: CGFloat = 170
let appsCenterX: CGFloat = 490
let iconRowY: CGFloat = 200

// Vertical gradient, top to bottom; same palette as Assets/gen_icon.py.
let bgTop = NSColor(srgbRed: 46 / 255, green: 54 / 255, blue: 72 / 255, alpha: 1)
let bgBottom = NSColor(srgbRed: 19 / 255, green: 23 / 255, blue: 32 / 255, alpha: 1)

/// Ink colour for the rule, matching the app icon.
func ink(_ alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: 242 / 255, green: 245 / 255, blue: 250 / 255, alpha: alpha)
}

/// Convert a "distance from the top edge" into the context's bottom-left origin.
func fromTop(_ y: CGFloat) -> CGFloat { H - y }

// MARK: - drawing helpers

struct TextSpec {
    var size: CGFloat
    var weight: NSFont.Weight = .regular
    var color: NSColor
    var tracking: CGFloat = 0
}

/// Draw `text` horizontally centred at `centerX`, with its cap top at `topY`
/// (measured from the content area's top edge). Returns the drawn size.
@discardableResult
func drawCentered(
    _ text: String,
    spec: TextSpec,
    centerX: CGFloat,
    topY: CGFloat,
    in ctx: CGContext
) -> CGSize {
    let font = NSFont.systemFont(ofSize: spec.size, weight: spec.weight)
    var attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: spec.color,
    ]
    if spec.tracking != 0 { attrs[.kern] = spec.tracking }

    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attrs)
    )
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

    ctx.textPosition = CGPoint(x: centerX - width / 2, y: fromTop(topY) - ascent)
    CTLineDraw(line, ctx)
    return CGSize(width: width, height: ascent + descent)
}

func drawBackground(in ctx: CGContext) {
    // gen_icon.py uses a slightly non-linear ramp (`t ** 0.85`) so the darker
    // half dominates; approximate it with extra stops.
    let positions: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
    let stops = positions.map { p -> CGColor in
        let t = pow(p, 0.85)
        return NSColor(
            srgbRed: bgTop.redComponent + (bgBottom.redComponent - bgTop.redComponent) * t,
            green: bgTop.greenComponent + (bgBottom.greenComponent - bgTop.greenComponent) * t,
            blue: bgTop.blueComponent + (bgBottom.blueComponent - bgTop.blueComponent) * t,
            alpha: 1
        ).cgColor
    }
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let gradient = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: positions)
    else { fatalError("could not build the background gradient") }

    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: H),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
}

/// The product motif: dashed on the left (thoughts in flight), solid on the
/// right (a composed document), ending in an arrowhead.
func drawRule(in ctx: CGContext, from x0: CGFloat, to x1: CGFloat, y topY: CGFloat) {
    let y = fromTop(topY)
    let span = x1 - x0
    let headLength: CGFloat = 15
    let headHalfHeight: CGFloat = 9

    /// Ink that brightens from left to right, so the eye follows the arrow.
    func tone(at x: CGFloat) -> NSColor {
        let t = min(max((x - x0) / span, 0), 1)
        return ink(0.42 + 0.58 * t)
    }

    ctx.setLineCap(.round)

    // Dashed half.
    let segments = 5
    let gap: CGFloat = 7
    let dashEnd = x0 + span * 0.50
    let segLen = (dashEnd - x0 - gap * CGFloat(segments - 1)) / CGFloat(segments)
    for i in 0..<segments {
        let x = x0 + CGFloat(i) * (segLen + gap)
        ctx.setStrokeColor(tone(at: x + segLen / 2).cgColor)
        ctx.setLineWidth(3.4)
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + segLen, y: y))
        ctx.strokePath()
    }

    // Solid half, running into the arrowhead.
    let solidStart = x0 + span * 0.60
    let solidEnd = x1 - headLength + 3
    ctx.setStrokeColor(tone(at: (solidStart + solidEnd) / 2).cgColor)
    ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: solidStart, y: y))
    ctx.addLine(to: CGPoint(x: solidEnd, y: y))
    ctx.strokePath()

    ctx.setFillColor(ink(1).cgColor)
    ctx.move(to: CGPoint(x: x1, y: y))
    ctx.addLine(to: CGPoint(x: x1 - headLength, y: y + headHalfHeight))
    ctx.addLine(to: CGPoint(x: x1 - headLength, y: y - headHalfHeight))
    ctx.closePath()
    ctx.fillPath()
}

func draw(in ctx: CGContext) {
    drawBackground(in: ctx)

    // Headline: what to do with the two icons below. Every hint is bilingual —
    // Chinese first, then an English line underneath, so the DMG reads for
    // someone who cannot read the Chinese at all.
    drawCentered(
        "把 wtmd 拖进右侧的「应用程序」",
        spec: TextSpec(size: 15, weight: .medium, color: ink(0.86)),
        centerX: W / 2,
        topY: 50,
        in: ctx
    )
    drawCentered(
        "Drag wtmd into the Applications folder on the right",
        spec: TextSpec(size: 11.5, color: ink(0.46)),
        centerX: W / 2,
        topY: 74,
        in: ctx
    )

    // The rule sits between the two icon slots. The Finder draws the real
    // icons on top of it; the arrow only bridges the gap between them.
    let halfGap = iconSize / 2 + 22
    drawRule(in: ctx, from: appCenterX + halfGap, to: appsCenterX - halfGap, y: iconRowY)

    // First-launch guidance. The build is ad-hoc signed (no Developer ID, so
    // no notarisation), which means Gatekeeper holds it on first open on any
    // other Mac. Keep the two escape hatches visible right where the user is
    // looking, and spell both of them out in README > 安装.
    drawCentered(
        "首次打开若被 macOS 拦截（「无法验证开发者」「已损坏」）",
        spec: TextSpec(size: 12, color: NSColor(srgbRed: 152 / 255, green: 162 / 255, blue: 182 / 255, alpha: 1)),
        centerX: W / 2,
        topY: 304,
        in: ctx
    )
    drawCentered(
        "系统设置 › 隐私与安全性 › 仍要打开　·　xattr -cr /Applications/wtmd.app",
        spec: TextSpec(size: 12, color: NSColor(srgbRed: 122 / 255, green: 133 / 255, blue: 155 / 255, alpha: 1)),
        centerX: W / 2,
        topY: 324,
        in: ctx
    )
    drawCentered(
        "If macOS blocks the first launch (\"unidentified developer\" / \"damaged\")",
        spec: TextSpec(size: 10.5, color: NSColor(srgbRed: 130 / 255, green: 140 / 255, blue: 160 / 255, alpha: 1)),
        centerX: W / 2,
        topY: 350,
        in: ctx
    )
    drawCentered(
        "System Settings › Privacy & Security › Open Anyway　·　xattr -cr /Applications/wtmd.app",
        spec: TextSpec(size: 10.5, color: NSColor(srgbRed: 108 / 255, green: 119 / 255, blue: 140 / 255, alpha: 1)),
        centerX: W / 2,
        topY: 368,
        in: ctx
    )

    // Slogan, kept faint so it reads as texture rather than content.
    drawCentered(
        "WHERE THOUGHTS MEET DOCUMENTS",
        spec: TextSpec(size: 10, color: ink(0.26), tracking: 1.6),
        centerX: W / 2,
        topY: 400,
        in: ctx
    )
}

// MARK: - rendering

func render(scale: CGFloat) -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        fatalError("no sRGB colour space")
    }
    guard let ctx = CGContext(
        data: nil,
        width: Int(W * scale),
        height: Int(H * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create the bitmap context") }

    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    draw(in: ctx)

    guard let image = ctx.makeImage() else { fatalError("could not snapshot the context") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "gen_dmg_background", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "PNG encoding failed for \(url.lastPathComponent)",
        ])
    }
    try data.write(to: url)
    print("  \(url.lastPathComponent)  \(image.width)x\(image.height)")
}

// MARK: - main

let outDir = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets",
    isDirectory: true
)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

print("── 渲染 DMG 背景图（设计空间 \(Int(W))x\(Int(H))）…")
try writePNG(render(scale: 1), to: outDir.appendingPathComponent("dmg-background.png"))
try writePNG(render(scale: 2), to: outDir.appendingPathComponent("dmg-background@2x.png"))

// Combine both resolutions into the HiDPI TIFF the DMG ships.
let tiff = outDir.appendingPathComponent("dmg-background.tiff")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
task.arguments = [
    "-cathidpicheck",
    outDir.appendingPathComponent("dmg-background.png").path,
    outDir.appendingPathComponent("dmg-background@2x.png").path,
    "-out", tiff.path,
]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("tiffutil failed (\(task.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
print("  dmg-background.tiff  \(tiff.path)")
