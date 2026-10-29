import SwiftUI

/// Verified public category links; no invented product IDs or cart API calls.
/// Product selection, stock and the final cart remain on the merchant's site.
enum PetrovichCatalog {
    static let base = "https://petrovich.ru"
    static let catalog = base + "/catalog/"

    static func category(for name: String) -> (title: String, url: URL) {
        let n = name.lowercased().replacingOccurrences(of: "ё", with: "е")
        let choice: (String, String)
        if n.contains("профил") {
            choice = ("Профили для ГКЛ", "12082/")
        } else if n.contains("саморез") {
            choice = ("Саморезы для ГКЛ", "9968/")
        } else if n.contains("гипсокартон") || n.contains("гкл") || n.contains("гвл") {
            choice = ("Гипсокартон", "113714477/")
        } else if n.contains("шпаклев") || n.contains("шпатлев") {
            choice = ("Шпаклёвки", "12092/")
        } else if n.contains("грунт") || n.contains("праймер") {
            choice = ("Грунтовки", "6615/")
        } else if n.contains("плиточн") && n.contains("клей") || n.contains("клей для плит") {
            choice = ("Плиточные клеи и смеси", "1445/")
        } else if n.contains("керамическ") || n.contains("керамогранит") || n.contains("плитка") {
            choice = ("Плитка", "10042/")
        } else if n.contains("штукатур") || n.contains("стяжк") || n.contains("ровнител") ||
                    n.contains("сухая смесь") || n.contains("сухой смеси") {
            choice = ("Строительные смеси", "1445/")
        } else {
            choice = ("Каталог Петровича", "")
        }
        return (choice.0, URL(string: catalog + choice.1)!)
    }

    static func query(_ material: String, package: String = "") -> String {
        let cleaned = material.trimmingCharacters(in: .whitespacesAndNewlines)
        return package.isEmpty ? cleaned : cleaned + " " + package
    }
}

/// Every line in a calculated takeoff can be looked up directly in the supplier catalog.
/// We never pretend a category selection is a verified exact item or in-cart order.
struct PetrovichMaterialLink: View {
    let name: String
    var package: String = ""
    @State private var copied = false

    private var category: (title: String, url: URL) {
        PetrovichCatalog.category(for: name)
    }

    var body: some View {
        HStack(spacing: 14) {
            Link(destination: category.url) {
                Label("В Петровиче", systemImage: "cart.badge.plus")
            }
            Button {
                UIPasteboard.general.string = PetrovichCatalog.query(name, package: package)
                copied = true
            } label: {
                Label(copied ? "Скопировано" : "Название", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .font(.caption.bold())
        .accessibilityElement(children: .contain)
    }
}

/// Category shortcuts under an AI text answer. Do not parse arbitrary numbers as product quantities.
struct PetrovichAnswerLinks: View {
    let answer: String

    private var matches: [(name: String, url: URL)] {
        let words = answer.lowercased().replacingOccurrences(of: "ё", with: "е")
        let candidates = [
            "гипсокартон", "гкл", "профиль", "саморез", "шпаклевка", "шпатлевка", "грунтовка", "плиточный клей",
            "керамогранит", "штукатурка"
        ]
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard words.contains(candidate) else { return nil }
            let pair = PetrovichCatalog.category(for: candidate)
            guard seen.insert(pair.url.absoluteString).inserted else { return nil }
            return (name: pair.title, url: pair.url)
        }
    }

    var body: some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Материалы в Петровиче", systemImage: "cart")
                    .font(.headline)
                Text("Открой нужный раздел, выбери товар по назначению и упаковке и добавь его в корзину магазина.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(matches.indices, id: \.self) { index in
                    let match = matches[index]
                    Link(destination: match.url) {
                        HStack {
                            Text(match.name)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
