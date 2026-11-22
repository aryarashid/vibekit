import AppKit
import XCTest
@testable import VibeKit
import VibeKitCore

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
        let (controller, store, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        controller.show(from: nil, tab: .servers)
        defer { controller.close() }
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? Panel }.first { $0.isVisible })
        // Edit actions go to the key window. A test run started while you use another app may never
        // get key focus, so skip there rather than fail. CI has no such user and must not skip.
        let keyDeadline = Date().addingTimeInterval(3)
        while !panel.isKeyWindow && Date() < keyDeadline { pump(0.01) }
        if !panel.isKeyWindow {
            let message = "The panel never became the key window, so edit shortcuts cannot reach it"
            if ProcessInfo.processInfo.environment["CI"] != nil { XCTFail(message); return }
            throw XCTSkip(message + ". Run this test while the Mac is idle.")
        }

        // Keep the whole clipboard, not just its text, and put it back after.
        let pasteboard = NSPasteboard.general
        let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !savedClipboard.isEmpty { pasteboard.writeObjects(savedClipboard) }
        }
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

        // ⇧⌘C still reaches the server's Copy URL shortcut instead of Edit › Copy. "3000" also matches a
        // recent server on 3001, and the filtered rows move under the still pointer, which must not select one.
        XCTAssertTrue(panel.performKeyEquivalent(with: key("c", unmodified: "C", keyCode: 8, flags: [.command, .shift])))
        let state = "pointer \(NSEvent.mouseLocation), panel \(panel.frame), key \(panel.isKeyWindow), query \(editor.string)"
        XCTAssertEqual(pasteboard.string(forType: .string), "http://localhost:3000", state)
        XCTAssertEqual(store.toast?.message, "Copied http://localhost:3000", state)

        pasteboard.clearContents()
        pasteboard.setString("5173", forType: .string)
        XCTAssertTrue(panel.performKeyEquivalent(with: key("v", keyCode: 9, flags: .command)))
        XCTAssertEqual(editor.string, "5173")

        XCTAssertTrue(panel.performKeyEquivalent(with: key("z", keyCode: 6, flags: .command)))
        XCTAssertEqual(editor.string, "3000")
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

    func testToggleForwardsQueryIntoSearchField() throws {
        let (controller, _, name) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defer { controller.close() }

        controller.toggle(from: nil, tab: .servers, query: "5173")
        pump(0.15)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? Panel }.first { $0.isVisible })
        let host = try XCTUnwrap(panel.contentView?.subviews.first)
        func searchField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: host))
        XCTAssertEqual(field.stringValue, "5173")
    }

    func testPromptContextPrefersFailingThenMostRecentDevServer() {
        let name = "VibeKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ServerStore(settings: Settings(defaults: defaults))

        let now = Date()
        let older = Server(
            id: "older", pid: 1, rootPid: 1, listenerPids: [1], startDate: now.addingTimeInterval(-600),
            ports: [PortBinding(port: 3000, address: "127.0.0.1", isIPv6: false)], framework: .next,
            project: Project(name: "alpha", root: "/tmp/alpha", subpath: nil, branch: "main", worktree: nil),
            processName: "node", executable: "/usr/bin/node", command: "next dev", directory: "/tmp/alpha", launch: nil
        )
        let newer = Server(
            id: "newer", pid: 2, rootPid: 2, listenerPids: [2], startDate: now.addingTimeInterval(-30),
            ports: [PortBinding(port: 5173, address: "127.0.0.1", isIPv6: false)], framework: .vite,
            project: Project(name: "beta", root: "/tmp/beta", subpath: nil, branch: "feat/ui", worktree: nil),
            processName: "node", executable: "/usr/bin/node", command: "vite", directory: "/tmp/beta", launch: nil
        )

        store.showDemo(servers: [older, newer], pages: ["older": PageInfo(status: 200, title: "Alpha"), "newer": PageInfo(status: 200, title: "Beta")], history: [:], recents: [])
        let normalCtx = store.promptContext(clipboard: "hello")
        XCTAssertEqual(normalCtx.project, "beta")
        XCTAssertEqual(normalCtx.port, "5173")
        XCTAssertEqual(normalCtx.branch, "feat/ui")
        XCTAssertEqual(normalCtx.url, "http://localhost:5173")
        XCTAssertEqual(normalCtx.clipboard, "hello")

        // When an older server is failing (500), it takes priority.
        store.showDemo(servers: [older, newer], pages: ["older": PageInfo(status: 500, title: "Error"), "newer": PageInfo(status: 200, title: "Beta")], history: [:], recents: [])
        let failingCtx = store.promptContext(clipboard: nil)
        XCTAssertEqual(failingCtx.project, "alpha")
        XCTAssertEqual(failingCtx.port, "3000")
    }

    func testSkipHTTPCheckSharedPortsUnreadCrashesAndLogPruning() throws {
        let name = "VibeKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let store = ServerStore(settings: Settings(defaults: defaults), persistenceDirectory: tempDir, logsDirectory: tempDir)
        let now = Date()
        let v4 = Server(
            id: "v4", pid: 10, rootPid: 10, listenerPids: [10], startDate: now,
            ports: [PortBinding(port: 3000, address: "127.0.0.1", isIPv6: false)], framework: .vite,
            project: Project(name: "web", root: "/tmp/web", subpath: nil, branch: "main", worktree: nil),
            processName: "node", executable: "/usr/bin/node", command: "vite", directory: "/tmp/web", launch: nil
        )
        let v6 = Server(
            id: "v6", pid: 11, rootPid: 11, listenerPids: [11], startDate: now,
            ports: [PortBinding(port: 3000, address: "::1", isIPv6: true, acceptsIPv4: false)], framework: .next,
            project: Project(name: "api", root: "/tmp/api", subpath: nil, branch: "main", worktree: nil),
            processName: "node", executable: "/usr/bin/node", command: "next dev", directory: "/tmp/api", launch: nil
        )
        store.showDemo(servers: [v4, v6], pages: [:], history: [:], recents: [])

        // Shared port disambiguation & explicit loopback URLs.
        XCTAssertTrue(store.sharedPorts.contains(3000))
        XCTAssertEqual(store.sharedPortLabel(for: v4, binding: v4.ports[0]), "shared · IPv4")
        XCTAssertEqual(store.sharedPortLabel(for: v6, binding: v6.ports[0]), "shared · IPv6")
        XCTAssertEqual(store.url(for: v4)?.absoluteString, "http://127.0.0.1:3000")
        XCTAssertEqual(store.url(for: v6)?.absoluteString, "http://[::1]:3000")
        XCTAssertEqual(store.otherServers(sharingPort: 3000, with: v4).map(\.id), ["v6"])

        // Skip HTTP check turns a waiting dev server immediately up.
        XCTAssertEqual(store.light(for: v4), .waiting)
        store.toggleSkipHTTP(v4)
        XCTAssertEqual(store.light(for: v4), .up)
        store.toggleSkipHTTP(v4)
        XCTAssertEqual(store.light(for: v4), .waiting)

        // Unread crashes accumulate while closed and clear with a toast on panel open.
        store.recordCrash(title: "worker", code: 1)
        XCTAssertEqual(store.unreadCrashes, 1)
        store.isPanelOpen = true
        XCTAssertEqual(store.unreadCrashes, 0)
        XCTAssertEqual(store.toast?.isError, true)
        XCTAssertTrue(store.toast?.message.contains("worker") == true)
        store.isPanelOpen = false

        // Log pruning: keeps newest 50, drops >30d old unless protected, ignores non-.log files.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let protectedOld = tempDir.appendingPathComponent("protected-old.log")
        let expiredOld = tempDir.appendingPathComponent("expired-old.log")
        let noteFile = tempDir.appendingPathComponent("README.txt")
        let oldDate = now.addingTimeInterval(-40 * 86_400)
        for url in [protectedOld, expiredOld, noteFile] {
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        for i in 0..<55 {
            let file = tempDir.appendingPathComponent("recent-\(i).log")
            try Data("log".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(-i * 60))], ofItemAtPath: file.path)
        }
        ServerStore.pruneLogs(in: tempDir, keep: [protectedOld], maxCount: 50, maxAge: 30 * 86_400, now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedOld.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredOld.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteFile.path))
        let remainingLogs = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
        // 50 newest + 1 protected old log.
        XCTAssertEqual(remainingLogs.count, 51)
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
