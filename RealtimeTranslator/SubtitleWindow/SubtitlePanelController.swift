import AppKit
import SwiftUI

@MainActor
final class SubtitlePanelController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<SubtitleView>?
    private var contentModel: SubtitleContentModel?
    private var targetWindowFrame: CGRect?

    func show(text: String, settings: AppSettings) {
        if panel == nil {
            createPanel(text: text, settings: settings)
        } else {
            update(text: text, settings: settings)
        }

        positionPanelOnActiveScreen()
        panel?.orderFrontRegardless()
    }

    func toggle(text: String, settings: AppSettings) {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            show(text: text, settings: settings)
        }
    }

    func update(text: String, settings: AppSettings) {
        if panel == nil {
            createPanel(text: text, settings: settings)
            panel?.orderFrontRegardless()
            return
        }

        contentModel?.update(text: text, settings: settings)
        panel?.ignoresMouseEvents = settings.subtitleMousePassthrough
        panel?.isMovableByWindowBackground = !settings.subtitleMousePassthrough
        positionPanelOnActiveScreen()
        panel?.orderFrontRegardless()
    }

    func updateTargetWindowFrame(_ frame: CGRect) {
        targetWindowFrame = frame
        positionPanelOnActiveScreen()
    }

    private func createPanel(text: String, settings: AppSettings) {
        let screenFrame = activeScreenFrame()
        let width = screenFrame.width * 0.72
        let height: CGFloat = 180
        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.minY + 80
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = settings.subtitleMousePassthrough

        let contentModel = SubtitleContentModel(text: text, settings: settings)
        let hostingController = NSHostingController(rootView: SubtitleView(model: contentModel))
        panel.contentViewController = hostingController

        self.contentModel = contentModel
        self.hostingController = hostingController
        self.panel = panel
    }

    private func positionPanelOnActiveScreen() {
        guard let panel else { return }

        if let targetWindowFrame {
            positionPanel(panel, belowWindowFrame: targetWindowFrame)
            return
        }

        let screenFrame = activeScreenFrame()
        let width = screenFrame.width * 0.72
        let height = max(panel.frame.height, 180)
        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.minY + 80
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func positionPanel(_ panel: NSPanel, belowWindowFrame captureFrame: CGRect) {
        let windowFrame = appKitWindowFrame(fromCaptureFrame: captureFrame)
        let screenFrame = screenFrame(containing: windowFrame) ?? activeScreenFrame()
        let height = max(panel.frame.height, 180)
        let verticalGap: CGFloat = 8
        let minY = screenFrame.minY + verticalGap
        let origin = NSPoint(
            x: windowFrame.minX,
            y: max(minY, windowFrame.minY - height - verticalGap)
        )

        panel.setFrame(
            NSRect(origin: origin, size: NSSize(width: windowFrame.width, height: height)),
            display: true
        )
    }

    private func activeScreenFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func appKitWindowFrame(fromCaptureFrame captureFrame: CGRect) -> NSRect {
        guard let screen = screenForCaptureFrame(captureFrame),
              let displayID = displayID(for: screen)
        else {
            return NSRect(origin: captureFrame.origin, size: captureFrame.size)
        }

        let displayBounds = CGDisplayBounds(displayID)
        return NSRect(
            x: screen.frame.minX + captureFrame.minX - displayBounds.minX,
            y: screen.frame.maxY - (captureFrame.maxY - displayBounds.minY),
            width: captureFrame.width,
            height: captureFrame.height
        )
    }

    private func screenForCaptureFrame(_ captureFrame: CGRect) -> NSScreen? {
        let captureCenter = CGPoint(x: captureFrame.midX, y: captureFrame.midY)

        return NSScreen.screens.first { screen in
            guard let displayID = displayID(for: screen) else { return false }
            return CGDisplayBounds(displayID).contains(captureCenter)
        } ?? NSScreen.screens.first { screen in
            screen.frame.contains(captureCenter)
        }
    }

    private func screenFrame(containing frame: NSRect) -> NSRect? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { screen in
            screen.frame.contains(center)
        }?.visibleFrame
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
