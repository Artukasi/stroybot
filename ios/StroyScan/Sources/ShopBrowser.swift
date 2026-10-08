import SwiftUI
import WebKit

/// Страница магазина внутри приложения. Настоящий браузер: открываются и сайты, которые
/// не отдают страницу «простому» запросу (Ozon, Wildberries и т. п.). Кнопка «Взять» собирает
/// с открытой страницы название, текст с размерами и картинки товара — пользователь выбирает нужную.
struct ShopPageView: View {
    let start: URL
    /// Что берём: «плитку», «товар»
    var what = "плитку"
    let onPick: (TileLinkFound, UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var page = ShopPage()
    @State private var grabbed: ShopPage.Grab?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ShopWebView(page: page, start: start)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 8) {
                    if let problem {
                        Text(problem).font(.footnote).padding(10)
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button { Task { await grab() } } label: {
                        HStack {
                            if page.grabbing { ProgressView() } else { Image(systemName: "square.and.arrow.down.on.square") }
                            Text(page.grabbing ? "Собираю со страницы…" : "Взять \(what) с этой страницы").bold()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Palette.signal, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(Palette.ink)
                    }
                    .disabled(page.loading || page.grabbing)
                }
                .padding()
            }
            .navigationTitle(page.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { page.web?.goBack() } label: { Image(systemName: "chevron.backward") }.disabled(!page.canBack)
                    if page.loading { ProgressView() } else {
                        Button { page.web?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .sheet(item: $grabbed) { g in
                ShopImagePicker(grab: g, page: page) { found, img in
                    onPick(found, img)
                    grabbed = nil
                    dismiss()
                }
            }
        }
    }

    private func grab() async {
        problem = nil
        do {
            let g = try await page.grab()
            if g.images.isEmpty {
                problem = "Картинок товара на экране не нашёл. Откройте карточку товара (не список) и нажмите ещё раз."
            } else {
                grabbed = g
            }
        } catch {
            problem = "Страница ещё грузится или не отвечает. Подождите секунду и нажмите ещё раз."
        }
    }
}

/// Выбор картинки, найденной на странице
struct ShopImagePicker: View {
    let grab: ShopPage.Grab
    let page: ShopPage
    let onDone: (TileLinkFound, UIImage) -> Void
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var taking: Int?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(grab.name).font(.headline)
                    if let s = grab.size {
                        Label("Размер: \(fmt(s.0)) × \(fmt(s.1)) см", systemImage: "ruler").font(.subheadline)
                    }
                    Text("Нажмите на картинку, где лучше всего виден сам товар — без интерьера вокруг.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        ForEach(Array(grab.images.enumerated()), id: \.offset) { i, img in
                            Button { Task { await take(i) } } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
                                    if let t = thumbs[i] {
                                        Image(uiImage: t).resizable().scaledToFill()
                                    } else {
                                        ProgressView()
                                    }
                                    if taking == i { Color.black.opacity(0.35); ProgressView().tint(.white) }
                                }
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topLeading) {
                                    if i == 0 && img.main {
                                        Text("главная").font(.caption2.bold()).padding(4)
                                            .background(Palette.signal, in: Capsule()).padding(5)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(taking != nil)
                            .task { if thumbs[i] == nil, let t = await page.image(img) { thumbs[i] = t } }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Какая картинка?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func take(_ i: Int) async {
        taking = i
        defer { taking = nil }
        let img = grab.images[i]
        // картинка в полном размере; если сайт её не отдаёт — снимок с экрана браузера
        guard let picture = await page.image(img, full: true) else {
            problem = "Эту картинку сайт не отдаёт. Выберите другую или добавьте плитку по фото (скриншот)."
            return
        }
        var found = TileLinkFound(image: img.url, name: grab.name, width: grab.size?.0, height: grab.size?.1)
        found.text = grab.text
        found.page = grab.url
        onDone(found, picture)
    }
}

@MainActor
final class ShopPage: NSObject, ObservableObject, WKNavigationDelegate {
    struct Picture {
        let url: URL
        /// og:image или картинка товара из разметки — обычно главная
        let main: Bool
        /// номер элемента <img> на странице — для снимка с экрана
        let tag: String
    }
    struct Grab: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let text: String
        let size: (Double, Double)?
        let images: [Picture]
    }

    @Published var loading = false
    @Published var grabbing = false
    @Published var canBack = false
    @Published var host = ""
    weak var web: WKWebView?
    private var cache: [URL: UIImage] = [:]

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { update(webView, loading: true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update(webView, loading: false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { update(webView, loading: false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        update(webView, loading: false)
    }

    private func update(_ w: WKWebView, loading: Bool) {
        self.loading = loading
        canBack = w.canGoBack
        host = (w.url?.host ?? "").replacingOccurrences(of: "www.", with: "")
    }

    /// Собрать со страницы: разметка товара (JSON-LD), og:*, крупные картинки, текст с размерами
    func grab() async throws -> Grab {
        guard let web else { throw URLError(.cancelled) }
        grabbing = true
        defer { grabbing = false }
        let raw = try await web.evaluateJavaScript(Self.script)
        guard let s = raw as? String, let data = s.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let page = URL(string: j["url"] as? String ?? "") ?? web.url ?? URL(string: "about:blank")!
        var name = (j["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = TileLink.unescape(name)
        if name.count > 80 { name = String(name.prefix(80)) }
        let props = j["props"] as? String ?? "", desc = j["desc"] as? String ?? "", text = j["text"] as? String ?? ""
        let size = TileLink.tileSize(name: name, props: props, desc: desc, text: text)
        let images: [Picture] = (j["images"] as? [[String: Any]] ?? []).compactMap { d in
            guard let src = d["src"] as? String, let u = URL(string: src) else { return nil }
            return Picture(url: u, main: d["main"] as? Bool ?? false, tag: d["tag"] as? String ?? "")
        }
        return Grab(url: page, name: name.isEmpty ? (page.host ?? "Товар") : name,
                    text: [name, props, desc, text].joined(separator: " "), size: size, images: images)
    }

    /// Картинка: скачиваем как браузер (с адресом страницы), не вышло — снимок элемента с экрана
    func image(_ p: Picture, full: Bool = false) async -> UIImage? {
        if let c = cache[p.url] { return c }
        var req = URLRequest(url: p.url, timeoutInterval: 20)
        req.setValue(TileLink.agent, forHTTPHeaderField: "User-Agent")
        if let page = web?.url { req.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        req.setValue("image/avif,image/webp,image/jpeg,image/png,*/*", forHTTPHeaderField: "Accept")
        if let (data, _) = try? await URLSession.shared.data(for: req), let img = UIImage(data: data), img.size.width >= 40 {
            cache[p.url] = img
            return img
        }
        guard full, !p.tag.isEmpty else { return nil }
        return await snapshot(tag: p.tag)
    }

    private func snapshot(tag: String) async -> UIImage? {
        guard let web else { return nil }
        let js = "(function(){var e=document.querySelector('[data-sb-id=\"\(tag)\"]');if(!e)return '';e.scrollIntoView({block:'center'});var r=e.getBoundingClientRect();return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height})})()"
        guard let s = try? await web.evaluateJavaScript(js) as? String, let data = s.data(using: .utf8),
              let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Double],
              let w = r["w"], let h = r["h"], w > 20, h > 20 else { return nil }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: r["x"] ?? 0, y: r["y"] ?? 0, width: w, height: h)
        return try? await web.takeSnapshot(configuration: cfg)
    }

    static let script = """
    (function(){
      function meta(n){var e=document.querySelector('meta[property="'+n+'"],meta[name="'+n+'"],meta[itemprop="'+n+'"]');return e?e.getAttribute('content'):null}
      function abs(u){try{return new URL(u,location.href).href}catch(e){return null}}
      var ld=[];
      document.querySelectorAll('script[type="application/ld+json"]').forEach(function(s){
        try{var j=JSON.parse(s.textContent);(Array.isArray(j)?j:[j]).forEach(function(x){if(x&&x['@graph'])ld=ld.concat(x['@graph']);else if(x)ld.push(x)})}catch(e){}
      });
      var prod=ld.find(function(x){var t=x['@type'];return t==='Product'||(Array.isArray(t)&&t.indexOf('Product')>=0)})||{};
      var pimg=prod.image;if(Array.isArray(pimg))pimg=pimg[0];if(pimg&&typeof pimg==='object')pimg=pimg.url||pimg.contentUrl;
      var props=(Array.isArray(prod.additionalProperty)?prod.additionalProperty:[]).map(function(p){return (p.name||'')+': '+(p.value||'')+' '+(p.unitText||'')}).join('; ');
      ['width','height','depth'].forEach(function(k){var v=prod[k];if(v)props+='; '+({width:'Ширина',height:'Высота',depth:'Глубина'})[k]+': '+(v.value||v)+' '+(v.unitText||v.unitCode||'')});
      var imgs=[],seen={},n=0;
      function add(src,area,main,el){src=abs(src);if(!src||src.indexOf('data:')===0||seen[src])return;seen[src]=1;
        var tag='';if(el){tag=el.getAttribute('data-sb-id')||String(++n);el.setAttribute('data-sb-id',tag)}
        imgs.push({src:src,area:area,main:main,tag:tag})}
      if(pimg)add(pimg,1e9,true,null);
      var og=meta('og:image')||meta('og:image:secure_url')||meta('twitter:image');if(og)add(og,1e9-1,true,null);
      Array.from(document.images).forEach(function(i){var r=i.getBoundingClientRect();var w=i.naturalWidth||r.width,h=i.naturalHeight||r.height;
        if(w>=150&&h>=150&&r.width>=60&&r.height>=60){var big=i.getAttribute('data-zoom-image')||i.getAttribute('data-large')||i.getAttribute('data-src');add(big||i.currentSrc||i.src,w*h,false,i)}});
      var main=imgs.filter(function(x){return x.main}),rest=imgs.filter(function(x){return !x.main}).sort(function(a,b){return b.area-a.area});
      imgs=main.concat(rest).slice(0,18);
      var h1=document.querySelector('h1');
      var name=prod.name||(h1&&h1.innerText)||meta('og:title')||document.title||'';
      var desc=(prod.description||meta('og:description')||meta('description')||'').slice(0,3000);
      return JSON.stringify({url:location.href,name:name,props:props,desc:desc,images:imgs,text:(document.body&&document.body.innerText||'').slice(0,300000)});
    })()
    """
}

struct ShopWebView: UIViewRepresentable {
    let page: ShopPage
    let start: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.customUserAgent = TileLink.agent
        w.allowsBackForwardNavigationGestures = true
        w.navigationDelegate = page
        page.web = w
        w.load(URLRequest(url: start))
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Поиск в магазинах: открывается в том же браузере, оттуда «Взять»
enum ShopSearch {
    static let shops: [(name: String, base: String)] = [
        ("Лемана ПРО", "https://lemanapro.ru/search/?q="),
        ("Петрович", "https://petrovich.ru/search/?q="),
        ("Яндекс Маркет", "https://market.yandex.ru/search?text="),
        ("Ozon", "https://www.ozon.ru/search/?text="),
        ("Wildberries", "https://www.wildberries.ru/catalog/0/search.aspx?search="),
    ]

    static func url(_ base: String, _ query: String) -> URL? {
        URL(string: base + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query))
    }
}

/// Ссылка из текста «Поделиться» (там бывает название, а ссылка в конце)
func linkIn(_ text: String) -> URL? {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let r = s.range(of: #"https?://[^\s]+"#, options: .regularExpression) {
        s = String(s[r])
    } else if s.range(of: #"^[\w.-]+\.[a-zа-я]{2,}(/|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
        s = "https://" + s   // «lemanapro.ru/product/…» без https
    } else {
        return nil
    }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)»\"'"))
    guard let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
          url.scheme?.hasPrefix("http") == true, url.host != nil else { return nil }
    return url
}
