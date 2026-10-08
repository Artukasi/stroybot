import PhotosUI
import SwiftUI

/// Бригада: название, телефон и логотип — в шапке каждого PDF и чертежа
struct Brand {
    var name: String
    var phone: String
    var note: String

    var isEmpty: Bool { name.isEmpty && phone.isEmpty && note.isEmpty && Brand.logo == nil }

    private static let defaults = UserDefaults.standard

    static var current: Brand {
        Brand(name: defaults.string(forKey: "brand.name") ?? "",
              phone: defaults.string(forKey: "brand.phone") ?? "",
              note: defaults.string(forKey: "brand.note") ?? "")
    }

    func save() {
        let trim = { (s: String) in String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        Brand.defaults.set(trim(name), forKey: "brand.name")
        Brand.defaults.set(trim(phone), forKey: "brand.phone")
        Brand.defaults.set(trim(note), forKey: "brand.note")
    }

    private static var logoURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("StroyScan")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("logo.png")
    }

    static var logo: UIImage? { UIImage(contentsOfFile: logoURL.path) }

    /// Логотип уменьшаем до 400 точек по большей стороне — PDF остаётся лёгким
    static func setLogo(_ image: UIImage?) {
        guard let image else {
            try? FileManager.default.removeItem(at: logoURL)
            return
        }
        let k = min(1, 400 / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * k, height: image.size.height * k)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try? small.pngData()?.write(to: logoURL, options: .atomic)
    }
}

struct BrandView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var brand = Brand.current
    @State private var logo = Brand.logo
    @State private var picked: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Так будет выглядеть шапка PDF-плана и чертежа, которые вы отправляете клиенту.")
                }
                Section("Бригада") {
                    TextField("Название, например «Ремонт под ключ — Артём»", text: $brand.name)
                    TextField("Телефон", text: $brand.phone).keyboardType(.phonePad)
                    TextField("Ещё строка: Telegram, сайт, город", text: $brand.note)
                }
                Section("Логотип") {
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label(logo == nil ? "Выбрать картинку" : "Заменить картинку", systemImage: "photo")
                    }
                    if logo != nil {
                        Button("Убрать логотип", role: .destructive) { logo = nil }
                    }
                }
            }
            .navigationTitle("Моя бригада")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        brand.save()
                        Brand.setLogo(logo)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onChange(of: picked) { item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        logo = img
                    }
                }
            }
        }
    }

    /// Живой предпросмотр шапки
    private var preview: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ПЛАН ПОМЕЩЕНИЯ").font(.caption2.bold()).foregroundStyle(Palette.signal)
                Text("Кухня").font(.title2.bold()).foregroundStyle(.white)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                ForEach([brand.name, brand.phone, brand.note].filter { !$0.isEmpty }, id: \.self) {
                    Text($0).font(.caption2).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                if brand.name.isEmpty && brand.phone.isEmpty && brand.note.isEmpty {
                    Text("СтройСкан").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            if let logo {
                Image(uiImage: logo).resizable().scaledToFit()
                    .frame(maxWidth: 70, maxHeight: 44)
                    .padding(3).background(.white, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
        .background(Palette.ink)
        .overlay(alignment: .bottom) { Palette.signal.frame(height: 4) }
        .animation(.spring(response: 0.35), value: logo != nil)
    }
}
