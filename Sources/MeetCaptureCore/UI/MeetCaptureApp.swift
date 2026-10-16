// MeetCaptureApp.swift
// Native menu-bar lifecycle. The @main shim lives in the executable target.

import AppKit
import Combine
import SwiftUI

@MainActor
public enum MeetCaptureApp {
    public static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

/// Where the status item actually ended up. macOS 26 hosts status items in
/// Control Center and silently drops them for apps turned off in
/// Settings › Menu Bar; on notched screens an overflowing item lands behind
/// the camera housing. In both cases AppKit still reports `isVisible == true`.
enum StatusItemPlacement: Equatable {
    case visible
    case notHosted
    case behindNotch

    /// `frame` is the status button's window frame in Cocoa screen coordinates.
    static func evaluate(frame: CGRect, notch: CGRect?,
                         hostedWindowFrames: [CGRect]) -> StatusItemPlacement {
        let hosted = hostedWindowFrames.contains {
            abs($0.minX - frame.minX) < 10 && abs($0.width - frame.width) < 10
        }
        guard hosted else { return .notHosted }
        if let notch, notch.intersects(frame) { return .behindNotch }
        return .visible
    }

    static func notchRect(_ screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        let origin = screen.frame.origin
        return CGRect(x: origin.x + left.maxX, y: origin.y + left.minY,
                      width: right.minX - left.maxX, height: max(left.height, right.height))
    }

    /// Menu-bar windows (layer 25) owned by Control Center (macOS 26) or by
    /// this process (earlier macOS). Bounds and owner need no screen-recording
    /// permission.
    static func hostedWindowFrames() -> [CGRect] {
        // By bundle id: the owner name is localized ("Centro de control").
        var owners = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter")
            .map { Int($0.processIdentifier) })
        owners.insert(Int(ProcessInfo.processInfo.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 25 else { return nil }
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, owners.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var fallbackPanel: NSPanel?
    private var statusUpdates: AnyCancellable?
    private var lastTransientClose = Date.distantPast
    private var terminating = false

    override init() {
        Settings.registerDefaults()
        appState = AppState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "MeetCaptureStatusItem"
        item.behavior = []
        statusItem = item
        guard let button = item.button else {
            NSApp.terminate(nil)
            return
        }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageOnly
        button.toolTip = AppInfo.name

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverContent(appState: appState))
        self.popover = popover

        statusUpdates = appState.$phase.combineLatest(appState.$isStartingRecording)
            .sink { [weak self] phase, isStarting in
                self?.updateStatusIcon(phase: phase, isStarting: isStarting)
            }

        let environment = ProcessInfo.processInfo.environment
        if environment["MEETCAPTURE_LAUNCH_PROBE"] == "1",
           let output = LaunchProbe.isolatedOutputDirectory(environment) {
            // Exercise the status item, click toggling, and Finder reopen
            // without permissions, capture, or meeting data.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.runLaunchProbe(output: output, environment: environment)
            }
            return
        }

        // The item normally stays quiet at launch. If macOS is not showing it,
        // open the same controls in a small window and say how to fix it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.placement() != .visible else { return }
            self.showFallbackPanel()
        }
        Task { @MainActor in await self.appState.startup() }
    }

    // MARK: - Menu-bar item

    private func placement() -> StatusItemPlacement {
        guard let window = statusItem?.button?.window else { return .notHosted }
        return StatusItemPlacement.evaluate(
            frame: window.frame, notch: window.screen.flatMap(StatusItemPlacement.notchRect),
            hostedWindowFrames: StatusItemPlacement.hostedWindowFrames())
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Clicking the icon of a transient popover first closes it on mouse
        // down; the action then arrives on mouse up. Don't reopen it.
        guard Date().timeIntervalSince(lastTransientClose) > 0.3 else { return }
        showControls()
    }

    /// Shows the popover under the icon when the icon is really on screen,
    /// otherwise the fallback window.
    private func showControls() {
        appState.refreshPermissions()
        appState.scanRecoverableRecordings()
        guard placement() == .visible, let button = statusItem?.button, let popover else {
            showFallbackPanel()
            return
        }
        fallbackPanel?.orderOut(nil)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        lastTransientClose = Date()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    private func updateStatusIcon(phase: AppPhase, isStarting: Bool) {
        guard let button = statusItem?.button else { return }
        let label = "\(AppInfo.name), \(Strings.phase(phase, isStartingRecording: isStarting))"
        let symbol: String
        if isStarting || phase == .transcribing {
            symbol = "waveform"
        } else if phase == .recording {
            symbol = "mic.fill"
        } else {
            symbol = "mic"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    // MARK: - Fallback window

    private func showFallbackPanel() {
        let panel = fallbackPanel ?? makeFallbackPanel()
        fallbackPanel = panel
        if let host = panel.contentViewController as? NSHostingController<FallbackContent> {
            host.rootView = FallbackContent(appState: appState, placement: placement())
        }
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16,
                                             y: visible.maxY - size.height - 8))
            }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeFallbackPanel() -> NSPanel {
        let host = NSHostingController(rootView: FallbackContent(appState: appState, placement: placement()))
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.title = AppInfo.name
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }

    // MARK: - Main menu

    /// Accessory apps show no menu bar, but key equivalents (⌘C/⌘V in search
    /// and notes, ⌘Q) still route through the main menu.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Salir de \(AppInfo.name)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edición")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    // MARK: - Termination

    /// Quitting mid-recording must finish the PCM file and its sidecar;
    /// startup recovery transcribes it on the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, appState.needsGracefulShutdown else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            await self.appState.shutdownGracefully()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    // MARK: - Launch probe

    private func runLaunchProbe(output: URL, environment: [String: String]) {
        guard let item = statusItem, let button = item.button, let popover else { return }
        let placement = placement()
        let iconReady = button.image != nil && item.length == NSStatusItem.squareLength
            && button.window != nil
        button.performClick(nil)
        let clickOpened = placement == .visible ? popover.isShown : fallbackPanel?.isVisible == true
        button.performClick(nil)
        let clickClosed = placement == .visible ? !popover.isShown : true
        fallbackPanel?.orderOut(nil)
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let reopenShown = popover.isShown || fallbackPanel?.isVisible == true
        popover.performClose(nil)
        fallbackPanel?.orderOut(nil)
        let requireVisible = environment["MEETCAPTURE_REQUIRE_HOSTED_ICON"] == "1"
        let details = "placement=\(placement) iconReady=\(iconReady) image=\(button.image != nil) "
            + "length=\(item.length) statusWindow=\(String(describing: button.window?.frame)) "
            + "screens=\(NSScreen.screens.map(\.frame)) clickOpened=\(clickOpened) "
            + "clickClosed=\(clickClosed) reopenShown=\(reopenShown) requireVisible=\(requireVisible)"
        try? Data(details.utf8).write(to: output.appendingPathComponent("menubar-interaction.txt"))
        guard iconReady, clickOpened, clickClosed, reopenShown,
              !requireVisible || placement == .visible else { return }
        try? Data("icon, click, and reopen passed".utf8)
            .write(to: output.appendingPathComponent("menubar-interaction.ok"))
    }
}

private enum LaunchProbe {
    static func isolatedOutputDirectory(_ environment: [String: String]) -> URL? {
        guard let output = environment["MEETCAPTURE_TEST_OUTPUT_DIR"] else { return nil }
        let isolated = URL(fileURLWithPath: output).resolvingSymlinksInPath().path
        let temporaryRoot = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard isolated.hasPrefix(temporaryRoot + "/"),
              FileManager.default.fileExists(atPath: isolated, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: isolated)
    }
}

/// The popover content plus, when the icon is not on screen, how to get it back.
@MainActor
private struct FallbackContent: View {
    @ObservedObject var appState: AppState
    let placement: StatusItemPlacement

    var body: some View {
        VStack(spacing: 0) {
            if placement != .visible {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "menubar.rectangle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.menuBarHiddenTitle).font(.callout.weight(.semibold))
                        Text(placement == .behindNotch ? Strings.menuBarBehindNotch : Strings.menuBarNotAllowed)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if placement == .notHosted {
                            Button(Strings.openMenuBarSettings) {
                                MenuBarSettings.open()
                            }
                            .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(width: PopoverContent<AppState>.width)
                .background(Color.orange.opacity(0.08))
                Divider()
            }
            PopoverContent(appState: appState)
        }
    }
}

enum MenuBarSettings {
    static func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
