import SwiftUI
import CoreGraphics
import ServiceManagement

struct Counts: Equatable {
    var keys = 0
    var clicks = 0
    var meters = 0.0
    var scroll = 0.0

    init() {}

    init(_ d: UserDefaults, _ prefix: String) {
        keys = d.integer(forKey: prefix + "keys")
        clicks = d.integer(forKey: prefix + "clicks")
        meters = d.double(forKey: prefix + "meters")
        scroll = d.double(forKey: prefix + "scroll")
    }

    func save(_ d: UserDefaults, _ prefix: String) {
        d.set(keys, forKey: prefix + "keys")
        d.set(clicks, forKey: prefix + "clicks")
        d.set(meters, forKey: prefix + "meters")
        d.set(scroll, forKey: prefix + "scroll")
    }
}

final class Stats: ObservableObject {
    // то, что видит интерфейс; обновляется раз в полсекунды, пока панель открыта
    @Published private(set) var total: Counts
    @Published private(set) var today: Counts
    @Published var hasAccess = false

    // живые счётчики, меняются на каждое событие
    private var liveTotal: Counts
    private var liveToday: Counts
    private var displays: [(rect: CGRect, mmPerPoint: Double)] = []
    private var uiTimer: Timer?
    private var day: String
    private var tap: CFMachPort?
    private var last: CGPoint?
    private let defaults = UserDefaults.standard

    init() {
        // старые ключи без префикса — это общая статистика
        liveTotal = Counts(defaults, "")
        day = Stats.dayKey()
        liveToday = defaults.string(forKey: "today.day") == day ? Counts(defaults, "today.") : Counts()
        total = liveTotal
        today = liveToday
        loadDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.loadDisplays()
        }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        // ждём, пока дадут доступ к мониторингу ввода
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.startTap() == true { t.invalidate() }
        }
        _ = startTap()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.save() }
    }

    func setPanelVisible(_ visible: Bool) {
        uiTimer?.invalidate()
        uiTimer = nil
        guard visible else { return }
        publish()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.publish() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        uiTimer = t
    }

    private func publish() {
        if total != liveTotal { total = liveTotal }
        if today != liveToday { today = liveToday }
    }

    // размеры дисплеев не меняются, пока не сменится конфигурация экранов
    private func loadDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        displays = ids.prefix(Int(n)).compactMap { id in
            let b = CGDisplayBounds(id)
            let mm = CGDisplayScreenSize(id).width
            return b.width > 0 && mm > 0 ? (b, Double(mm / b.width)) : nil
        }
    }

    private static func dayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    func reset() {
        liveTotal = Counts()
        liveToday = Counts()
        save()
        publish()
    }

    func save() {
        // новый день — обнуляем сегодняшнюю статистику
        let now = Stats.dayKey()
        if now != day { day = now; liveToday = Counts() }
        liveTotal.save(defaults, "")
        liveToday.save(defaults, "today.")
        defaults.set(day, forKey: "today.day")
    }

    private func startTap() -> Bool {
        if tap != nil { return true }
        // без доступа tap создаётся, но видит только события своего окна
        guard CGPreflightListenEventAccess() else { return false }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, info in
                Unmanaged<Stats>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        hasAccess = true
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            // автоповтор при зажатой клавише не считаем
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                liveTotal.keys += 1
                liveToday.keys += 1
            }
        case .flagsChanged:
            if modifierPressed(event) {
                liveTotal.keys += 1
                liveToday.keys += 1
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            liveTotal.clicks += 1
            liveToday.clicks += 1
        case .scrollWheel:
            // считаем только движение пальцев или колёсика, без инерции
            if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { break }
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if let d = displays.first(where: { $0.rect.contains(event.location) }) {
                let m = hypot(dx, dy) * d.mmPerPoint / 1000
                liveTotal.scroll += m
                liveToday.scroll += m
            }
        default:
            let p = event.location
            if let l = last {
                let d = distance(from: l, to: p)
                liveTotal.meters += d
                liveToday.meters += d
            }
            last = p
        }
    }

    // модификаторы приходят как flagsChanged и при нажатии, и при отпускании;
    // по биту конкретной клавиши (левой или правой) понимаем, что её нажали
    private func modifierPressed(_ e: CGEvent) -> Bool {
        let mask: UInt64
        switch e.getIntegerValueField(.keyboardEventKeycode) {
        case 59: mask = 0x01        // левый control
        case 62: mask = 0x2000      // правый control
        case 56: mask = 0x02        // левый shift
        case 60: mask = 0x04        // правый shift
        case 55: mask = 0x08        // левый command
        case 54: mask = 0x10        // правый command
        case 58: mask = 0x20        // левый option
        case 61: mask = 0x40        // правый option
        case 63: mask = CGEventFlags.maskSecondaryFn.rawValue
        case 57: return true        // caps lock присылает одно событие на нажатие
        default: return false
        }
        return e.flags.rawValue & mask != 0
    }

    // переводим точки экрана в миллиметры по физическому размеру дисплея
    private func distance(from a: CGPoint, to b: CGPoint) -> Double {
        guard let d = displays.first(where: { $0.rect.contains(b) }) else { return 0 }
        return Double(hypot(b.x - a.x, b.y - a.y)) * d.mmPerPoint / 1000
    }
}

@main
struct KeyMeterApp: App {
    @StateObject private var stats = Stats()

    var body: some Scene {
        MenuBarExtra("KeyMeter", systemImage: "ruler") {
            StatsView(stats: stats)
        }
        .menuBarExtraStyle(.window)
    }
}

struct StatsView: View {
    @ObservedObject var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !stats.hasAccess {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Input Monitoring access")
                    Text("Grant access and restart KeyMeter")
                        .foregroundStyle(.secondary)
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                Divider()
            }

            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1).gridColumnAlignment(.leading)
                    Text("Today")
                    Text("Total")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                row("keyboard", count(stats.today.keys), count(stats.total.keys))
                row("computermouse", count(stats.today.clicks), count(stats.total.clicks))
                row("ruler", distance(stats.today.meters), distance(stats.total.meters))
                row("arrow.up.and.down", distance(stats.today.scroll), distance(stats.total.scroll))
            }
            .monospacedDigit()

            Divider()

            HStack(spacing: 14) {
                Button("About") { showAbout() }
                Spacer()
                Button("Settings") { SettingsWindow.show(stats) }
                    .keyboardShortcut(",")
                Button("Quit") { stats.save(); NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 250)
        .onAppear { stats.setPanelVisible(true) }
        .onDisappear { stats.setPanelVisible(false) }
    }

    private func row(_ icon: String, _ today: String, _ total: String) -> some View {
        GridRow {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Text(today)
            Text(total)
        }
    }

    private func count(_ n: Int) -> String {
        n < 1_000_000
            ? n.formatted()
            : String(localized: "\((Double(n) / 1_000_000).formatted(.number.precision(.fractionLength(2))))M")
    }

    private func distance(_ m: Double) -> String {
        m < 1000
            ? String(localized: "\(m.formatted(.number.precision(.fractionLength(1)))) m")
            : String(localized: "\((m / 1000).formatted(.number.precision(.fractionLength(2)))) km")
    }
}

struct SettingsView: View {
    @ObservedObject var stats: Stats
    @State private var autostart = SMAppService.mainApp.status == .enabled
    @State private var language = SettingsView.currentLanguage()
    @State private var confirmReset = false

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { autostart }, set: setAutostart))
            Picker("Language", selection: Binding(get: { language }, set: setLanguage)) {
                Text("System").tag("")
                Text(verbatim: "English").tag("en")
                Text(verbatim: "Русский").tag("ru")
            }
            HStack {
                Spacer()
                Button("Reset statistics…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
        .confirmationDialog("Reset all statistics?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { stats.reset() }
        } message: {
            Text("Today and total counters will be set to zero. This can't be undone.")
        }
    }

    private func setAutostart(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        autostart = SMAppService.mainApp.status == .enabled
    }

    // язык самого приложения, а не системы; пустая строка — как в системе
    static func currentLanguage() -> String {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        return (domain?["AppleLanguages"] as? [String])?.first ?? ""
    }

    private func setLanguage(_ code: String) {
        guard code != language else { return }
        language = code
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        // язык подхватывается только при запуске
        stats.save()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

enum SettingsWindow {
    private static var window: NSWindow?

    static func show(_ stats: Stats) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(stats: stats)))
            w.title = String(localized: "Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private func showAbout() {
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let base: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: center,
    ]
    var link = base
    link[.link] = URL(string: "https://github.com/cheeselover419")!
    let credits = NSAttributedString(string: "github.com/cheeselover419", attributes: link)

    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
}
