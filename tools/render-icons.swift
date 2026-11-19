// Renders the app icon and menu-bar glyph from SVG using macOS's own SVG
// support (NSImage), so no extra tools are needed.
//
//   swift tools/render-icons.swift <app.svg> <menubar.svg> <out-dir>
//
// Produces <out-dir>/AppIcon.icns and <out-dir>/MenuBarIcon.png (18 pt, @2x rep).
import AppKit

func render(_ svg: URL, pixels: Int) -> NSBitmapImageRep {
    guard let image = NSImage(contentsOf: svg) else { fatalError("can't read \(svg.path)") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let args = CommandLine.arguments
guard args.count == 4 else {
    print("usage: render-icons.swift <app.svg> <menubar.svg> <out-dir>")
    exit(1)
}
let appSVG = URL(fileURLWithPath: args[1])
let menuSVG = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
let fm = FileManager.default
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

// App icon: an .iconset with every size macOS asks for, then iconutil.
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(render(appSVG, pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(appSVG, pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

// Menu-bar glyph: 18 pt, stored at 36 px (Retina); the app marks it as a template.
writePNG(render(menuSVG, pixels: 36), to: outDir.appendingPathComponent("MenuBarIcon.png"))
print("wrote \(outDir.path)/AppIcon.icns and MenuBarIcon.png")
