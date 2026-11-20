// snapshot <page URL> <output.png> <width> <height>
// Renders a local page with WebKit on a transparent background (2× pixels on
// a Retina screen). Used by demo/make.sh for the README header.

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5, let url = URL(string: args[1]),
      let width = Double(args[3]), let height = Double(args[4]) else {
    print("usage: snapshot <file:// URL> <output.png> <width> <height>")
    exit(2)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let size = NSSize(width: width, height: height)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                      backing: .buffered, defer: false)
let view = WKWebView(frame: NSRect(origin: .zero, size: size))
view.setValue(false, forKey: "drawsBackground")
window.contentView = view
window.alphaValue = 0  // kept on screen so WebKit renders, but invisible
window.orderFrontRegardless()
view.loadFileURL(url, allowingReadAccessTo: root)

/// Snapshots once the page has loaded and its images have decoded.
func capture() {
    view.evaluateJavaScript("document.readyState === 'complete' && [...document.images].every(i => i.complete)") { ready, _ in
        if ready as? Bool != true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: capture)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: snapshot)
    }
}

func snapshot() {
    view.takeSnapshot(with: nil) { image, _ in
        guard let tiff = image?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("snapshot failed"); exit(1)
        }
        try! png.write(to: URL(fileURLWithPath: args[2]))
        print("wrote \(args[2])")
        exit(0)
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: capture)
app.run()
