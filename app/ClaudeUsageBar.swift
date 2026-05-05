import SwiftUI
import AppKit
import WebKit
import Carbon
import Combine

// MARK: - Enums

enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    // Use NSAppearance directly — .preferredColorScheme inverts on macOS popovers
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}

enum BarStyle: String, CaseIterable, Identifiable {
    case rounded = "Rounded"
    case thin = "Thin"
    case segmented = "Segmented"
    var id: String { rawValue }
}

enum AccentColorPreset: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case matrix = "Matrix"
    case sunset = "Sunset"
    case ocean = "Ocean"
    case monochrome = "Mono"
    var id: String { rawValue }

    func color(for percentage: Double) -> Color {
        switch self {
        case .default:
            if percentage < 0.7 { return .green }
            else if percentage < 0.9 { return .orange }
            else { return .red }
        case .matrix:
            if percentage < 0.7 { return Color(red: 0.2, green: 0.9, blue: 0.2) }
            else if percentage < 0.9 { return Color(red: 0.1, green: 0.68, blue: 0.1) }
            else { return Color(red: 0.05, green: 0.45, blue: 0.05) }
        case .sunset:
            if percentage < 0.7 { return Color(red: 1.0, green: 0.75, blue: 0.0) }
            else if percentage < 0.9 { return Color(red: 1.0, green: 0.45, blue: 0.0) }
            else { return Color(red: 0.9, green: 0.1, blue: 0.3) }
        case .ocean:
            if percentage < 0.7 { return Color(red: 0.0, green: 0.78, blue: 0.78) }
            else if percentage < 0.9 { return Color(red: 0.0, green: 0.48, blue: 0.9) }
            else { return Color(red: 0.28, green: 0.0, blue: 0.88) }
        case .monochrome:
            if percentage < 0.7 { return Color(white: 0.58) }
            else if percentage < 0.9 { return Color(white: 0.38) }
            else { return Color(white: 0.2) }
        }
    }
}

enum UsageTab: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    var id: String { rawValue }
}

struct UsageHistoryPoint: Codable, Identifiable {
    let timestamp: Date
    let primaryPercentage: Double
    let secondaryPercentage: Double
    var id: Date { timestamp }
}

// MARK: - App Entry

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?
    var refreshTimer: Timer?
    var cancellables = Set<AnyCancellable>()
    let settingsWindowController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("✅ App launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusIcon(sessionPct: 0, weeklyPct: 0)
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.appearsDisabled = false
            button.isEnabled = true
        }

        usageManager = UsageManager(statusItem: statusItem, delegate: self)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 440, height: 540)
        popover.behavior = .transient
        popover.appearance = usageManager.themeMode.nsAppearance
        popover.contentViewController = NSHostingController(
            rootView: UsageDashboardView(usageManager: usageManager)
        )

        usageManager.fetchAllUsage()
        scheduleRefreshTimer()

        usageManager.$refreshInterval
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefreshTimer() }
            .store(in: &cancellables)

        usageManager.$themeMode
            .dropFirst()
            .sink { [weak self] _ in self?.reloadPopoverView() }
            .store(in: &cancellables)

        usageManager.$sideBySideLayout
            .dropFirst()
            .sink { [weak self] _ in self?.updatePopoverSize() }
            .store(in: &cancellables)

        setupKeyboardShortcut()
    }

    func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(usageManager?.refreshInterval ?? 300)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.usageManager.fetchAllUsage()
        }
    }

    func reloadPopoverView() {
        guard let manager = usageManager else { return }
        popover.appearance = manager.themeMode.nsAppearance
        popover.contentViewController = NSHostingController(
            rootView: UsageDashboardView(usageManager: manager)
        )
    }

    func updatePopoverSize() {
        let w: CGFloat = usageManager?.sideBySideLayout == true ? 820 : 440
        popover.contentSize = NSSize(width: w, height: 540)
        if popover.isShown {
            closePopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.openPopover() }
        }
    }

    func setupKeyboardShortcut() {
        checkAccessibilityPermissions()
        if usageManager.shortcutEnabled { registerGlobalHotKey() }
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled { registerGlobalHotKey() } else { unregisterGlobalHotKey() }
    }

    func checkAccessibilityPermissions() {
        guard !AXIsProcessTrusted() else {
            NSLog("✅ Accessibility permissions granted")
            return
        }
        NSLog("⚠️ Accessibility permissions not granted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Claude + Codex Usage Tracker needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Skip for Now")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    func registerGlobalHotKey() {
        guard hotKeyRef == nil else { return }
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = 0x436C5542
        hotKeyID.id = 1
        let keyCode: UInt32 = 32
        let modifiers: UInt32 = UInt32(cmdKey)
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        var handler: EventHandlerRef?
        let callback: EventHandlerUPP = { (_, _, userData) -> OSStatus in
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { appDelegate.togglePopover() }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &handler)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr { NSLog("✅ Registered Cmd+U hotkey") }
        else { NSLog("❌ Failed to register hotkey: \(status)") }
    }

    func unregisterGlobalHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func quitApp() { NSApplication.shared.terminate(nil) }

    @objc func togglePopover() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "Toggle Usage (⌘U)", action: #selector(togglePopover), keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(settingsItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit Claude + Codex Tracker", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc func openSettings() {
        settingsWindowController.open(usageManager: usageManager)
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        let w: CGFloat = usageManager?.sideBySideLayout == true ? 820 : 440
        popover.contentSize = NSSize(width: w, height: 540)
        popover.appearance = usageManager?.themeMode.nsAppearance
        DispatchQueue.main.async { self.usageManager.updatePercentages() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover.isShown == true { self?.closePopover() }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func updateStatusIcon(sessionPct: Int, weeklyPct: Int) {
        guard let button = statusItem?.button else { return }
        let showBoth = usageManager?.showBothInStatusBar ?? false
        let color: NSColor
        if sessionPct < 70 { color = NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) }
        else if sessionPct < 90 { color = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) }
        else { color = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0) }
        button.image = createSparkIcon(color: color)
        if showBoth {
            button.title = " \(sessionPct)%·\(weeklyPct)%"
        } else {
            button.title = " \(sessionPct)%"
        }
    }

    func createSparkIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 1))
        path.line(to: NSPoint(x: 9, y: 6))
        path.line(to: NSPoint(x: 13, y: 3))
        path.line(to: NSPoint(x: 10, y: 7))
        path.line(to: NSPoint(x: 15, y: 8))
        path.line(to: NSPoint(x: 10, y: 9))
        path.line(to: NSPoint(x: 13, y: 13))
        path.line(to: NSPoint(x: 9, y: 10))
        path.line(to: NSPoint(x: 8, y: 15))
        path.line(to: NSPoint(x: 7, y: 10))
        path.line(to: NSPoint(x: 3, y: 13))
        path.line(to: NSPoint(x: 6, y: 9))
        path.line(to: NSPoint(x: 1, y: 8))
        path.line(to: NSPoint(x: 6, y: 7))
        path.line(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 7, y: 6))
        path.close()
        color.setFill()
        path.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

// MARK: - NSColor Extension

extension NSColor {
    var hexString: String {
        guard let rgb = self.usingColorSpace(.deviceRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }
}

// MARK: - UsageManager

class UsageManager: ObservableObject {
    // Claude usage
    @Published var sessionUsage: Int = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0
    @Published var claudeHistory: [UsageHistoryPoint] = []

    // Codex usage
    @Published var codexSessionUsage: Int = 0
    @Published var codexSessionLimit: Int = 100
    @Published var codexWeeklyUsage: Int = 0
    @Published var codexWeeklyLimit: Int = 100
    @Published var codexReviewUsage: Int = 0
    @Published var codexReviewLimit: Int = 100
    @Published var codexSessionResetsAt: Date?
    @Published var codexWeeklyResetsAt: Date?
    @Published var codexReviewResetsAt: Date?
    @Published var codexLastUpdated: Date = Date()
    @Published var codexIsLoading: Bool = false
    @Published var codexErrorMessage: String?
    @Published var codexHasFetchedData: Bool = false
    @Published var codexHasReviewLimit: Bool = false
    @Published var codexSessionPercentage: Double = 0.0
    @Published var codexWeeklyPercentage: Double = 0.0
    @Published var codexReviewPercentage: Double = 0.0
    @Published var codexHistory: [UsageHistoryPoint] = []

    // App state
    @Published var notificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true
    @Published var activeTab: UsageTab = .claude

    // Appearance & display customization
    @Published var themeMode: ThemeMode = .system
    @Published var barStyle: BarStyle = .rounded
    @Published var accentPreset: AccentColorPreset = .default
    @Published var showBothInStatusBar: Bool = false
    @Published var sideBySideLayout: Bool = false
    @Published var showGraph: Bool = true
    @Published var compactMode: Bool = false
    @Published var refreshInterval: Int = 300

    private var statusItem: NSStatusItem?
    private var sessionCookie: String = ""
    private var codexSessionCookie: String = ""
    private weak var delegate: AppDelegate?
    private var lastNotifiedThreshold: Int = 0
    private var lastCodexNotifiedThreshold: Int = 0

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        loadSessionCookie()
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    func loadSessionCookie() {
        sessionCookie = UserDefaults.standard.string(forKey: "claude_session_cookie") ?? ""
        codexSessionCookie = UserDefaults.standard.string(forKey: "codex_session_cookie") ?? ""
    }

    func loadSettings() {
        notificationsEnabled = UserDefaults.standard.object(forKey: "notifications_enabled") as? Bool ?? true
        if !UserDefaults.standard.bool(forKey: "has_set_notifications") {
            notificationsEnabled = true
            UserDefaults.standard.set(true, forKey: "has_set_notifications")
        }
        openAtLogin = UserDefaults.standard.bool(forKey: "open_at_login")
        shortcutEnabled = UserDefaults.standard.object(forKey: "shortcut_enabled") as? Bool ?? true
        lastNotifiedThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold")
        lastCodexNotifiedThreshold = UserDefaults.standard.integer(forKey: "last_codex_notified_threshold")

        if let savedTab = UserDefaults.standard.string(forKey: "active_usage_tab"),
           let tab = UsageTab(rawValue: savedTab) {
            activeTab = tab
        }

        // Appearance
        if let raw = UserDefaults.standard.string(forKey: "theme_mode"), let t = ThemeMode(rawValue: raw) { themeMode = t }
        if let raw = UserDefaults.standard.string(forKey: "bar_style"), let b = BarStyle(rawValue: raw) { barStyle = b }
        if let raw = UserDefaults.standard.string(forKey: "accent_preset"), let a = AccentColorPreset(rawValue: raw) { accentPreset = a }
        showBothInStatusBar = UserDefaults.standard.object(forKey: "show_both_status_bar") as? Bool ?? false
        sideBySideLayout = UserDefaults.standard.object(forKey: "side_by_side_layout") as? Bool ?? false
        showGraph = UserDefaults.standard.object(forKey: "show_graph") as? Bool ?? true
        compactMode = UserDefaults.standard.object(forKey: "compact_mode") as? Bool ?? false
        refreshInterval = UserDefaults.standard.object(forKey: "refresh_interval") as? Int ?? 300

        loadHistory()
    }

    func saveSettings() {
        UserDefaults.standard.set(notificationsEnabled, forKey: "notifications_enabled")
        UserDefaults.standard.set(openAtLogin, forKey: "open_at_login")
        UserDefaults.standard.set(shortcutEnabled, forKey: "shortcut_enabled")
        UserDefaults.standard.set(activeTab.rawValue, forKey: "active_usage_tab")
        UserDefaults.standard.set(themeMode.rawValue, forKey: "theme_mode")
        UserDefaults.standard.set(barStyle.rawValue, forKey: "bar_style")
        UserDefaults.standard.set(accentPreset.rawValue, forKey: "accent_preset")
        UserDefaults.standard.set(showBothInStatusBar, forKey: "show_both_status_bar")
        UserDefaults.standard.set(sideBySideLayout, forKey: "side_by_side_layout")
        UserDefaults.standard.set(showGraph, forKey: "show_graph")
        UserDefaults.standard.set(compactMode, forKey: "compact_mode")
        UserDefaults.standard.set(refreshInterval, forKey: "refresh_interval")
        UserDefaults.standard.synchronize()
    }

    func setActiveTab(_ tab: UsageTab) {
        activeTab = tab
        saveSettings()
        updateStatusBar()
    }

    // MARK: - Cookie Management

    func saveSessionCookie(_ cookie: String) {
        sessionCookie = cookie
        UserDefaults.standard.set(cookie, forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()
    }

    func clearSessionCookie() {
        sessionCookie = ""
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()
        sessionUsage = 0; weeklyUsage = 0; weeklySonnetUsage = 0
        sessionResetsAt = nil; weeklyResetsAt = nil; weeklySonnetResetsAt = nil
        hasFetchedData = false; hasWeeklySonnet = false; errorMessage = nil
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")
        delegate?.updateStatusIcon(sessionPct: 0, weeklyPct: 0)
    }

    func saveCodexSessionCookie(_ cookie: String) {
        codexSessionCookie = cookie
        UserDefaults.standard.set(cookie, forKey: "codex_session_cookie")
        UserDefaults.standard.synchronize()
    }

    func clearCodexSessionCookie() {
        codexSessionCookie = ""
        UserDefaults.standard.removeObject(forKey: "codex_session_cookie")
        UserDefaults.standard.synchronize()
        codexSessionUsage = 0; codexWeeklyUsage = 0; codexReviewUsage = 0
        codexSessionResetsAt = nil; codexWeeklyResetsAt = nil; codexReviewResetsAt = nil
        codexHasFetchedData = false; codexHasReviewLimit = false; codexErrorMessage = nil
        lastCodexNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_codex_notified_threshold")
        updateCodexPercentages()
        updateStatusBar()
    }

    func hasClaudeCookie() -> Bool { !sessionCookie.isEmpty }
    func hasCodexCookie() -> Bool { !codexSessionCookie.isEmpty }
    func savedClaudeCookiePreview() -> String { sessionCookie.isEmpty ? "" : String(sessionCookie.prefix(24)) + "..." }
    func savedCodexCookiePreview() -> String { codexSessionCookie.isEmpty ? "" : String(codexSessionCookie.prefix(24)) + "..." }

    // MARK: - Fetching

    func fetchAllUsage() {
        if !sessionCookie.isEmpty { fetchUsage() }
        else if activeTab == .claude { errorMessage = "Session cookie not set"; updateStatusBar() }
        if !codexSessionCookie.isEmpty { fetchCodexUsage() }
        else if activeTab == .codex { codexErrorMessage = "Codex cookie not set"; updateStatusBar() }
    }

    func fetchUsage() {
        guard !sessionCookie.isEmpty else {
            DispatchQueue.main.async { self.errorMessage = "Session cookie not set"; self.updateStatusBar() }
            return
        }
        isLoading = true
        errorMessage = nil
        fetchOrganizationId { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async { self?.errorMessage = "Could not get org ID"; self?.isLoading = false }
                return
            }
            self.fetchUsageWithOrgId(orgId)
        }
    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        let cookieParts = sessionCookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                completion(trimmed.replacingOccurrences(of: "lastActiveOrg=", with: ""))
                return
            }
        }
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else { completion(nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let orgId = account["lastActiveOrgId"] as? String else { completion(nil); return }
            completion(orgId)
        }.resume()
    }

    func fetchUsageWithOrgId(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else {
            DispatchQueue.main.async { self.errorMessage = "Invalid URL"; self.isLoading = false }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if error != nil { self?.errorMessage = "Network error"; self?.updateStatusBar(); return }
                guard let http = response as? HTTPURLResponse else { self?.errorMessage = "Invalid response"; self?.updateStatusBar(); return }
                if http.statusCode == 200, let data = data { self?.parseUsageData(data) }
                else { self?.errorMessage = "HTTP \(http.statusCode)" }
                self?.updateStatusBar()
            }
        }.resume()
    }

    func parseUsageData(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { errorMessage = "Invalid JSON"; return }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let util = fiveHour["utilization"] as? Double { sessionUsage = Int(util); sessionLimit = 100 }
                if let s = fiveHour["resets_at"] as? String { sessionResetsAt = iso.date(from: s) }
            }
            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let util = sevenDay["utilization"] as? Double { weeklyUsage = Int(util); weeklyLimit = 100 }
                if let s = sevenDay["resets_at"] as? String { weeklyResetsAt = iso.date(from: s) }
            }
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                hasWeeklySonnet = true
                if let util = sevenDaySonnet["utilization"] as? Double { weeklySonnetUsage = Int(util); weeklySonnetLimit = 100 }
                if let s = sevenDaySonnet["resets_at"] as? String { weeklySonnetResetsAt = iso.date(from: s) }
            } else {
                hasWeeklySonnet = false
            }

            lastUpdated = Date()
            errorMessage = nil
            hasFetchedData = true
            updatePercentages()
            appendClaudeHistoryPoint()
        } catch {
            errorMessage = "Parse error"
        }
    }

    func updateStatusBar() {
        let sessionPct: Int
        let weeklyPct: Int
        if activeTab == .codex {
            sessionPct = Int((Double(codexSessionUsage) / Double(max(codexSessionLimit, 1))) * 100)
            weeklyPct = Int((Double(codexWeeklyUsage) / Double(max(codexWeeklyLimit, 1))) * 100)
        } else {
            sessionPct = Int((Double(sessionUsage) / Double(max(sessionLimit, 1))) * 100)
            weeklyPct = Int((Double(weeklyUsage) / Double(max(weeklyLimit, 1))) * 100)
        }
        delegate?.updateStatusIcon(sessionPct: sessionPct, weeklyPct: weeklyPct)
        if activeTab == .codex { checkCodexNotificationThresholds(percentage: sessionPct) }
        else { checkNotificationThresholds(percentage: sessionPct) }
    }

    func checkNotificationThresholds(percentage: Int) {
        guard notificationsEnabled else { return }
        let thresholds = [25, 50, 75, 90]
        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                sendNotification(title: "Claude Usage Alert", body: "You've reached \(percentage)% of your 5-hour session limit")
                lastNotifiedThreshold = threshold
                UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
            }
        }
        if percentage < lastNotifiedThreshold {
            lastNotifiedThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
        }
    }

    func checkCodexNotificationThresholds(percentage: Int) {
        guard notificationsEnabled else { return }
        let thresholds = [25, 50, 75, 90]
        for threshold in thresholds {
            if percentage >= threshold && lastCodexNotifiedThreshold < threshold {
                sendNotification(title: "Codex Usage Alert", body: "You've reached \(percentage)% of your Codex session limit")
                lastCodexNotifiedThreshold = threshold
                UserDefaults.standard.set(lastCodexNotifiedThreshold, forKey: "last_codex_notified_threshold")
            }
        }
        if percentage < lastCodexNotifiedThreshold {
            lastCodexNotifiedThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            UserDefaults.standard.set(lastCodexNotifiedThreshold, forKey: "last_codex_notified_threshold")
        }
    }

    func sendNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    func sendTestNotification() {
        sendNotification(title: "Claude Usage Alert", body: "Test — You've reached 75% of your 5-hour session limit")
    }

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(max(sessionLimit, 1))
        weeklyPercentage = Double(weeklyUsage) / Double(max(weeklyLimit, 1))
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(max(weeklySonnetLimit, 1))
    }

    func updateCodexPercentages() {
        codexSessionPercentage = Double(codexSessionUsage) / Double(max(codexSessionLimit, 1))
        codexWeeklyPercentage = Double(codexWeeklyUsage) / Double(max(codexWeeklyLimit, 1))
        codexReviewPercentage = Double(codexReviewUsage) / Double(max(codexReviewLimit, 1))
    }

    // MARK: - Codex Fetching

    func fetchCodexUsage() {
        guard !codexSessionCookie.isEmpty else {
            DispatchQueue.main.async { self.codexErrorMessage = "Codex cookie not set"; self.updateStatusBar() }
            return
        }
        codexIsLoading = true
        codexErrorMessage = nil
        // wham/usage is the correct endpoint — codex/usage does not exist
        fetchCodexUsageEndpoint("https://chatgpt.com/backend-api/wham/usage")
    }

    private func fetchCodexUsageEndpoint(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { self.codexErrorMessage = "Invalid Codex URL"; self.codexIsLoading = false }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        // Full browser header set — Cloudflare on chatgpt.com blocks requests missing these
        request.setValue(codexSessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue("chatgpt.com", forHTTPHeaderField: "Authority")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("1", forHTTPHeaderField: "DNT")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    NSLog("❌ Codex network error: \(error.localizedDescription)")
                    self.codexErrorMessage = "Network error: \(error.localizedDescription)"
                    self.codexIsLoading = false
                    self.updateStatusBar()
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    self.codexErrorMessage = "Invalid response"
                    self.codexIsLoading = false
                    self.updateStatusBar()
                    return
                }

                NSLog("📡 Codex HTTP \(http.statusCode) from \(urlString)")

                if let data = data, let body = String(data: data, encoding: .utf8) {
                    NSLog("📦 Codex body (first 400): \(String(body.prefix(400)))")
                }

                if http.statusCode == 200, let data = data, self.parseCodexUsageData(data) {
                    self.codexIsLoading = false
                    self.updateStatusBar()
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    self.codexErrorMessage = "Cookie expired or invalid (HTTP \(http.statusCode)) — please re-paste your Codex cookie"
                    self.codexIsLoading = false
                    self.updateStatusBar()
                } else {
                    self.codexErrorMessage = "HTTP \(http.statusCode) — check your cookie is fresh and complete"
                    self.codexIsLoading = false
                    self.updateStatusBar()
                }
            }
        }.resume()
    }

    @discardableResult
    func parseCodexUsageData(_ data: Data) -> Bool {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                codexErrorMessage = "Invalid Codex JSON"; return false
            }
            let primary = findCodexWindow(in: json, names: ["primary_window", "five_hour", "5h", "session", "session_limit"])
            let secondary = findCodexWindow(in: json, names: ["secondary_window", "seven_day", "7d", "weekly", "week", "weekly_limit"])
            let review = findCodexWindow(in: json, names: ["code_review_rate_limit", "code_review", "review", "review_limit"])

            guard primary.percent != nil || secondary.percent != nil || review.percent != nil else {
                codexErrorMessage = "Could not parse Codex usage"; return false
            }
            if let p = primary.percent { codexSessionUsage = p; codexSessionLimit = 100 }
            codexSessionResetsAt = primary.resetDate
            if let p = secondary.percent { codexWeeklyUsage = p; codexWeeklyLimit = 100 }
            codexWeeklyResetsAt = secondary.resetDate
            if let p = review.percent { codexReviewUsage = p; codexReviewLimit = 100; codexHasReviewLimit = true }
            else { codexHasReviewLimit = false }
            codexReviewResetsAt = review.resetDate
            codexLastUpdated = Date()
            codexErrorMessage = nil
            codexHasFetchedData = true
            updateCodexPercentages()
            appendCodexHistoryPoint()
            return true
        } catch {
            codexErrorMessage = "Codex parse error"; return false
        }
    }

    private func findCodexWindow(in json: [String: Any], names: [String]) -> (percent: Int?, resetDate: Date?) {
        for name in names {
            if let window = json[name] as? [String: Any] { return (percentageFromWindow(window), resetDateFromWindow(window)) }
        }
        for key in ["usage", "rate_limits", "limits", "data"] {
            if let nested = json[key] as? [String: Any] {
                let r = findCodexWindow(in: nested, names: names)
                if r.percent != nil || r.resetDate != nil { return r }
            }
        }
        if let array = json["additional_rate_limits"] as? [[String: Any]] {
            for item in array {
                let label = [item["name"], item["type"], item["id"], item["window"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
                if names.contains(where: { label.contains($0.replacingOccurrences(of: "_", with: " ")) || label.contains($0) }) {
                    return (percentageFromWindow(item), resetDateFromWindow(item))
                }
            }
        }
        return (nil, nil)
    }

    private func percentageFromWindow(_ window: [String: Any]) -> Int? {
        for key in ["utilization", "used_percent", "percent_used", "usage_percent", "percentage", "percent", "usedPercentage"] {
            if let v = window[key] as? Double { return Int(v <= 1.0 ? v * 100.0 : v) }
            if let v = window[key] as? Int { return v <= 1 ? v * 100 : v }
            if let v = window[key] as? String, let n = Double(v) { return Int(n <= 1.0 ? n * 100.0 : n) }
        }
        if let used = numericValue(window["used"]), let limit = numericValue(window["limit"]), limit > 0 { return Int((used / limit) * 100.0) }
        if let rem = numericValue(window["remaining"]), let limit = numericValue(window["limit"]), limit > 0 { return max(0, Int(((limit - rem) / limit) * 100.0)) }
        return nil
    }

    private func resetDateFromWindow(_ window: [String: Any]) -> Date? {
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for key in ["resets_at", "reset_at", "resetAt", "resetsAt", "expires_at", "expiresAt"] {
            if let s = window[key] as? String { if let d = fmt.date(from: s) { return d } }
        }
        for key in ["reset_after_seconds", "resetAfterSeconds", "seconds_until_reset"] {
            if let secs = numericValue(window[key]) { return Date().addingTimeInterval(secs) }
        }
        return nil
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }

    // MARK: - History

    private func loadHistory() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "claude_usage_history"),
           let h = try? decoder.decode([UsageHistoryPoint].self, from: data) { claudeHistory = h }
        if let data = UserDefaults.standard.data(forKey: "codex_usage_history"),
           let h = try? decoder.decode([UsageHistoryPoint].self, from: data) { codexHistory = h }
    }

    private func saveHistory(_ history: [UsageHistoryPoint], key: String) {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func appendClaudeHistoryPoint() {
        let point = UsageHistoryPoint(timestamp: Date(), primaryPercentage: sessionPercentage, secondaryPercentage: weeklyPercentage)
        claudeHistory.append(point)
        if claudeHistory.count > 48 { claudeHistory = Array(claudeHistory.suffix(48)) }
        saveHistory(claudeHistory, key: "claude_usage_history")
    }

    private func appendCodexHistoryPoint() {
        let point = UsageHistoryPoint(timestamp: Date(), primaryPercentage: codexSessionPercentage, secondaryPercentage: codexWeeklyPercentage)
        codexHistory.append(point)
        if codexHistory.count > 48 { codexHistory = Array(codexHistory.suffix(48)) }
        saveHistory(codexHistory, key: "codex_usage_history")
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var usageManager: UsageManager?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude + Codex Usage Tracker — Settings"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(usageManager: UsageManager) {
        self.usageManager = usageManager
        window?.appearance = usageManager.themeMode.nsAppearance
        window?.contentViewController = NSHostingController(
            rootView: SettingsWindowView(usageManager: usageManager)
        )
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings Window View

struct SettingsWindowView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var claudeCookieInput: String = ""
    @State private var codexCookieInput: String = ""
    @State private var selectedSection: SettingsSection = .appearance

    enum SettingsSection: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case display = "Display"
        case notifications = "Notifications"
        case shortcuts = "Shortcuts"
        case cookies = "Cookies"
        case about = "About"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .appearance: return "paintbrush.fill"
            case .display: return "rectangle.split.2x1.fill"
            case .notifications: return "bell.fill"
            case .shortcuts: return "command"
            case .cookies: return "key.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    Button(action: { selectedSection = section }) {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 13))
                                .frame(width: 18, alignment: .center)
                            Text(section.rawValue)
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selectedSection == section ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(7)
                        .foregroundColor(selectedSection == section ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 165)
            .background(Color.secondary.opacity(0.05))

            Divider()

            // Detail
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedSection {
                    case .appearance: AppearanceSectionView(usageManager: usageManager)
                    case .display: DisplaySectionView(usageManager: usageManager)
                    case .notifications: NotificationsSectionView(usageManager: usageManager)
                    case .shortcuts: ShortcutsSectionView(usageManager: usageManager)
                    case .cookies: CookiesSectionView(usageManager: usageManager, claudeCookieInput: $claudeCookieInput, codexCookieInput: $codexCookieInput)
                    case .about: AboutSectionView()
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 395)
        }
        .frame(width: 560, height: 660)
        .onAppear {
            claudeCookieInput = usageManager.savedClaudeCookiePreview()
            codexCookieInput = usageManager.savedCodexCookiePreview()
            selectedSection = .appearance
        }
    }
}

// MARK: - Settings Sections

struct AppearanceSectionView: View {
    @ObservedObject var usageManager: UsageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(title: "Appearance", icon: "paintbrush.fill")

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsRow(label: "Theme", description: "Controls the color scheme of the popover and settings window") {
                        Picker("", selection: Binding(
                            get: { usageManager.themeMode },
                            set: { usageManager.themeMode = $0; usageManager.saveSettings() }
                        )) {
                            ForEach(ThemeMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    Divider()

                    SettingsRow(label: "Color Palette", description: "Progress bar color theme") {
                        Picker("", selection: Binding(
                            get: { usageManager.accentPreset },
                            set: { usageManager.accentPreset = $0; usageManager.saveSettings() }
                        )) {
                            ForEach(AccentColorPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }

                    Divider()

                    SettingsRow(label: "Bar Style", description: "Visual style of progress bars") {
                        Picker("", selection: Binding(
                            get: { usageManager.barStyle },
                            set: { usageManager.barStyle = $0; usageManager.saveSettings() }
                        )) {
                            ForEach(BarStyle.allCases) { style in Text(style.rawValue).tag(style) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    // Live preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preview")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        StyledProgressBar(value: 0.45, color: usageManager.accentPreset.color(for: 0.45), style: usageManager.barStyle)
                        StyledProgressBar(value: 0.78, color: usageManager.accentPreset.color(for: 0.78), style: usageManager.barStyle)
                        StyledProgressBar(value: 0.95, color: usageManager.accentPreset.color(for: 0.95), style: usageManager.barStyle)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

struct DisplaySectionView: View {
    @ObservedObject var usageManager: UsageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(title: "Display", icon: "rectangle.split.2x1.fill")

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsToggleRow(
                        label: "Show 5h and 7d in menu bar",
                        description: "Display both window percentages in the status bar, e.g. 12%·34%",
                        isOn: Binding(get: { usageManager.showBothInStatusBar }, set: { usageManager.showBothInStatusBar = $0; usageManager.saveSettings(); usageManager.updateStatusBar() })
                    )
                    Divider()
                    SettingsToggleRow(
                        label: "Side-by-side layout",
                        description: "Show Claude and Codex panels next to each other in a wider popover",
                        isOn: Binding(get: { usageManager.sideBySideLayout }, set: { usageManager.sideBySideLayout = $0; usageManager.saveSettings() })
                    )
                    Divider()
                    SettingsToggleRow(
                        label: "Show usage history graph",
                        description: "Display the trend graph below usage bars",
                        isOn: Binding(get: { usageManager.showGraph }, set: { usageManager.showGraph = $0; usageManager.saveSettings() })
                    )
                    Divider()
                    SettingsToggleRow(
                        label: "Compact mode",
                        description: "Reduce padding and use smaller text for a denser layout",
                        isOn: Binding(get: { usageManager.compactMode }, set: { usageManager.compactMode = $0; usageManager.saveSettings() })
                    )
                    Divider()
                    SettingsRow(label: "Auto-refresh interval", description: "How often to poll for new usage data") {
                        Picker("", selection: Binding(
                            get: { usageManager.refreshInterval },
                            set: { usageManager.refreshInterval = $0; usageManager.saveSettings() }
                        )) {
                            Text("Every minute").tag(60)
                            Text("Every 5 min").tag(300)
                            Text("Every 15 min").tag(900)
                            Text("Every 30 min").tag(1800)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }
            }
        }
    }
}

struct NotificationsSectionView: View {
    @ObservedObject var usageManager: UsageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(title: "Notifications", icon: "bell.fill")

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsToggleRow(
                        label: "Usage alerts",
                        description: "Get notified at 25%, 50%, 75%, and 90% session usage",
                        isOn: Binding(get: { usageManager.notificationsEnabled }, set: { usageManager.notificationsEnabled = $0; usageManager.saveSettings() })
                    )
                    Divider()
                    SettingsToggleRow(
                        label: "Open at login",
                        description: "Launch ClaudeUsageBar automatically when you log in",
                        isOn: Binding(get: { usageManager.openAtLogin }, set: { usageManager.openAtLogin = $0; usageManager.saveSettings() })
                    )
                    Divider()
                    Button("Send test notification") { usageManager.sendTestNotification() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

struct ShortcutsSectionView: View {
    @ObservedObject var usageManager: UsageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(title: "Shortcuts", icon: "command")

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsToggleRow(
                        label: "Global shortcut ⌘U",
                        description: "Toggle the usage popover from anywhere. Disable if it conflicts with another app.",
                        isOn: Binding(
                            get: { usageManager.shortcutEnabled },
                            set: { newValue in
                                usageManager.shortcutEnabled = newValue
                                usageManager.saveSettings()
                                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                                    appDelegate.setShortcutEnabled(newValue)
                                }
                            }
                        )
                    )

                    if usageManager.shortcutEnabled && !usageManager.isAccessibilityEnabled {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Accessibility permission needed for the shortcut to work globally")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Grant Accessibility Permission") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

struct CookiesSectionView: View {
    @ObservedObject var usageManager: UsageManager
    @Binding var claudeCookieInput: String
    @Binding var codexCookieInput: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(title: "Cookies", icon: "key.fill")

            EnhancedCookieCard(
                title: "Claude Cookie",
                accentColor: .orange,
                instructions: [
                    ("1", "Open claude.ai in your browser and make sure you're signed in"),
                    ("2", "Go to Settings > Usage — or navigate directly to claude.ai/settings/usage"),
                    ("3", "Open DevTools: press F12 on Windows/Linux or Cmd+Option+I on Mac"),
                    ("4", "Click the Network tab at the top of DevTools, then refresh the page"),
                    ("5", "Click the request named 'usage' that appears in the list"),
                    ("6", "Scroll to Request Headers, find 'Cookie', and copy the complete value — it starts with anthropic-device-id= and is very long, copy all of it")
                ],
                placeholder: "Paste full Cookie header value here...",
                text: $claudeCookieInput,
                hasSavedCookie: usageManager.hasClaudeCookie(),
                saveAction: {
                    let cookie = claudeCookieInput.hasSuffix("...") ? "" : claudeCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cookie.isEmpty { usageManager.errorMessage = "Claude cookie field is empty" }
                    else { usageManager.saveSessionCookie(cookie); usageManager.fetchUsage(); claudeCookieInput = usageManager.savedClaudeCookiePreview() }
                },
                clearAction: { claudeCookieInput = ""; usageManager.clearSessionCookie() }
            )

            EnhancedCookieCard(
                title: "Codex Cookie",
                accentColor: .green,
                instructions: [
                    ("1", "Open chatgpt.com and sign in with a ChatGPT Pro account that has Codex access"),
                    ("2", "Navigate to chatgpt.com/codex/settings/usage"),
                    ("3", "Open DevTools: Cmd+Option+I on Mac, or F12 on Windows/Linux"),
                    ("4", "Click the Network tab, then refresh the page (Cmd+R)"),
                    ("5", "Find the request to /backend-api/wham/usage and click it"),
                    ("6", "Under Request Headers → Cookie, copy the complete value. It is very long (includes cf_clearance, oai-sc, etc) — copy every character, do not truncate")
                ],
                placeholder: "Paste full ChatGPT Cookie header value here...",
                text: $codexCookieInput,
                hasSavedCookie: usageManager.hasCodexCookie(),
                saveAction: {
                    let cookie = codexCookieInput.hasSuffix("...") ? "" : codexCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cookie.isEmpty { usageManager.codexErrorMessage = "Codex cookie field is empty" }
                    else { usageManager.saveCodexSessionCookie(cookie); usageManager.fetchCodexUsage(); codexCookieInput = usageManager.savedCodexCookiePreview() }
                },
                clearAction: { codexCookieInput = ""; usageManager.clearCodexSessionCookie() }
            )

            Text("Your cookies are stored locally on your Mac and sent only to claude.ai and chatgpt.com. They are never transmitted elsewhere.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 2)
        }
    }
}

struct AboutSectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(title: "About", icon: "info.circle.fill")

            SettingsCard {
                VStack(spacing: 16) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(LinearGradient(colors: [Color.orange, Color.red.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 56, height: 56)
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Claude + Codex Usage Tracker")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("Monitor Claude & Codex usage from your menu bar")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Built by")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: "person.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text("Sarthak Sethi")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        AboutLinkButton(label: "GitHub", icon: "chevron.left.forwardslash.chevron.right", url: "https://github.com/1300Sarthak/claudeandcodex", bg: Color.secondary.opacity(0.12))
                        AboutLinkButton(label: "Website", icon: "globe", url: "https://sarthak.lol", bg: Color.secondary.opacity(0.12))
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Based on")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Button(action: { NSWorkspace.shared.open(URL(string: "https://github.com/Artzainnn/ClaudeUsageBar")!) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("ClaudeUsageBar by Maxime B. — original inspiration and foundation")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Settings UI Components

struct AboutLinkButton: View {
    let label: String
    let icon: String
    let url: String
    let bg: Color

    var body: some View {
        Button(action: {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }) {
            Label(label, systemImage: icon)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(bg)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
        }
        .padding(.bottom, 4)
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .background(Color.secondary.opacity(0.07))
            .cornerRadius(12)
    }
}

struct SettingsRow<Control: View>: View {
    let label: String
    let description: String
    let control: Control
    init(label: String, description: String, @ViewBuilder control: () -> Control) {
        self.label = label; self.description = description; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline).fontWeight(.medium)
                Text(description).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            control
        }
    }
}

struct SettingsToggleRow: View {
    let label: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline).fontWeight(.medium)
                Text(description).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
    }
}

struct EnhancedCookieCard: View {
    let title: String
    let accentColor: Color
    let instructions: [(String, String)]
    let placeholder: String
    @Binding var text: String
    let hasSavedCookie: Bool
    let saveAction: () -> Void
    let clearAction: () -> Void
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(hasSavedCookie ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                Spacer()
                Text(hasSavedCookie ? "Connected" : "Not set")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(hasSavedCookie ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((hasSavedCookie ? Color.green : Color.secondary).opacity(0.12))
                    .cornerRadius(6)
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded || !hasSavedCookie {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to get your cookie:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(instructions, id: \.0) { step, text in
                            HStack(alignment: .top, spacing: 8) {
                                Text(step + ".")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(accentColor)
                                    .frame(width: 14, alignment: .trailing)
                                Text(text)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(10)
                .background(accentColor.opacity(0.06))
                .cornerRadius(8)

                PasteableTextField(text: $text, placeholder: placeholder)
                    .frame(height: 58)

                HStack(spacing: 8) {
                    Button("Save & Fetch") { saveAction() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    if hasSavedCookie {
                        Button("Clear") { clearAction() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(10)
    }
}

// MARK: - Dashboard

struct UsageDashboardView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var selectedTab: UsageTab

    init(usageManager: UsageManager) {
        self.usageManager = usageManager
        _selectedTab = State(initialValue: usageManager.activeTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.orange)
                    Text("Claude + Codex")
                        .font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Button(action: {
                    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                        appDelegate.settingsWindowController.open(usageManager: usageManager)
                    }
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            if usageManager.sideBySideLayout {
                // Side by side
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        ProviderUsagePanel(
                            title: "Claude",
                            subtitle: "claude.ai · 5h & 7d windows",
                            isLoading: usageManager.isLoading,
                            errorMessage: usageManager.errorMessage,
                            hasFetchedData: usageManager.hasFetchedData,
                            emptyMessage: "Add your Claude cookie in Settings to start tracking.",
                            metrics: claudeMetrics,
                            history: usageManager.claudeHistory,
                            lastUpdated: usageManager.lastUpdated,
                            showGraph: usageManager.showGraph,
                            compactMode: usageManager.compactMode,
                            barStyle: usageManager.barStyle,
                            accentPreset: usageManager.accentPreset,
                            refreshAction: { usageManager.fetchUsage() }
                        )
                        .padding(14)
                    }
                    Divider()
                    ScrollView {
                        ProviderUsagePanel(
                            title: "Codex",
                            subtitle: "chatgpt.com · 5h & 7d windows",
                            isLoading: usageManager.codexIsLoading,
                            errorMessage: usageManager.codexErrorMessage,
                            hasFetchedData: usageManager.codexHasFetchedData,
                            emptyMessage: "Add your Codex cookie in Settings to start tracking.",
                            metrics: codexMetrics,
                            history: usageManager.codexHistory,
                            lastUpdated: usageManager.codexLastUpdated,
                            showGraph: usageManager.showGraph,
                            compactMode: usageManager.compactMode,
                            barStyle: usageManager.barStyle,
                            accentPreset: usageManager.accentPreset,
                            refreshAction: { usageManager.fetchCodexUsage() }
                        )
                        .padding(14)
                    }
                }
            } else {
                // Tabbed
                Picker("", selection: Binding(
                    get: { selectedTab },
                    set: { selectedTab = $0; usageManager.setActiveTab($0) }
                )) {
                    ForEach(UsageTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                ScrollView {
                    Group {
                        switch selectedTab {
                        case .claude:
                            ProviderUsagePanel(
                                title: "Claude Usage",
                                subtitle: "claude.ai session and weekly limits",
                                isLoading: usageManager.isLoading,
                                errorMessage: usageManager.errorMessage,
                                hasFetchedData: usageManager.hasFetchedData,
                                emptyMessage: "Open Settings and add your Claude cookie to start tracking.",
                                metrics: claudeMetrics,
                                history: usageManager.claudeHistory,
                                lastUpdated: usageManager.lastUpdated,
                                showGraph: usageManager.showGraph,
                                compactMode: usageManager.compactMode,
                                barStyle: usageManager.barStyle,
                                accentPreset: usageManager.accentPreset,
                                refreshAction: { usageManager.fetchUsage() }
                            )
                        case .codex:
                            ProviderUsagePanel(
                                title: "Codex Usage",
                                subtitle: "ChatGPT Codex session and weekly limits",
                                isLoading: usageManager.codexIsLoading,
                                errorMessage: usageManager.codexErrorMessage,
                                hasFetchedData: usageManager.codexHasFetchedData,
                                emptyMessage: "Open Settings and add your Codex cookie to start tracking.",
                                metrics: codexMetrics,
                                history: usageManager.codexHistory,
                                lastUpdated: usageManager.codexLastUpdated,
                                showGraph: usageManager.showGraph,
                                compactMode: usageManager.compactMode,
                                barStyle: usageManager.barStyle,
                                accentPreset: usageManager.accentPreset,
                                refreshAction: { usageManager.fetchCodexUsage() }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: usageManager.sideBySideLayout ? 820 : 440, height: 540)
        .onAppear {
            selectedTab = usageManager.activeTab
            usageManager.updatePercentages()
            usageManager.updateCodexPercentages()
        }
    }

    private var claudeMetrics: [UsageMetric] {
        var m = [
            UsageMetric(title: "Session · 5h", percentage: usageManager.sessionPercentage, resetDate: usageManager.sessionResetsAt, includeDate: false),
            UsageMetric(title: "Weekly · 7d", percentage: usageManager.weeklyPercentage, resetDate: usageManager.weeklyResetsAt, includeDate: true)
        ]
        if usageManager.hasWeeklySonnet {
            m.append(UsageMetric(title: "Weekly Sonnet", percentage: usageManager.weeklySonnetPercentage, resetDate: usageManager.weeklySonnetResetsAt, includeDate: true))
        }
        return m
    }

    private var codexMetrics: [UsageMetric] {
        var m = [
            UsageMetric(title: "Session · 5h", percentage: usageManager.codexSessionPercentage, resetDate: usageManager.codexSessionResetsAt, includeDate: false),
            UsageMetric(title: "Weekly · 7d", percentage: usageManager.codexWeeklyPercentage, resetDate: usageManager.codexWeeklyResetsAt, includeDate: true)
        ]
        if usageManager.codexHasReviewLimit {
            m.append(UsageMetric(title: "Code Review", percentage: usageManager.codexReviewPercentage, resetDate: usageManager.codexReviewResetsAt, includeDate: true))
        }
        return m
    }
}

// MARK: - Provider Panel

struct UsageMetric: Identifiable {
    let id = UUID()
    let title: String
    let percentage: Double
    let resetDate: Date?
    let includeDate: Bool
}

struct ProviderUsagePanel: View {
    let title: String
    let subtitle: String
    let isLoading: Bool
    let errorMessage: String?
    let hasFetchedData: Bool
    let emptyMessage: String
    let metrics: [UsageMetric]
    let history: [UsageHistoryPoint]
    let lastUpdated: Date
    let showGraph: Bool
    let compactMode: Bool
    let barStyle: BarStyle
    let accentPreset: AccentColorPreset
    let refreshAction: () -> Void

    @State private var spinRefresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: compactMode ? 10 : 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(compactMode ? .subheadline : .headline)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: {
                    withAnimation(.linear(duration: 0.6)) { spinRefresh = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { spinRefresh = false }
                    refreshAction()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isLoading ? .secondary : .accentColor)
                        .rotationEffect(.degrees(spinRefresh ? 360 : 0))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Refresh")
            }

            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if !hasFetchedData {
                VStack(spacing: 10) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(Color.secondary.opacity(0.07))
                .cornerRadius(10)
            } else {
                ForEach(metrics) { metric in
                    UsageMetricRow(
                        metric: metric,
                        compactMode: compactMode,
                        barStyle: barStyle,
                        accentPreset: accentPreset
                    )
                }

                if showGraph {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Usage trend")
                                .font(compactMode ? .caption : .subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(history.count) samples")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        UsageHistoryGraph(history: history, accentPreset: accentPreset)
                            .frame(height: compactMode ? 80 : 110)
                    }
                }

                HStack {
                    Text("Updated \(formatTime(lastUpdated))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }
}

// MARK: - Usage Metric Row

struct UsageMetricRow: View {
    let metric: UsageMetric
    let compactMode: Bool
    let barStyle: BarStyle
    let accentPreset: AccentColorPreset

    var body: some View {
        VStack(alignment: .leading, spacing: compactMode ? 4 : 7) {
            HStack {
                Text(metric.title)
                    .font(compactMode ? .caption : .subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let d = metric.resetDate {
                    Text("Resets \(formatResetTime(d, includeDate: metric.includeDate))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            StyledProgressBar(
                value: clamped(metric.percentage),
                color: accentPreset.color(for: metric.percentage),
                style: barStyle
            )

            HStack {
                Text("\(Int(clamped(metric.percentage) * 100))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if metric.percentage >= 0.9 {
                    Text("Critical")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(4)
                } else if metric.percentage >= 0.7 {
                    Text("High")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(4)
                }
            }
        }
        .padding(compactMode ? 8 : 11)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(10)
    }

    private func clamped(_ v: Double) -> Double { min(max(v, 0), 1) }

    private func formatResetTime(_ date: Date, includeDate: Bool) -> String {
        let f = DateFormatter()
        if includeDate { f.dateFormat = "d MMM 'at' h:mm a"; return "on \(f.string(from: date))" }
        f.timeStyle = .short; f.dateStyle = .none; return "at \(f.string(from: date))"
    }
}

// MARK: - Styled Progress Bar

struct StyledProgressBar: View {
    let value: Double
    let color: Color
    let style: BarStyle

    var body: some View {
        switch style {
        case .rounded:
            ProgressView(value: value)
                .tint(color)
        case .thin:
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 3)
                    Capsule().fill(color).frame(width: geo.size.width * value, height: 3)
                }
                .frame(height: 3)
            }
            .frame(height: 3)
        case .segmented:
            HStack(spacing: 3) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Double(i) / 10.0 < value ? color : Color.secondary.opacity(0.18))
                        .frame(height: 10)
                }
            }
        }
    }
}

// MARK: - History Graph

struct UsageHistoryGraph: View {
    let history: [UsageHistoryPoint]
    let accentPreset: AccentColorPreset

    var body: some View {
        GeometryReader { geometry in
            if history.count < 2 {
                Text("Graph appears after two data points.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(8)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07))
                    graphLine(size: geometry.size, values: history.map { $0.secondaryPercentage }, color: .blue.opacity(0.5), lineWidth: 2)
                    graphLine(size: geometry.size, values: history.map { $0.primaryPercentage }, color: accentPreset.color(for: history.last?.primaryPercentage ?? 0), lineWidth: 3)
                    VStack {
                        HStack(spacing: 10) {
                            legend(color: accentPreset.color(for: history.last?.primaryPercentage ?? 0), label: "5h Session")
                            legend(color: .blue.opacity(0.6), label: "7d Weekly")
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
        }
    }

    private func graphLine(size: CGSize, values: [Double], color: Color, lineWidth: CGFloat) -> some View {
        Path { path in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            for i in values.indices {
                let x = CGFloat(i) * step
                let y = size.height - CGFloat(min(max(values[i], 0), 1)) * size.height
                if i == values.startIndex { path.move(to: .init(x: x, y: y)) }
                else { path.addLine(to: .init(x: x, y: y)) }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        .padding(10)
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}

// MARK: - Text Input Components

class CustomTextField: NSTextField {
    var onTextChange: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown && event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v":
                if let s = NSPasteboard.general.string(forType: .string) { self.stringValue = s; onTextChange?(s); return true }
            case "a": self.currentEditor()?.selectAll(nil); return true
            case "c": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.stringValue, forType: .string); return true
            case "x": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.stringValue, forType: .string); self.stringValue = ""; onTextChange?(""); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(self.stringValue)
    }
}

class PasteableNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": paste(nil); return true
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "a": selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct PasteableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PasteableNSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteableNSTextView else { return }
        if textView.string != text { textView.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteableTextField
        init(_ parent: PasteableTextField) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
