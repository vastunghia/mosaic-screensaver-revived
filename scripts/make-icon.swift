// Draws the app icon: a mosaic whose centre tile is the whole mosaic again,
// and so on down to a pixel — the effect, zooming in, in one picture.
//
//     swift scripts/make-icon.swift <out.icns> [preview.png] [--tint <0...1>] [--side <pixels>] [--tiles <odd n>]
//
// The icon is drawn, not stored: the tile colours below are the only thing
// to edit. They were sampled from a sunset gradient drafted with an image
// generator, then the grid was redrawn regular, square and recursive.
// Options other than the outputs are for comparing variants.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Seven rows of seven, top to bottom. Odd, so that one tile is the centre.
/// The corners, hidden by the rounding when sampled, are their neighbours'
/// extrapolation: across plus down minus diagonal.
let palette: [[UInt32]] = [
    [0x0B2E84, 0x12368F, 0x18409A, 0x184BA9, 0x154BAA, 0x1648A7, 0x0A3D9C],
    [0x4B45A8, 0x524DB3, 0x5D53B9, 0x6A60C6, 0x655BC1, 0x5C51B8, 0x5046AD],
    [0x7C4BA8, 0x965BB3, 0xAC69BA, 0xB671BE, 0xAE66B8, 0x9C5AB0, 0x844EA9],
    [0xB0529D, 0xCC63A3, 0xE171A1, 0xE26FA0, 0xE36D9F, 0xD4639D, 0xBD5599],
    [0xDC5573, 0xEB6578, 0xF5757B, 0xF77779, 0xF46F75, 0xEE6573, 0xE2586F],
    [0xE75549, 0xF3644B, 0xFA774A, 0xFC8349, 0xFB7C46, 0xF76D47, 0xEC5F45],
    [0xEA5A20, 0xF66922, 0xFC8322, 0xFC9227, 0xFD9C23, 0xFB8519, 0xF07717],
]
/// Tiles per side: 5, chosen over 7 on a page of both at every size — the
/// miniature is larger, and its own miniature still shows. The palette is a
/// field of colour sampled at each tile's place, so any odd count works.
var tiles = 5

/// The palette's colour at a tile, interpolated between its samples.
func paletteColour(row: Int, column: Int) -> RGB {
    let last = CGFloat(palette.count - 1)
    let y = CGFloat(row) * last / CGFloat(tiles - 1), x = CGFloat(column) * last / CGFloat(tiles - 1)
    let y0 = min(Int(y), palette.count - 2), x0 = min(Int(x), palette.count - 2)
    let fy = y - CGFloat(y0), fx = x - CGFloat(x0)
    let top = mix(rgb(palette[y0][x0]), rgb(palette[y0][x0 + 1]), fx)
    let bottom = mix(rgb(palette[y0 + 1][x0]), rgb(palette[y0 + 1][x0 + 1]), fx)
    return mix(top, bottom, fy)
}

/// The macOS icon grid: an 824-point rounded square on a 1024-point canvas.
let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4

/// Grout, as a share of a tile's width, and how much darker than the tile.
let groutShare: CGFloat = 0.07
let groutShade: CGFloat = 0.78

/// How far each smaller mosaic leans towards the colour of the tile it
/// stands in for, as the solver picks a photograph whose mean matches its
/// cell. At 0 the miniature is the mosaic as it is, and stands out of its row
/// as a thing laid on top; 0.4 was chosen against 0 and 0.7.
var tint: CGFloat = 0.4

let space = CGColorSpace(name: CGColorSpace.sRGB)!

typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

func rgb(_ hex: UInt32) -> RGB {
    (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
}

func mix(_ a: RGB, _ b: RGB, _ amount: CGFloat) -> RGB {
    (a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount)
}

func color(_ c: RGB, shade: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [c.r * shade, c.g * shade, c.b * shade, 1])!
}

/// The mosaic in `rect`, its centre tile the mosaic again until a tile is
/// smaller than a pixel. Rows run top to bottom; the context's y runs up.
func drawMosaic(in rect: CGRect, context: CGContext, pixel: CGFloat, towards target: RGB? = nil) {
    let cell = rect.width / CGFloat(tiles)
    for row in 0..<tiles {
        for column in 0..<tiles {
            let frame = CGRect(
                x: rect.minX + CGFloat(column) * cell,
                y: rect.maxY - CGFloat(row + 1) * cell,
                width: cell, height: cell
            )
            var shown = paletteColour(row: row, column: column)
            if let target { shown = mix(shown, target, tint) }
            context.setFillColor(color(shown, shade: groutShade))
            context.fill(frame)
            let tile = frame.insetBy(dx: cell * groutShare / 2, dy: cell * groutShare / 2)
            if row == tiles / 2, column == tiles / 2, tile.width / CGFloat(tiles) >= pixel {
                drawMosaic(in: tile, context: context, pixel: pixel, towards: shown)
            } else {
                context.setFillColor(color(shown))
                context.fill(tile)
            }
        }
    }
}

func render(side: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(side) / canvas
    context.scaleBy(x: scale, y: scale)
    let shape = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // The shadow the system's icons cast, from the shape alone.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                      color: CGColor(colorSpace: space, components: [0, 0, 0, 0.35])!)
    context.addPath(shape)
    context.setFillColor(color((0, 0, 0)))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    drawMosaic(in: body, context: context, pixel: 1 / scale)
    context.restoreGState()
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

var arguments: [String] = []
var previewSide = 1024
var rest = CommandLine.arguments.makeIterator()
while let argument = rest.next() {
    switch argument {
    case "--tint": tint = rest.next().flatMap(Double.init).map { CGFloat($0) } ?? tint
    case "--side": previewSide = rest.next().flatMap(Int.init) ?? previewSide
    case "--tiles": tiles = rest.next().flatMap(Int.init).map { max(3, $0 | 1) } ?? tiles
    default: arguments.append(argument)
    }
}
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.icns> [preview.png] [--tint t] [--side n]\n".data(using: .utf8)!)
    exit(2)
}
let icns = URL(fileURLWithPath: arguments[1])
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// Each size drawn at its own resolution, not scaled down from the largest:
// the recursion stops at that size's pixel.
for points in [16, 32, 128, 256, 512] {
    writePNG(render(side: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(side: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if arguments.count >= 3 {
    writePNG(render(side: previewSide), to: URL(fileURLWithPath: arguments[2]))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
