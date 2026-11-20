// Renders the README's demo frames and screenshots without screen recording:
// the real popup UI (Resources/web) is loaded in an offscreen WKWebView, driven
// by demo/scene.js, and composited over a mock desktop (demo/stage.html) the
// way the panel looks on screen (blurred, tinted backdrop, rounded corners,
// shadow). See demo/make.sh.
//
//   render <scene> <output dir> [fps]
//
// Writes <output dir>/00000.png… for an animated scene, or <output dir>/<scene>.png
// for a still. Frames are 2× (Retina) pixels.

import AppKit
import CoreImage
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: render <scene> <output dir> [fps]")
    exit(2)
}
let sceneName = args[1]
let outDir = URL(fileURLWithPath: args[2])
let fps = args.count > 3 ? Double(args[3]) ?? 30 : 30
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

let stageSize = NSSize(width: 1280, height: 820)
let panelWidth: CGFloat = 640
let panelTop: CGFloat = 24 + (820 - 24) * 0.2  // as PanelController: 20 % down the visible frame
let scale: CGFloat = 2

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let stage: WKWebView
    let popup: WKWebView
    var loads: [CheckedContinuation<Void, Never>] = []
    let ci = CIContext()

    override init() {
        stage = WKWebView(frame: NSRect(origin: .zero, size: stageSize))
        popup = WKWebView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 56))
        popup.setValue(false, forKey: "drawsBackground")
        super.init()
        stage.navigationDelegate = self
        popup.navigationDelegate = self
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.addSubview(stage)
        content.addSubview(popup)
        window.contentView = content
        // Kept on screen (so WebKit keeps rendering) but invisible.
        window.alphaValue = 0.0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderFrontRegardless()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !loads.isEmpty { loads.removeFirst().resume() }
    }

    func load(_ view: WKWebView, _ file: URL, access: URL) async {
        await withCheckedContinuation { continuation in
            loads.append(continuation)
            view.loadFileURL(file, allowingReadAccessTo: access)
        }
    }

    @discardableResult
    func js(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await view.callAsyncJavaScript(script, contentWorld: .page)
    }

    /// Waits until the page has laid out and painted the latest changes.
    func settle(_ view: WKWebView) async throws {
        try await js(view, "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));")
    }

    func snapshot(_ view: WKWebView) async throws -> CGImage {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: config)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw NSError(domain: "render", code: 1)
        }
        return cg
    }

    func run() async throws {
        await load(stage, root.appendingPathComponent("demo/stage.html"), access: root)
        let web = root.appendingPathComponent("Resources/web")
        await load(popup, web.appendingPathComponent("index.html"), access: web)

        let info = try await js(stage, "const s = scenes[name]; return { duration: s.duration ?? 0, still: !!s.still, dark: !!s.dark };",
                                arguments: ["name": sceneName]) as? [String: Any] ?? [:]
        let dark = info["dark"] as? Bool ?? false
        let still = info["still"] as? Bool ?? false
        let duration = info["duration"] as? Double ?? 0
        popup.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try await js(stage, "stage.setDark(\(dark))")

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let count = still ? 1 : Int((duration * fps).rounded())
        for index in 0..<count {
            let t = Double(index) / fps
            let frame = try await js(stage, "return scenes[name].frame(t);", arguments: ["name": sceneName, "t": t]) as? [String: Any] ?? [:]
            let visible = frame["visible"] as? Bool ?? false
            if visible {
                let state = frame["state"] ?? [:]
                let input = frame["input"] as? String ?? ""
                try await js(popup, """
                    QA.setState(state);
                    const box = document.getElementById("input");
                    if (box.value !== input) { box.value = input; box.dispatchEvent(new Event("input")); }
                    box.blur();
                    """, arguments: ["state": state, "input": input])
                try await settle(popup)
                // Freeze CSS animations (the pulsing dots) at this frame's time.
                try await js(popup, "for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; }", arguments: ["t": t])
                // Size the panel to the content (app.js naturalHeight), measured
                // here rather than waiting for the page's height message.
                // Like PanelController: don't shrink while an answer streams.
                let pending = (frame["state"] as? [String: Any])?["pending"]
                let streaming = pending != nil && !(pending is NSNull)
                // Repeated because the measurement depends on the size (a
                // scrollbar narrows the text and makes it wrap).
                for _ in 0..<4 {
                    let measuredValue = try await js(popup, """
                        const thread = document.getElementById("thread");
                        const style = getComputedStyle(thread);
                        const shown = !document.body.classList.contains("empty");
                        const h = document.getElementById("composer").offsetHeight + (shown
                          ? document.getElementById("thread-inner").offsetHeight
                            + parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) : 0);
                        return Math.min(Math.ceil(h), maxHeight);
                        """, arguments: ["maxHeight": 557])
                    let measured: CGFloat = CGFloat((measuredValue as? Double) ?? 56)
                    let current: CGFloat = popup.frame.height
                    let target: CGFloat = streaming ? Swift.max(measured, current) : measured
                    if popup.frame.height == target { break }
                    popup.setFrameSize(NSSize(width: panelWidth, height: target))
                    try await settle(popup)
                }
                // Grow until the thread no longer overflows (up to the cap).
                for _ in 0..<4 {
                    let overflowValue = try await js(popup, "const t = document.getElementById('thread'); return t.scrollHeight - t.clientHeight;")
                    let overflow: CGFloat = CGFloat((overflowValue as? Double) ?? 0)
                    let grown: CGFloat = Swift.min(popup.frame.height + overflow, 557)
                    if overflow <= 0 || grown <= popup.frame.height { break }
                    popup.setFrameSize(NSSize(width: panelWidth, height: grown))
                    try await settle(popup)
                }
                // Resizing changes the thread's scroll range; keep it at the bottom.
                try await js(popup, "const t = document.getElementById('thread'); t.scrollTop = t.scrollHeight;")
                try await settle(popup)
            }
            try await settle(stage)
            let background = try await snapshot(stage)
            let panel = visible ? try await snapshot(popup) : nil
            var image = composite(background: background, panel: panel,
                                  opacity: frame["opacity"] as? Double ?? 1, dark: dark)
            if still, let panel {
                // Stills: just the panel, with a margin of desktop around it.
                let margin = 56 * scale
                let crop = CGRect(x: ((stageSize.width - panelWidth) / 2) * scale - margin,
                                  y: panelTop * scale - margin,
                                  width: panelWidth * scale + 2 * margin,
                                  height: CGFloat(panel.height) + 2 * margin)
                image = image.cropping(to: crop) ?? image
            }
            let name = still ? "\(sceneName).png" : String(format: "%05d.png", index)
            try write(image, to: outDir.appendingPathComponent(name))
            if index % 30 == 0 { print("frame \(index)/\(count)") }
        }
        print("wrote \(count) frame(s) to \(outDir.path)")
    }

    @discardableResult
    func js(_ view: WKWebView, _ script: String, arguments: [String: Any]) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    /// The panel as it looks on screen: the desktop behind it blurred and
    /// tinted (NSVisualEffectView's popover material), rounded, with a shadow.
    func composite(background: CGImage, panel: CGImage?, opacity: Double, dark: Bool) -> CGImage {
        let width = Int(stageSize.width * scale), height = Int(stageSize.height * scale)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(background, in: full)
        guard let panel else { return ctx.makeImage()! }

        let panelHeight = CGFloat(panel.height)  // already in pixels
        let rect = CGRect(x: (stageSize.width - panelWidth) / 2 * scale,
                          y: CGFloat(height) - panelTop * scale - panelHeight,
                          width: panelWidth * scale, height: panelHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: 16 * scale, cornerHeight: 16 * scale, transform: nil)

        // Blurred, saturated backdrop.
        let source = CIImage(cgImage: background)
        let blurred = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 30 * scale])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6])
            .cropped(to: source.extent)
        let backdrop = ci.createCGImage(blurred, from: source.extent)!

        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // Shadow, drawn from an opaque shape under the panel.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 44 * scale,
                      color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.32).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(backdrop, in: full)
        let tint = dark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 0.80)
                        : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.975, alpha: 0.80)
        ctx.setFillColor(tint.cgColor)
        ctx.fill(rect)
        ctx.draw(panel, in: rect)
        ctx.restoreGState()

        // Hairline edge.
        ctx.addPath(path)
        ctx.setLineWidth(1)
        ctx.setStrokeColor((dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)).cgColor)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        let renderer = Renderer()
        try await renderer.run()
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
app.run()
