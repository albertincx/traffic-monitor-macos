import Cocoa
import Foundation

struct AppConfig: Codable {
    var interval: Double = 3.0
    var excludeLocal: Bool = true
    var menuPeriod: String = "day24h" // "session", "day24h", "week7d"
    var showSpeedInMenuBar: Bool = true
    var lang: String = "auto"
    var keepInDock: Bool = false
}

enum TimeRange: String, CaseIterable, Identifiable {
    case session = "session"
    case day24h = "day24h"
    case week7d = "week7d"
    case month30d = "month30d"
    case allTime = "allTime"

    var id: String { rawValue }

    var sinceTimestamp: Int64? {
        let now = Int64(Date().timeIntervalSince1970)
        switch self {
        case .session: return nil // handled via sessionStartTimestamp
        case .day24h: return now - 24 * 3600
        case .week7d: return now - 7 * 24 * 3600
        case .month30d: return now - 30 * 24 * 3600
        case .allTime: return 0
        }
    }

    var bucketSeconds: Int64 {
        switch self {
        case .session, .day24h: return 3600
        case .week7d, .month30d, .allTime: return 86400
        }
    }
}

struct ProcessTrafficSummary: Identifiable, Hashable {
    var id: String { processName }
    let processName: String
    let bytesIn: Int64
    let bytesOut: Int64
    let lastSeen: Int64
    let destinationCount: Int

    var totalBytes: Int64 { bytesIn + bytesOut }
}

struct DestinationTrafficSummary: Identifiable, Hashable {
    var id: String { "\(remoteIP):\(remotePort):\(proto)" }
    let remoteIP: String
    let remotePort: Int
    let proto: String
    let hostname: String?
    let bytesIn: Int64
    let bytesOut: Int64
    let firstSeen: Int64
    let lastSeen: Int64
    let processNames: String

    var totalBytes: Int64 { bytesIn + bytesOut }

    var displayHost: String {
        if let h = hostname, !h.isEmpty, h != remoteIP {
            return h
        }
        return remoteIP
    }
}

struct TimelineBucket: Identifiable {
    var id: Int64 { timestamp }
    let timestamp: Int64
    let bytesIn: Int64
    let bytesOut: Int64
}

enum ProcessSortOrder: String, CaseIterable {
    case totalDesc
    case outDesc
    case inDesc
    case nameAsc
}

enum ByteFormatter {
    static func format(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        if b < 1024 {
            return "\(Int(b)) B"
        } else if b < 1024 * 1024 {
            return String(format: "%.1f KB", b / 1024)
        } else if b < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", b / (1024 * 1024))
        } else if b < 1024 * 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
        } else {
            return String(format: "%.2f TB", b / (1024 * 1024 * 1024 * 1024))
        }
    }

    static func formatRate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        if b < 1024 {
            return "\(Int(b)) B/s"
        } else if b < 1024 * 1024 {
            return String(format: "%.0f KB/s", b / 1024)
        } else if b < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB/s", b / (1024 * 1024))
        } else {
            return String(format: "%.2f GB/s", b / (1024 * 1024 * 1024))
        }
    }

    static func formatDate(_ ts: Int64) -> String {
        guard ts > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        return df.string(from: date)
    }
}

enum L10n {
    static var activeLang: String = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("ru") ? "ru" : "en"
    }()

    static func resolve(_ configLang: String) {
        if configLang == "en" || configLang == "ru" {
            activeLang = configLang
        } else {
            let preferred = Locale.preferredLanguages.first ?? "en"
            activeLang = preferred.lowercased().hasPrefix("ru") ? "ru" : "en"
        }
    }

    private static let strings: [String: (en: String, ru: String)] = [
        "app_title": ("Traffic Monitor", "Монитор трафика"),
        "open_dashboard": ("Open Detailed Statistics…", "Открыть детальную статистику…"),
        "top_processes": ("Top Processes", "Топ процессов"),
        "no_traffic": ("No internet traffic recorded yet…", "Интернет-трафик пока не зафиксирован…"),
        "period_session": ("Session", "Сессия"),
        "period_24h": ("24 Hours", "Сутки (24ч)"),
        "period_7d": ("7 Days", "Неделя (7д)"),
        "period_30d": ("30 Days", "Месяц (30д)"),
        "period_all": ("All Time", "Всё время"),
        "menu_period": ("Menu Top Period", "Период в меню"),
        "interval": ("Update Interval", "Интервал обновления"),
        "exclude_local": ("Internet Only (Exclude LAN/Loopback)", "Только интернет (без LAN/Loopback)"),
        "show_speed_bar": ("Show Live Speed in Menu Bar", "Показывать скорость в статус-баре"),
        "keep_in_dock": ("Keep Icon in Dock", "Показывать иконку в Dock"),
        "language": ("Language", "Язык"),
        "lang_auto": ("Auto (System)", "Авто (Системный)"),
        "reset_stats": ("Reset All Statistics…", "Сбросить всю статистику…"),
        "reset_confirm_title": ("Reset Traffic Statistics?", "Сбросить статистику трафика?"),
        "reset_confirm_msg": ("All recorded historical traffic data will be permanently deleted.", "Все сохранённые данные о трафике будут безвозвратно удалены."),
        "reset_confirm_btn": ("Reset", "Сбросить"),
        "cancel": ("Cancel", "Отмена"),
        "quit": ("Quit Traffic Monitor", "Выйти"),
        "sent": ("Sent", "Отправлено"),
        "received": ("Received", "Получено"),
        "total": ("Total", "Всего"),
        "speed": ("Live Speed", "Скорость"),
        "processes": ("Processes (Who)", "Процессы (Кто)"),
        "destinations": ("Destinations (Where & When)", "Направления (Куда и Когда)"),
        "all_processes": ("All Processes", "Все процессы"),
        "search_placeholder": ("Filter process, host, IP…", "Поиск процесса, хоста, IP…"),
        "timeline": ("Traffic Timeline", "График трафика"),
        "export_csv": ("Export CSV", "Экспорт CSV"),
        "refresh": ("Refresh", "Обновить"),
        "host_ip": ("Destination (Host / IP)", "Адрес (Хост / IP)"),
        "proto_port": ("Proto / Port", "Протокол / Порт"),
        "when_last": ("Last Active", "Последняя активность"),
        "when_first": ("First Seen", "Начало"),
        "sort_total": ("Total", "Всего"),
        "sort_sent": ("Sent ↑", "Отправлено ↑"),
        "sort_recv": ("Received ↓", "Получено ↓"),
        "sort_name": ("Name", "Имя"),
        "short_lived": ("(short-lived / closed connections)", "(короткие / закрытые соединения)"),
        "active_procs": ("Processes", "Процессов"),
        "active_dests": ("Destinations", "Адресов"),
        "by_process_tab": ("By Process", "По процессам"),
        "all_dests_tab": ("All Destinations", "Все направления")
    ]

    static func t(_ key: String) -> String {
        guard let pair = strings[key] else { return key }
        return activeLang == "ru" ? pair.ru : pair.en
    }
}
