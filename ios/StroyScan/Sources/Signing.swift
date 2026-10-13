import SwiftUI
import UserNotifications

/// Установка через Sideloadly с бесплатным Apple ID живёт 7 дней. Срок берём из профиля внутри приложения
/// (embedded.mobileprovision), показываем на главном и ставим напоминание за день и в последний день.
enum Signing {
    /// Когда приложение перестанет открываться; nil — профиля нет (App Store, симулятор)
    static let expires: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // внутри подписи лежит обычный plist — вырезаем его
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }()

    /// Сколько полных дней осталось (0 — сегодня последний)
    static var daysLeft: Int? {
        guard let expires else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: Date(), to: expires).day ?? 0)
    }

    /// Напоминания: за сутки и за 3 часа до конца. Разрешение спрашиваем один раз
    static func scheduleReminders() {
        guard let expires, expires > Date() else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            center.removePendingNotificationRequests(withIdentifiers: ["resign-1d", "resign-3h"])
            let plan: [(String, TimeInterval, String)] = [
                ("resign-1d", 24 * 3600, "Завтра СтройСкан перестанет открываться"),
                ("resign-3h", 3 * 3600, "Через 3 часа СтройСкан перестанет открываться"),
            ]
            for (id, before, title) in plan {
                let at = expires.addingTimeInterval(-before)
                guard at > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = "Подключите iPhone к компьютеру и переустановите через Sideloadly — сканы и настройки сохранятся."
                content.sound = .default
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }
}

/// Плашка на главном: сколько дней осталось до переустановки. Яркая, когда осталось 2 дня и меньше
struct SigningBanner: View {
    @State private var open = false

    var body: some View {
        if let expires = Signing.expires, let days = Signing.daysLeft {
            let urgent = days <= 2
            Button { withAnimation(.spring(response: 0.35)) { open.toggle() } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: urgent ? "exclamationmark.arrow.circlepath" : "calendar.badge.clock")
                            .font(.title3)
                            .foregroundStyle(urgent ? Palette.ink : Palette.signal)
                            .symbolEffectPulse(urgent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(days)).font(.subheadline.bold())
                            Text("до \(expires.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                                .foregroundStyle(urgent ? Palette.ink.opacity(0.7) : .secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption.bold()).rotationEffect(.degrees(open ? 180 : 0))
                            .foregroundStyle(.secondary)
                    }
                    if open {
                        Text("Бесплатная установка через Sideloadly действует 7 дней. Перед концом срока подключите iPhone к компьютеру кабелем, откройте Sideloadly и установите приложение заново тем же Apple ID. Сканы, квартиры и настройки останутся. За день до конца придёт напоминание.")
                            .font(.caption).foregroundStyle(urgent ? Palette.ink.opacity(0.8) : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(14)
                .background(urgent ? Palette.signal : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(urgent ? Palette.ink : Color.primary)
            }
            .buttonStyle(.plain)
            .onAppear { Signing.scheduleReminders() }
        }
    }

    private func title(_ days: Int) -> String {
        switch days {
        case 0: return "Сегодня последний день — переустановите"
        case 1: return "Завтра нужно переустановить"
        default: return "Переустановка через \(days) \(plural(days, "день", "дня", "дней"))"
        }
    }
}

private extension View {
    /// Мягкая пульсация значка (iOS 17), на iOS 16 — без неё
    @ViewBuilder func symbolEffectPulse(_ on: Bool) -> some View {
        if #available(iOS 17.0, *), on {
            self.symbolEffect(.pulse)
        } else {
            self
        }
    }
}
