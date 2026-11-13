import Cocoa
import Foundation
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var timer: Timer?
    var dashboardWindow: NSWindow?

    var config = AppConfig()
    var isMenuOpen = false

    let intervalOptions: [Double] = [2, 3, 5, 10, 30]

    var configFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/traffic-monitor/config.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadConfig()
        L10n.resolve(config.lang)
        setupMainMenu()
        applyDockPolicy()

        TrafficMonitor.shared.excludeLocal = config.excludeLocal
        TrafficMonitor.shared.menuPeriod = TimeRange(rawValue: config.menuPeriod) ?? .day24h
        TrafficMonitor.shared.onMenuDataUpdated = { [weak self] in
            self?.updateStatusButton()
            if self?.isMenuOpen == true {
                self?.rebuildMenu()
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = "🌐"
        }

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        rebuildMenu()
        TrafficMonitor.shared.pollOnce()
        startTimer(interval: config.interval)
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu (Cmd+Q)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File Menu (Cmd+W)
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // Edit Menu (Cmd+C / Cmd+V / Cmd+X / Cmd+A for search box)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applyDockPolicy() {
        let hasVisibleDashboard = dashboardWindow?.isVisible ?? false
        let policy: NSApplication.ActivationPolicy = (config.keepInDock || hasVisibleDashboard) ? .regular : .accessory
        NSApplication.shared.setActivationPolicy(policy)
        setupAppIcon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return true
    }

    func setupAppIcon() {
        let execUrl = URL(fileURLWithPath: CommandLine.arguments[0])
        let execDir = execUrl.deletingLastPathComponent()

        let candidatePaths: [String?] = [
            Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
            Bundle.main.path(forResource: "AppIcon", ofType: "png"),
            execDir.appendingPathComponent("../Resources/AppIcon.icns").path,
            execDir.appendingPathComponent("AppIcon.icns").path,
            "macos/AppIcon.icns"
        ]

        for path in candidatePaths {
            if let p = path, FileManager.default.fileExists(atPath: p), let image = NSImage(contentsOfFile: p) {
                NSApplication.shared.applicationIconImage = image
                return
            }
        }
    }

    // MARK: - Config Persistence

    func loadConfig() {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            config = decoded
        } catch {
            // Keep defaults
        }
    }

    func saveConfig() {
        let url = configFileURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(config)
            try data.write(to: url)
        } catch {
            // Ignore write errors
        }
    }

    // MARK: - Timer & Status Bar

    func startTimer(interval: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            TrafficMonitor.shared.pollOnce()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let mon = TrafficMonitor.shared
        if config.showSpeedInMenuBar {
            let inStr = ByteFormatter.formatRate(mon.currentInRate)
            let outStr = ByteFormatter.formatRate(mon.currentOutRate)
            button.title = "🌐 ↓\(inStr) ↑\(outStr)"
        } else {
            button.title = "🌐"
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        TrafficMonitor.shared.refreshMenuSummary()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func rebuildMenu() {
        statusMenu.removeAllItems()
        let mon = TrafficMonitor.shared
        let periodLabel = periodTitle(mon.menuPeriod)

        let headerTitle = "\(L10n.t("app_title")) (\(periodLabel))"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        statusMenu.addItem(headerItem)

        let totalsLine = "   ↑ \(L10n.t("sent")): \(ByteFormatter.format(mon.menuTotalOut))   •   ↓ \(L10n.t("received")): \(ByteFormatter.format(mon.menuTotalIn))"
        let totalsItem = NSMenuItem(title: totalsLine, action: nil, keyEquivalent: "")
        totalsItem.isEnabled = false
        statusMenu.addItem(totalsItem)

        statusMenu.addItem(NSMenuItem.separator())

        let topHeader = NSMenuItem(title: "\(L10n.t("top_processes")) (\(periodLabel)):", action: nil, keyEquivalent: "")
        topHeader.isEnabled = false
        statusMenu.addItem(topHeader)

        if mon.menuTopProcesses.isEmpty {
            let emptyItem = NSMenuItem(title: "   \(L10n.t("no_traffic"))", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            statusMenu.addItem(emptyItem)
        } else {
            for proc in mon.menuTopProcesses {
                let label = "   \(proc.processName)  —  ↑\(ByteFormatter.format(proc.bytesOut))  ↓\(ByteFormatter.format(proc.bytesIn))"
                let item = NSMenuItem(title: label, action: #selector(openDashboardAction), keyEquivalent: "")
                item.target = self
                if let icon = mon.iconForProcess(proc.processName) {
                    let resized = NSImage(size: NSSize(width: 16, height: 16))
                    resized.lockFocus()
                    icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                    resized.unlockFocus()
                    item.image = resized
                }
                statusMenu.addItem(item)
            }
        }

        statusMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: L10n.t("open_dashboard"), action: #selector(openDashboardAction), keyEquivalent: "d")
        openItem.target = self
        statusMenu.addItem(openItem)

        statusMenu.addItem(NSMenuItem.separator())

        // Menu Period Submenu
        let periodMenu = NSMenu()
        for p in [TimeRange.session, .day24h, .week7d, .month30d] {
            let item = NSMenuItem(title: periodTitle(p), action: #selector(selectMenuPeriod(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            item.state = (config.menuPeriod == p.rawValue) ? .on : .off
            periodMenu.addItem(item)
        }
        let periodRoot = NSMenuItem(title: L10n.t("menu_period"), action: nil, keyEquivalent: "")
        periodRoot.submenu = periodMenu
        statusMenu.addItem(periodRoot)

        // Update Interval Submenu
        let intervalMenu = NSMenu()
        for sec in intervalOptions {
            let item = NSMenuItem(title: "\(Int(sec))s", action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sec
            item.state = (config.interval == sec) ? .on : .off
            intervalMenu.addItem(item)
        }
        let intervalRoot = NSMenuItem(title: L10n.t("interval"), action: nil, keyEquivalent: "")
        intervalRoot.submenu = intervalMenu
        statusMenu.addItem(intervalRoot)

        // Toggles
        let excludeLocalItem = NSMenuItem(title: L10n.t("exclude_local"), action: #selector(toggleExcludeLocal), keyEquivalent: "")
        excludeLocalItem.target = self
        excludeLocalItem.state = config.excludeLocal ? .on : .off
        statusMenu.addItem(excludeLocalItem)

        let speedBarItem = NSMenuItem(title: L10n.t("show_speed_bar"), action: #selector(toggleSpeedBar), keyEquivalent: "")
        speedBarItem.target = self
        speedBarItem.state = config.showSpeedInMenuBar ? .on : .off
        statusMenu.addItem(speedBarItem)

        let dockItem = NSMenuItem(title: L10n.t("keep_in_dock"), action: #selector(toggleKeepInDock), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = config.keepInDock ? .on : .off
        statusMenu.addItem(dockItem)

        // Language Submenu
        let langMenu = NSMenu()
        for (code, label) in [("auto", L10n.t("lang_auto")), ("en", "English"), ("ru", "Русский")] {
            let item = NSMenuItem(title: label, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = (config.lang == code) ? .on : .off
            langMenu.addItem(item)
        }
        let langRoot = NSMenuItem(title: L10n.t("language"), action: nil, keyEquivalent: "")
        langRoot.submenu = langMenu
        statusMenu.addItem(langRoot)

        statusMenu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(title: L10n.t("reset_stats"), action: #selector(resetStatsAction), keyEquivalent: "")
        resetItem.target = self
        statusMenu.addItem(resetItem)

        let quitItem = NSMenuItem(title: L10n.t("quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func periodTitle(_ range: TimeRange) -> String {
        switch range {
        case .session: return L10n.t("period_session")
        case .day24h: return L10n.t("period_24h")
        case .week7d: return L10n.t("period_7d")
        case .month30d: return L10n.t("period_30d")
        case .allTime: return L10n.t("period_all")
        }
    }

    // MARK: - Actions

    @objc func openDashboardAction() {
        openDashboard()
    }

    func openDashboard() {
        if dashboardWindow == nil {
            let hosting = NSHostingController(rootView: DashboardView())
            let win = NSWindow(contentViewController: hosting)
            win.title = L10n.t("app_title")
            win.setContentSize(NSSize(width: 1040, height: 680))
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            dashboardWindow = win
        }
        dashboardWindow?.title = L10n.t("app_title")
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if !config.keepInDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !(self.dashboardWindow?.isVisible ?? false) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    @objc func selectMenuPeriod(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let range = TimeRange(rawValue: raw) else { return }
        config.menuPeriod = raw
        TrafficMonitor.shared.menuPeriod = range
        TrafficMonitor.shared.refreshMenuSummary()
        saveConfig()
        rebuildMenu()
    }

    @objc func selectInterval(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Double else { return }
        config.interval = sec
        saveConfig()
        startTimer(interval: sec)
        rebuildMenu()
    }

    @objc func toggleExcludeLocal() {
        config.excludeLocal.toggle()
        TrafficMonitor.shared.excludeLocal = config.excludeLocal
        saveConfig()
        rebuildMenu()
    }

    @objc func toggleSpeedBar() {
        config.showSpeedInMenuBar.toggle()
        saveConfig()
        updateStatusButton()
        rebuildMenu()
    }

    @objc func toggleKeepInDock() {
        config.keepInDock.toggle()
        saveConfig()
        applyDockPolicy()
        rebuildMenu()
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        config.lang = code
        L10n.resolve(code)
        saveConfig()
        rebuildMenu()
        if let win = dashboardWindow, win.isVisible {
            win.title = L10n.t("app_title")
            win.contentViewController = NSHostingController(rootView: DashboardView())
        }
    }

    @objc func resetStatsAction() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.t("reset_confirm_title")
        alert.informativeText = L10n.t("reset_confirm_msg")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("reset_confirm_btn"))
        alert.addButton(withTitle: L10n.t("cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            TrafficMonitor.shared.resetAllData()
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
