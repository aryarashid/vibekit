import AppKit
import XCTest
@testable import VibeKit

@MainActor
final class PanelTests: XCTestCase {
    private func fixture() -> (PanelController, ServerStore, String) {
        _ = NSApplication.shared
        let name = "VibeKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let store = ServerStore(settings: Settings(defaults: defaults), persistenceDirectory: directory)
        DemoData.load(into: store)
        let prompts = PromptStore(persists: false)
        DemoData.load(into: prompts)
        return (PanelController(store: store, prompts: prompts), store, name)
    }

    func testOpeningAndSwitchingPagesKeepsContentInsideWindow() {
        let (controller, _, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        for route: Route in [.list, .settings, .list] {
            let start = ContinuousClock.now
            controller.show(from: nil, tab: .prompts, route: route)
            let panel = NSApp.windows.compactMap { $0 as? Panel }.first { $0.isVisible }!
            let before = panel.frame
            XCTAssertEqual(panel.alphaValue, 1, "Opening must be immediately visible, including rapid reopen")
            pump(0.1)
            let background = panel.contentView!
            let content = background.subviews.first!
            print("PANEL: open+settle=\(start.duration(to: .now)) before=\(before.size) after=\(panel.frame.size) content=\(content.frame)")
            XCTAssertEqual(content.frame, background.bounds, "The entire hosting view must fill the window")
            XCTAssertEqual(before.size, panel.frame.size, "The panel must open at the final page size")
            XCTAssertEqual(panel.alphaValue, 1)
            if route == .list {
                XCTAssertTrue((panel.firstResponder as? NSTextView)?.isFieldEditor == true,
                              "Typing immediately after opening must reach the search field")
            }
        }
        controller.close()
        pump(0.2)
    }

    func testPrewarmCannotDismissARealOpen() {
        let (controller, store, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        controller.prewarm()
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(store.isPanelOpen)
        controller.show(from: nil, tab: .servers)
        pump(0.1)
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(store.isPanelOpen)
        controller.close()
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(store.isPanelOpen)
    }

    func testDemoNeverStartsLiveScanningOrWritesHistory() throws {
        let name = "VibeKitTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = directory.appendingPathComponent("recents.json")
        let original = Data("[]".utf8)
        try original.write(to: history)
        let store = ServerStore(settings: Settings(defaults: defaults), persistenceDirectory: directory)
        DemoData.load(into: store)
        let ids = store.servers.map(\.id)
        store.start()
        store.isPanelOpen = true
        store.scanNow(fullSweep: true)
        store.clearRecents()
        pump(0.1)
        XCTAssertEqual(store.servers.map(\.id), ids)
        XCTAssertEqual(try Data(contentsOf: history), original)
    }

    func testShrinkingTheOpenPanelKeepsGlassAndHostingFramesAligned() {
        let (controller, _, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        controller.show(from: nil, tab: .prompts)
        let panel = NSApp.windows.compactMap { $0 as? Panel }.first { $0.isVisible }!
        pump(0.1)
        for height: CGFloat in [640, 147, 471, 120, 640] {
            controller.resize(to: height)
            pump(0.1)
            let background = panel.contentView!
            let host = background.subviews.first!
            XCTAssertEqual(panel.frame.height, height)
            XCTAssertEqual(background.bounds.size, panel.frame.size)
            XCTAssertEqual(host.frame, background.bounds)
            print("RESIZE: window=\(panel.frame) background=\(background.frame) host=\(host.frame)")
        }
        controller.close()
    }

    func testHeightReportsDoNotResizeDuringTheReportingLayout() {
        let (controller, _, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        controller.show(from: nil, tab: .prompts)
        pump(0.1)
        let panel = NSApp.windows.compactMap { $0 as? Panel }.first { $0.isVisible }!
        let before = panel.frame
        controller.resize(to: 179)
        XCTAssertEqual(panel.frame, before, "Do not resize AppKit inside the reporting SwiftUI layout")
        pump(0.1)
        XCTAssertEqual(panel.frame.height, 179)
        controller.close()
    }

    func testFilteringPromptsKeepsSearchAtTheTop() throws {
        let (controller, _, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        controller.show(from: nil, tab: .prompts)
        pump(0.1)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? Panel }.first { $0.isVisible })
        let host = try XCTUnwrap(panel.contentView?.subviews.first)
        func searchField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: host))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        // Exercise AppKit's input/notification pipeline, rather than directly invoking
        // SwiftUI's runtime-specific delegate implementation.
        editor.insertText("zz-no-match", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let deadline = Date().addingTimeInterval(2)
        while panel.frame.height >= 250 && Date() < deadline { pump(0.01) }
        XCTAssertEqual(field.stringValue, "zz-no-match")
        XCTAssertLessThan(panel.frame.height, 250)
        let rect = field.convert(field.bounds, to: host)
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        XCTAssertGreaterThanOrEqual(top, 0)
        XCTAssertLessThan(top, 46, "The header must not keep the previous panel height as an offset")
        XCTAssertEqual(host.frame, panel.contentView!.bounds)
        controller.close()
    }

    func testRapidCloseAndReopenHasNoDelayedDismissalOrLiveHiddenRows() {
        let (controller, store, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        controller.prewarm()
        pump(0.1)
        var durations: [Double] = []
        for index in 0..<30 {
            let start = Date()
            controller.show(from: nil, tab: index.isMultiple(of: 2) ? .servers : .prompts)
            durations.append(Date().timeIntervalSince(start) * 1000)
            XCTAssertTrue(controller.isVisible)
            controller.close()
            XCTAssertFalse(controller.isVisible, "Closing must take effect synchronously")
            XCTAssertFalse(store.isPanelOpen)
        }
        controller.show(from: nil)
        let panel = NSApp.windows.compactMap { $0 as? Panel }.first { $0.isVisible }!
        pump(0.3)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(panel.alphaValue, 1)
        let host = panel.contentView!.subviews.first!
        controller.close()
        pump(0.1)
        func lightCount(_ view: NSView) -> Int {
            (view is StatusLightView ? 1 : 0) + view.subviews.reduce(0) { $0 + lightCount($1) }
        }
        XCTAssertEqual(lightCount(host), 0, "Hidden content must release its status animations and observations")
        durations.sort()
        print(String(format: "PANEL: 30 warm opens median %.1f ms, p95 %.1f ms", durations[15], durations[28]))
    }

    func testEditShortcutsWorkInsideThePanel() throws {
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedClipboard { pasteboard.setString(savedClipboard, forType: .string) }
        }

        let (controller, store, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        controller.show(from: nil, tab: .servers)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? Panel }.first { $0.isVisible })
        // Wait for the full demo list to render and focus the search field before filtering;
        // otherwise the initial 200pt height would satisfy the `< 300` check before the filter runs.
        let openDeadline = Date().addingTimeInterval(3)
        while (panel.frame.height <= 400 || !(panel.firstResponder is NSTextView)) && Date() < openDeadline { pump(0.01) }
        XCTAssertGreaterThan(panel.frame.height, 400)
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.insertText("3000", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        // Wait for SwiftUI to apply the filter so the single match (port 3000) becomes active.
        let filterDeadline = Date().addingTimeInterval(3)
        while panel.frame.height >= 300 && Date() < filterDeadline { pump(0.01) }
        XCTAssertLessThan(panel.frame.height, 300)

        func key(_ chars: String, unmodified: String? = nil, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: panel.windowNumber, context: nil, characters: chars,
                             charactersIgnoringModifiers: unmodified ?? chars, isARepeat: false, keyCode: keyCode)!
        }

        XCTAssertTrue(panel.performKeyEquivalent(with: key("a", keyCode: 0, flags: .command)))
        XCTAssertTrue(panel.performKeyEquivalent(with: key("c", keyCode: 8, flags: .command)))
        XCTAssertEqual(pasteboard.string(forType: .string), "3000")

        // ⇧⌘C still reaches the server's Copy URL shortcut instead of Edit › Copy.
        XCTAssertTrue(panel.performKeyEquivalent(with: key("c", unmodified: "C", keyCode: 8, flags: [.command, .shift])))
        XCTAssertEqual(pasteboard.string(forType: .string), "http://localhost:3000")
        XCTAssertEqual(store.toast?.message, "Copied http://localhost:3000")

        pasteboard.clearContents()
        pasteboard.setString("5173", forType: .string)
        XCTAssertTrue(panel.performKeyEquivalent(with: key("v", keyCode: 9, flags: .command)))
        XCTAssertEqual(editor.string, "5173")

        XCTAssertTrue(panel.performKeyEquivalent(with: key("z", keyCode: 6, flags: .command)))
        XCTAssertEqual(editor.string, "3000")
        controller.close()
    }

    func testClickingTheStatusButtonClosesInsteadOfClosingAndReopening() throws {
        let (controller, _, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)
        button.title = "V"
        pump(0.05)

        let window = try XCTUnwrap(button.window)
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let hitRect = buttonRect.union(window.frame)

        controller.toggle(from: button)
        XCTAssertTrue(controller.isVisible)

        // On macOS, the global mouse-down monitor fires even when clicking our own status item.
        // It must ignore clicks on the status button (center and top edge) so the button's toggle closes it.
        controller.handleGlobalMouseDown(at: NSPoint(x: hitRect.midX, y: hitRect.midY))
        XCTAssertTrue(controller.isVisible, "Global mouse-down on the status button must not close before toggle runs")
        controller.handleGlobalMouseDown(at: NSPoint(x: hitRect.midX, y: hitRect.maxY))
        XCTAssertTrue(controller.isVisible, "Global mouse-down at the top edge of the status button must not close")

        controller.toggle(from: button)
        XCTAssertFalse(controller.isVisible, "Second click on the status button must close the panel")

        // A click outside the status button still closes the panel immediately.
        controller.toggle(from: button)
        XCTAssertTrue(controller.isVisible)
        controller.handleGlobalMouseDown(at: NSPoint(x: hitRect.minX - 40, y: hitRect.midY))
        XCTAssertFalse(controller.isVisible, "Clicking outside the status button must close the panel")
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
}

final class PanelGeometryTests: XCTestCase {
    func testMenuBarRevealDoesNotMoveThePanel() {
        let hidden = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let shown = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let top: CGFloat = 869
        XCTAssertEqual(PanelGeometry.frame(midX: 1380, top: top, visibleFrame: hidden, preferredHeight: 640),
                       PanelGeometry.frame(midX: 1380, top: top, visibleFrame: shown, preferredHeight: 640))
    }

    func testSmallDisplayClampsHeightAndAvoidsSideDock() {
        let usable = CGRect(x: 80, y: 0, width: 720, height: 575)
        let panel = PanelGeometry.frame(midX: 5, top: 569, visibleFrame: usable, preferredHeight: 900)
        XCTAssertEqual(panel.minX, 88)
        XCTAssertEqual(panel.minY, 12)
        XCTAssertEqual(panel.maxY, 569)
        XCTAssertTrue(usable.contains(panel))
    }

    func testSecondaryDisplayWithNegativeOrigin() {
        let usable = CGRect(x: -1920, y: -300, width: 1920, height: 1055)
        for x: CGFloat in [-2500, -1800, -1, 400] {
            let panel = PanelGeometry.frame(midX: x, top: 900, visibleFrame: usable, preferredHeight: 640)
            XCTAssertTrue(usable.contains(panel))
            XCTAssertEqual(panel.maxY, 749)
        }
    }
}
