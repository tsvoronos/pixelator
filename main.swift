import Cocoa
import CoreImage
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Pixelator — a tiny AppKit helper that opens an image, lets you drag
// rectangles over it, and bakes pixelate / blur / solid-black into the pixels.
// Saves a copy next to the original as <name>-pixelated.<ext>.
//
// All geometry is done in CGContext space (origin bottom-left) so that view
// coordinates, image pixel coordinates and drawing coordinates all agree.
// ---------------------------------------------------------------------------

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ciContext = CIContext(options: [.workingColorSpace: sRGB])

func makeContext(_ width: Int, _ height: Int) -> CGContext? {
    guard width > 0, height > 0 else { return nil }
    return CGContext(data: nil,
                     width: width,
                     height: height,
                     bitsPerComponent: 8,
                     bytesPerRow: 0,
                     space: sRGB,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// Load an image with EXIF orientation already applied.
func loadImage(_ url: URL) -> CGImage? {
    if let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
       let cg = ciContext.createCGImage(ci, from: ci.extent) {
        return cg
    }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// Crop by redrawing into a fresh context — keeps bottom-left origin semantics
/// (CGImage.cropping(to:) uses a top-left origin space, which is a trap).
func cropped(_ img: CGImage, _ r: CGRect) -> CGImage? {
    guard let c = makeContext(Int(r.width), Int(r.height)) else { return nil }
    c.interpolationQuality = .high
    c.translateBy(x: -r.minX, y: -r.minY)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return c.makeImage()
}

// MARK: - Tools

enum Tool: Int {
    case pixelate = 1
    case blur = 2
    case solid = 3

    var label: String {
        switch self {
        case .pixelate: return "pixelate"
        case .blur:     return "blur"
        case .solid:    return "black"
        }
    }

    var previewColor: CGColor {
        switch self {
        case .pixelate: return CGColor(red: 0.30, green: 0.78, blue: 1.00, alpha: 1)
        case .blur:     return CGColor(red: 0.55, green: 0.90, blue: 0.55, alpha: 1)
        case .solid:    return CGColor(red: 1.00, green: 0.62, blue: 0.35, alpha: 1)
        }
    }
}

/// Returns a new image with `rect` obscured, or nil if nothing was done.
func obscure(_ img: CGImage, rect rawRect: CGRect, tool: Tool, level: Int) -> CGImage? {
    let bounds = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    let r = rawRect.integral.intersection(bounds)
    guard r.width >= 2, r.height >= 2 else { return nil }
    guard let ctx = makeContext(img.width, img.height) else { return nil }
    ctx.draw(img, in: bounds)

    let lvl = min(max(level, 0), 2)
    let shortSide = CGFloat(min(img.width, img.height))

    switch tool {
    case .solid:
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(r)

    case .pixelate:
        // Block size scales with the image so results look consistent across
        // a 900px screenshot and a 6000px photo.
        let factors: [CGFloat] = [0.005, 0.011, 0.022]
        let block = max(3, Int((shortSide * factors[lvl]).rounded()))
        let sw = max(1, Int(r.width) / block)
        let sh = max(1, Int(r.height) / block)
        guard let crop = cropped(img, r), let small = makeContext(sw, sh) else { return nil }
        small.interpolationQuality = .high            // average down…
        small.draw(crop, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let mosaic = small.makeImage() else { return nil }
        ctx.interpolationQuality = .none              // …then hard-edged back up
        ctx.draw(mosaic, in: r)

    case .blur:
        let factors: [CGFloat] = [0.008, 0.016, 0.032]
        let radius = max(3, shortSide * factors[lvl])
        guard let crop = cropped(img, r) else { return nil }
        let ci = CIImage(cgImage: crop)
        let blurred = ci.clampedToExtent()            // clamp so edges don't go transparent
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: ci.extent)
        guard let out = ciContext.createCGImage(blurred, from: ci.extent) else { return nil }
        ctx.draw(out, in: r)
    }

    return ctx.makeImage()
}

// MARK: - Saving

func saveCopy(_ img: CGImage, basedOn url: URL) -> URL? {
    let dir = url.deletingLastPathComponent()
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension.lowercased()
    let isJPEG = (ext == "jpg" || ext == "jpeg")
    let outExt = isJPEG ? "jpg" : "png"
    let type: CFString = (isJPEG ? "public.jpeg" : "public.png") as CFString

    var out = dir.appendingPathComponent("\(stem)-pixelated.\(outExt)")
    var n = 2
    while FileManager.default.fileExists(atPath: out.path) {
        out = dir.appendingPathComponent("\(stem)-pixelated-\(n).\(outExt)")
        n += 1
    }

    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { return nil }
    var props: [CFString: Any] = [:]
    if isJPEG { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out : nil
}

// MARK: - Canvas

final class CanvasView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var tool: Tool = .pixelate { didSet { needsDisplay = true } }
    var level: Int = 1 { didSet { needsDisplay = true } }
    var filename: String = "" { didSet { needsDisplay = true } }
    var edits: Int = 0 { didSet { needsDisplay = true } }
    var onRegion: ((CGRect) -> Void)?

    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    /// Aspect-fit rect for the image inside the view.
    var imageRect: CGRect {
        guard let img = image else { return .zero }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return .zero }
        let s = min(bounds.width / iw, bounds.height / ih)
        let w = iw * s, h = ih * s
        return CGRect(x: ((bounds.width - w) / 2).rounded(),
                      y: ((bounds.height - h) / 2).rounded(),
                      width: w, height: h)
    }

    private func toImageSpace(_ p: CGPoint) -> CGPoint {
        guard let img = image else { return .zero }
        let ir = imageRect
        guard ir.width > 0 else { return .zero }
        let s = ir.width / CGFloat(img.width)
        return CGPoint(x: (p.x - ir.minX) / s, y: (p.y - ir.minY) / s)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
        ctx.fill(bounds)

        if let img = image {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: imageRect)
        }

        if let a = dragStart, let b = dragEnd {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.setFillColor(tool.previewColor.copy(alpha: 0.18) ?? tool.previewColor)
            ctx.fill(r)
            ctx.setStrokeColor(tool.previewColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.stroke(r.insetBy(dx: 0.75, dy: 0.75))
            ctx.setLineDash(phase: 0, lengths: [])
        }

        drawHUD()
    }

    private func drawHUD() {
        let line1 = "\(filename)   ·   \(tool.label)   ·   strength \(level + 1)/3   ·   \(edits) edit\(edits == 1 ? "" : "s")"
        let line2 = "drag to cover   1 pixelate  2 blur  3 black   [ ] strength   ⌘Z undo   ⌘S save copy   ⌘W skip"
        let text = line1 + "\n" + line2

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 8
        let box = NSRect(x: 10,
                         y: bounds.height - size.height - 2 * pad - 10,
                         width: size.width + 2 * pad,
                         height: size.height + 2 * pad)

        NSColor(calibratedWhite: 0, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        str.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad))
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragEnd = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragEnd = nil; needsDisplay = true }
        guard let a = dragStart else { return }
        let b = convert(event.locationInWindow, from: nil)
        let pa = toImageSpace(a), pb = toImageSpace(b)
        let r = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y),
                       width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
        if r.width >= 2 && r.height >= 2 { onRegion?(r) }
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers ?? "" {
        case "1": tool = .pixelate
        case "2": tool = .blur
        case "3": tool = .solid
        case "[": level = max(0, level - 1)
        case "]": level = min(2, level + 1)
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var queue: [URL] = []
    var index = 0

    private var window: NSWindow!
    private var canvas: CanvasView!
    private var current: CGImage?
    private var undoStack: [CGImage] = []
    private var savedFiles: [URL] = []
    private var unreadable: [URL] = []
    private var didStart = false
    private var uiReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        canvas.onRegion = { [weak self] rect in self?.applyToRegion(rect) }

        window = NSWindow(contentRect: canvas.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.contentView = canvas
        window.minSize = NSSize(width: 480, height: 360)
        window.title = "Pixelator"
        window.center()

        uiReady = true

        // Files reach us two ways: as argv (Quick Action / --args) or as an
        // openURLs Apple Event (double-click, Open With, drop on the icon).
        // That event can land either side of this method, so start now if we
        // already have work and otherwise give it a beat before falling back
        // to the open panel.
        if !queue.isEmpty {
            start(allowPrompt: false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.start(allowPrompt: true)
            }
        }
    }

    /// Finder opened files on us: double-click, Open With, drop on icon or Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        queue.append(contentsOf: files)
        // This event can arrive before applicationDidFinishLaunching has built
        // the window; in that case just bank the URLs and let it start us.
        guard uiReady else { return }
        if didStart {
            // Already working — extend the queue and refresh the counter.
            window.title = "Pixelator — \(queue[index].lastPathComponent)"
                + "  (\(index + 1) of \(queue.count))"
        } else {
            start(allowPrompt: false)
        }
    }

    private func start(allowPrompt: Bool) {
        guard uiReady, !didStart else { return }
        if queue.isEmpty {
            guard allowPrompt else { return }
            promptForFiles()
            if queue.isEmpty { NSApp.terminate(nil); return }
        }
        didStart = true
        loadCurrent()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func promptForFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]   // covers heic/webp/etc. automatically
        panel.message = "Choose image(s) to pixelate"
        if panel.runModal() == .OK { queue = panel.urls }
    }

    // MARK: document lifecycle

    private func loadCurrent() {
        guard index < queue.count else { finish(); return }
        let url = queue[index]
        guard let img = loadImage(url) else {
            // Unreadable file — skip it rather than dying, but remember it so
            // we can explain ourselves instead of just vanishing.
            unreadable.append(url)
            index += 1
            loadCurrent()
            return
        }
        current = img
        undoStack = []
        canvas.image = img
        canvas.filename = url.lastPathComponent
        canvas.edits = 0
        window.title = "Pixelator — \(url.lastPathComponent)  (\(index + 1) of \(queue.count))"
        fitWindow(to: img)
    }

    private func fitWindow(to img: CGImage) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let maxW = visible.width * 0.85, maxH = visible.height * 0.85
        let s = min(1.0, min(maxW / CGFloat(img.width), maxH / CGFloat(img.height)))
        let size = NSSize(width: max(480, (CGFloat(img.width) * s).rounded()),
                          height: max(360, (CGFloat(img.height) * s).rounded()))
        window.setContentSize(size)
        window.center()
    }

    private func applyToRegion(_ rect: CGRect) {
        guard let img = current else { return }
        guard let out = obscure(img, rect: rect, tool: canvas.tool, level: canvas.level) else { return }
        undoStack.append(img)
        current = out
        canvas.image = out
        canvas.edits = undoStack.count
    }

    private func finish() {
        if !savedFiles.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(savedFiles)
        } else if !unreadable.isEmpty {
            let alert = NSAlert()
            alert.messageText = unreadable.count == 1
                ? "Couldn't read that image"
                : "Couldn't read any of those \(unreadable.count) images"
            alert.informativeText =
                unreadable.prefix(5).map { $0.lastPathComponent }.joined(separator: "\n")
                + "\n\nIf they live in Desktop, Documents or Downloads, macOS may be "
                + "blocking access. Grant Pixelator permission under System Settings → "
                + "Privacy & Security → Files and Folders."
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    // MARK: actions

    @objc func undoEdit(_ sender: Any?) {
        guard let previous = undoStack.popLast() else { NSSound.beep(); return }
        current = previous
        canvas.image = previous
        canvas.edits = undoStack.count
    }

    @objc func saveAndNext(_ sender: Any?) {
        guard let img = current else { return }
        if undoStack.isEmpty {
            // Nothing changed — don't litter the folder with an identical copy.
            NSSound.beep()
            return
        }
        if let out = saveCopy(img, basedOn: queue[index]) {
            savedFiles.append(out)
        } else {
            let alert = NSAlert()
            alert.messageText = "Couldn't write the copy"
            alert.informativeText = "Check that you have write access to \(queue[index].deletingLastPathComponent().path)."
            alert.runModal()
            return
        }
        index += 1
        loadCurrent()
    }

    @objc func skipFile(_ sender: Any?) {
        index += 1
        loadCurrent()
    }

    @objc func setPixelate(_ sender: Any?) { canvas.tool = .pixelate }
    @objc func setBlur(_ sender: Any?)     { canvas.tool = .blur }
    @objc func setSolid(_ sender: Any?)    { canvas.tool = .solid }
    @objc func coarser(_ sender: Any?)     { canvas.level = min(2, canvas.level + 1) }
    @objc func finer(_ sender: Any?)       { canvas.level = max(0, canvas.level - 1) }

    // MARK: menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Pixelator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(fileMenu, "Save Copy & Next", #selector(saveAndNext(_:)), "s")
        add(fileMenu, "Skip This Image", #selector(skipFile(_:)), "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add(editMenu, "Undo Last Edit", #selector(undoEdit(_:)), "z")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let toolItem = NSMenuItem()
        let toolMenu = NSMenu(title: "Tools")
        add(toolMenu, "Pixelate", #selector(setPixelate(_:)), "1")
        add(toolMenu, "Blur", #selector(setBlur(_:)), "2")
        add(toolMenu, "Solid Black", #selector(setSolid(_:)), "3")
        toolMenu.addItem(NSMenuItem.separator())
        add(toolMenu, "Stronger", #selector(coarser(_:)), "]")
        add(toolMenu, "Weaker", #selector(finer(_:)), "[")
        toolItem.submenu = toolMenu
        main.addItem(toolItem)

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
}

// MARK: - Entry point

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
delegate.queue = CommandLine.arguments
    .dropFirst()
    .filter { !$0.hasPrefix("-") }          // drop -psn_… and friends
    .map { URL(fileURLWithPath: $0) }
app.run()
