import AppKit
import SwiftUI

@MainActor
final class SubtitlePanelController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<SubtitleView>?

    func show(text: String, settings: AppSettings) {
        if panel == nil {
            createPanel(text: text, settings: settings)
        } else {
            update(text: text, settings: settings)
        }

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
            return
        }

        hostingController?.rootView = SubtitleView(text: text, settings: settings)
        panel?.ignoresMouseEvents = settings.subtitleMousePassthrough
        panel?.isMovableByWindowBackground = !settings.subtitleMousePassthrough
    }

    private func createPanel(text: String, settings: AppSettings) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = settings.subtitleMousePassthrough

        let hostingController = NSHostingController(rootView: SubtitleView(text: text, settings: settings))
        panel.contentViewController = hostingController

        self.hostingController = hostingController
        self.panel = panel
    }
}
