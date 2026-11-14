import SwiftUI
import CoreGraphics

final class Stats: ObservableObject {
    @Published var keys: Int
    @Published var meters: Double
    @Published var clicks: Int
    @Published var hasAccess = false

    private var tap: CFMachPort?
    private var last: CGPoint?
    private let defaults = UserDefaults.standard

    init() {
        keys = defaults.integer(forKey: "keys")
        meters = defaults.double(forKey: "meters")
        clicks = defaults.integer(forKey: "clicks")
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        // ждём, пока дадут доступ к мониторингу ввода
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.startTap() == true { t.invalidate() }
        }
        _ = startTap()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.save() }
    }

    func save() {
        defaults.set(keys, forKey: "keys")
        defaults.set(meters, forKey: "meters")
        defaults.set(clicks, forKey: "clicks")
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
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { keys += 1 }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            clicks += 1
        default:
            let p = event.location
            if let l = last { meters += distance(from: l, to: p) }
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
            if !stats.hasAccess {
                Text("Нет доступа к мониторингу ввода")
                Text("Выдайте доступ и перезапустите KeyMeter")
                Button("Открыть настройки…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                Divider()
            }
            Text("Нажатий клавиш: \(stats.keys)")
            Text("Кликов мыши: \(stats.clicks)")
            Text(String(format: "Курсор прошёл: %.2f м", stats.meters))
            Divider()
            Button("О программе KeyMeter") { showAbout() }
            Button("Выход") { stats.save(); NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
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
    let credits = NSMutableAttributedString(
        string: "Считает нажатия клавиш и путь курсора в метрах.\n\nРазработчик: cheeselover419\n", attributes: base)
    var link = base
    link[.link] = URL(string: "https://github.com/cheeselover419")!
    credits.append(NSAttributedString(string: "github.com/cheeselover419", attributes: link))

    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
}
