import SwiftUI
import CoreGraphics

struct Counts {
    var keys = 0
    var clicks = 0
    var meters = 0.0

    init() {}

    init(_ d: UserDefaults, _ prefix: String) {
        keys = d.integer(forKey: prefix + "keys")
        clicks = d.integer(forKey: prefix + "clicks")
        meters = d.double(forKey: prefix + "meters")
    }

    func save(_ d: UserDefaults, _ prefix: String) {
        d.set(keys, forKey: prefix + "keys")
        d.set(clicks, forKey: prefix + "clicks")
        d.set(meters, forKey: prefix + "meters")
    }
}

final class Stats: ObservableObject {
    @Published var total: Counts
    @Published var today: Counts
    @Published var hasAccess = false

    private var day: String
    private var tap: CFMachPort?
    private var last: CGPoint?
    private let defaults = UserDefaults.standard

    init() {
        // старые ключи без префикса — это общая статистика
        total = Counts(defaults, "")
        day = Stats.dayKey()
        today = defaults.string(forKey: "today.day") == day ? Counts(defaults, "today.") : Counts()
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        // ждём, пока дадут доступ к мониторингу ввода
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.startTap() == true { t.invalidate() }
        }
        _ = startTap()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.save() }
    }

    private static func dayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    func save() {
        // новый день — обнуляем сегодняшнюю статистику
        let now = Stats.dayKey()
        if now != day { day = now; today = Counts() }
        total.save(defaults, "")
        today.save(defaults, "today.")
        defaults.set(day, forKey: "today.day")
    }

    private func startTap() -> Bool {
        if tap != nil { return true }
        // без доступа tap создаётся, но видит только события своего окна
        guard CGPreflightListenEventAccess() else { return false }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
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
                total.keys += 1
                today.keys += 1
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            total.clicks += 1
            today.clicks += 1
        default:
            let p = event.location
            if let l = last {
                let d = distance(from: l, to: p)
                total.meters += d
                today.meters += d
            }
            last = p
        }
    }

    // переводим точки экрана в миллиметры по физическому размеру дисплея
    private func distance(from a: CGPoint, to b: CGPoint) -> Double {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(b, 1, &id, &count)
        guard count > 0 else { return 0 }
        let mm = CGDisplayScreenSize(id).width
        let pts = CGDisplayBounds(id).width
        guard mm > 0, pts > 0 else { return 0 }
        return Double(hypot(b.x - a.x, b.y - a.y) * mm / pts) / 1000
    }
}

@main
struct KeyMeterApp: App {
    @StateObject private var stats = Stats()

    var body: some Scene {
        MenuBarExtra("KeyMeter", systemImage: "keyboard") {
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
                    Text("Нет доступа к мониторингу ввода")
                    Text("Выдайте доступ и перезапустите KeyMeter")
                        .foregroundStyle(.secondary)
                    Button("Открыть настройки…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                Divider()
            }

            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1).gridColumnAlignment(.leading)
                    Text("Сегодня")
                    Text("Всего")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                row("Клавиши", stats.today.keys.formatted(), stats.total.keys.formatted())
                row("Клики", stats.today.clicks.formatted(), stats.total.clicks.formatted())
                row("Курсор", distance(stats.today.meters), distance(stats.total.meters))
            }
            .monospacedDigit()

            Divider()

            HStack {
                Button("О программе") { showAbout() }
                Spacer()
                Button("Выход") { stats.save(); NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }

    private func row(_ title: String, _ today: String, _ total: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(today)
            Text(total)
        }
    }

    private func distance(_ m: Double) -> String {
        m < 1000
            ? m.formatted(.number.precision(.fractionLength(1))) + " м"
            : (m / 1000).formatted(.number.precision(.fractionLength(2))) + " км"
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
