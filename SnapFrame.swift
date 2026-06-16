import AppKit
import ScreenCaptureKit

private let aspect: CGFloat = 3.0 / 4.0

final class CropController: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }

        for (index, screen) in NSScreen.screens.enumerated() {
            let view = OverlayView(frame: screen.frame)
            view.screenRef = screen
            view.displayIndex = index + 1
            view.onComplete = { [weak self] screen, _, rect in
                self?.capture(screen: screen, rectInScreenPoints: rect)
            }
            view.onCancel = { NSApp.terminate(nil) }

            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    private func capture(screen: NSScreen, rectInScreenPoints rect: CGRect) {
        let region = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        ).integral

        for window in windows {
            window.orderOut(nil)
        }

        Task {
            do {
                let image = try await captureImage(screen: screen, region: region)
                guard let data = pngData(from: image) else {
                    throw NSError(domain: "SnapFrame", code: 1)
                }
                let url = desktopURL()
                try data.write(to: url, options: .atomic)
                copyToPasteboard(data: data)
                showSavedNotification(url: url)
            } catch {
                NSSound.beep()
                showPermissionNotification()
            }

            await MainActor.run {
                NSApp.terminate(nil)
            }
        }
    }

    @available(macOS 14.0, *)
    private func captureImage(screen: NSScreen, region: CGRect) async throws -> CGImage {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw NSError(domain: "SnapFrame", code: 2)
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "SnapFrame", code: 3)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region
        configuration.width = Int((region.width * scale).rounded())
        configuration.height = Int((region.height * scale).rounded())
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 1

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "SnapFrame", code: 4))
                }
            }
        }
    }

    private func pngData(from image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func desktopURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let name = "snapframe-\(formatter.string(from: Date())).png"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(name)
    }

    private func copyToPasteboard(data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    private func showSavedNotification(url: URL) {
        let notification = NSUserNotification()
        notification.title = "SnapFrame 截图已保存"
        notification.informativeText = url.path
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func showPermissionNotification() {
        let notification = NSUserNotification()
        notification.title = "截图失败"
        notification.informativeText = "请确认已允许 SnapFrame 进行屏幕录制"
        NSUserNotificationCenter.default.deliver(notification)
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    var screenRef: NSScreen?
    var displayIndex: Int = 1
    var onComplete: ((NSScreen, Int, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var anchor: CGPoint?
    private var selection: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        if !selection.isEmpty {
            NSColor.clear.setFill()
            selection.fill(using: .clear)

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 2
            border.stroke()

            NSColor(calibratedRed: 0.85, green: 0.13, blue: 0.26, alpha: 1).setStroke()
            let accent = NSBezierPath(rect: selection.insetBy(dx: 3, dy: 3))
            accent.lineWidth = 1
            accent.stroke()
        }

        drawHint()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        anchor = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        selection = rectFrom(anchor: anchor, current: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let screen = screenRef, selection.width >= 24, selection.height >= 32 else {
            selection = .zero
            needsDisplay = true
            return
        }
        onComplete?(screen, displayIndex, selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        }
    }

    private func rectFrom(anchor: CGPoint, current: CGPoint) -> CGRect {
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let directionX: CGFloat = dx >= 0 ? 1 : -1
        let directionY: CGFloat = dy >= 0 ? 1 : -1

        var width = abs(dx)
        var height = width / aspect
        if height > abs(dy) {
            height = abs(dy)
            width = height * aspect
        }

        let origin = CGPoint(
            x: directionX >= 0 ? anchor.x : anchor.x - width,
            y: directionY >= 0 ? anchor.y : anchor.y - height
        )
        let raw = CGRect(origin: origin, size: CGSize(width: width, height: height))
        return clamp(raw)
    }

    private func clamp(_ rect: CGRect) -> CGRect {
        var result = rect
        if result.minX < bounds.minX { result.origin.x = bounds.minX }
        if result.minY < bounds.minY { result.origin.y = bounds.minY }
        if result.maxX > bounds.maxX { result.origin.x = bounds.maxX - result.width }
        if result.maxY > bounds.maxY { result.origin.y = bounds.maxY - result.height }
        return result
    }

    private func drawHint() {
        let text = selection.isEmpty ? "拖动选择 3:4 区域，Esc 取消" : "3:4"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: selection.isEmpty ? 24 : 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.42)
        ]
        let size = text.size(withAttributes: attributes)
        let point: CGPoint
        if selection.isEmpty {
            point = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        } else {
            point = CGPoint(x: selection.minX + 10, y: selection.minY + 10)
        }
        text.draw(at: point, withAttributes: attributes)
    }
}

let app = NSApplication.shared
let controller = CropController()
app.delegate = controller
app.run()
