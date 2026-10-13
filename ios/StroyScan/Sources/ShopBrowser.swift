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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                                            .transition(.opacity)
                                    } else {
                                        ProgressView()
                                    }
                                    if taking == i {
                                        Color.black.opacity(0.35).transition(.opacity)
                                        ProgressView().tint(.white).transition(.opacity)
                                    }
                                }
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .animation(reduceMotion ? .easeOut(duration: 0.12) : AppMotion.fade,
                                           value: thumbs[i] != nil)
                                .animation(reduceMotion ? .easeOut(duration: 0.12) : AppMotion.press,
                                           value: taking == i)
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
        // Many stores lazy-load their product photos after navigation or scrolling.
        _ = try? await web.evaluateJavaScript(Self.prepareImagesScript)
        try? await Task.sleep(nanoseconds: 450_000_000)
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
        req.setValue("image/webp,image/jpeg,image/png,*/*", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await URLSession.shared.data(for: req),
           (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
           !((response as? HTTPURLResponse)?.mimeType?.lowercased().contains("text/html") ?? false),
           let img = UIImage(data: data), img.size.width >= 50, img.size.height >= 50 {
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
        try? await Task.sleep(nanoseconds: 650_000_000)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: r["x"] ?? 0, y: r["y"] ?? 0, width: w, height: h)
        return try? await web.takeSnapshot(configuration: cfg)
    }

    static let prepareImagesScript = """
    (function(){
      Array.from(document.images).slice(0,80).forEach(function(i){
        i.loading='eager';
        var lazy=i.getAttribute('data-zoom-image')||i.getAttribute('data-large')||i.getAttribute('data-original')||i.getAttribute('data-lazy-src')||i.getAttribute('data-src');
        if(lazy&&(!i.currentSrc||i.currentSrc.indexOf('data:')===0))i.src=lazy;
      });
      window.dispatchEvent(new Event('scroll'));
      return true;
    })()
    """

    static let script = """
    (function(){
      function meta(n){var e=document.querySelector('meta[property="'+n+'"],meta[name="'+n+'"],meta[itemprop="'+n+'"]');return e?e.getAttribute('content'):null}
      function abs(u){try{return new URL(u,location.href).href}catch(e){return null}}
      var ld=[];
      function walk(x,depth){if(!x||depth>5)return;if(Array.isArray(x)){x.forEach(function(y){walk(y,depth+1)});return}
        if(typeof x!=='object')return;ld.push(x);
        ['@graph','mainEntity','hasVariant','itemListElement'].forEach(function(k){if(x[k])walk(x[k],depth+1)})}
      document.querySelectorAll('script[type="application/ld+json"]').forEach(function(s){try{walk(JSON.parse(s.textContent),0)}catch(e){}});
      function isProduct(x){var t=x&&x['@type'];if(!Array.isArray(t))t=[t];return t.some(function(v){var n=String(v||'').split(/[\/#]/).pop();return n==='Product'||n==='ProductGroup'})}
      function score(x){return (x.name?4:0)+(x.image?3:0)+(x.description?1:0)+(x.additionalProperty?2:0)+(x.width||x.height||x.depth?3:0)}
      var products=ld.filter(isProduct).sort(function(a,b){return score(b)-score(a)});
      var prod=products.find(function(x){return x.image||x.name})||{};
      if(prod.hasVariant&&Array.isArray(prod.hasVariant)){var v=prod.hasVariant.find(function(x){return x.image})||prod.hasVariant[0];if(v)prod=v}
      function imageURL(v){if(typeof v==='string')return v;if(v&&typeof v==='object')return v.url||v.contentUrl||v['@id'];return null}
      var imgs=[],seen={},n=0;
      function add(src,area,main,el,rank){src=abs(src);if(!src||/^data:|\.svg(?:$|\?)/i.test(src))return;
        var old=seen[src];if(old){
          old.main=old.main||main;old.rank=Math.max(old.rank,rank||0);
          if(el&&!old.tag){old.tag=el.getAttribute('data-sb-id')||String(++n);el.setAttribute('data-sb-id',old.tag)}
          return
        }
        var tag='';if(el){tag=el.getAttribute('data-sb-id')||String(++n);el.setAttribute('data-sb-id',tag)}
        var entry={src:src,area:area||0,main:!!main,tag:tag,rank:rank||0};seen[src]=entry;imgs.push(entry)}
      var pimgs=Array.isArray(prod.image)?prod.image:[prod.image];pimgs.forEach(function(x){var u=imageURL(x);if(u)add(u,1e9,true,null,100)});
      var og=meta('og:image:secure_url')||meta('og:image')||meta('twitter:image');if(og)add(og,1e8,true,null,80);
      function bestSrc(i){var attrs=['data-zoom-image','data-large','data-original','data-lazy-src','data-src','data-original-src'];
        for(var a=0;a<attrs.length;a++){var v=i.getAttribute(attrs[a]);if(v&&v.length>8)return v}
        var sets=(i.getAttribute('srcset')||'').split(',').map(function(s){var p=s.trim().split(/\s+/);return {url:p[0],size:parseFloat(p[1])||0}}).sort(function(a,b){return b.size-a.size});
        return (sets[0]&&sets[0].url)||i.currentSrc||i.src}
      Array.from(document.images).forEach(function(i){var r=i.getBoundingClientRect(),w=i.naturalWidth||Number(i.getAttribute('width'))||r.width,h=i.naturalHeight||Number(i.getAttribute('height'))||r.height;
        var src=bestSrc(i),hint=((i.alt||'')+' '+(i.title||'')+' '+(i.className||'')+' '+src).toLowerCase();
        if(!src||w<100||h<100||r.width<45||r.height<45)return;
        if(/logo|sprite|favicon|avatar|payment|delivery|banner|badge|widget|qr-code|social-icon/.test(hint))return;
        var rank=(/product|catalog|goods|tile|sku|gallery|detail|zoom/.test(hint)?30:0)-(/recommend|similar|recently|review/.test(hint)?25:0);
        add(src,w*h,false,i,rank)});
      imgs.sort(function(a,b){if(a.main!==b.main)return a.main?-1:1;return b.rank-a.rank||b.area-a.area});
      imgs=imgs.slice(0,24);
      var h1=document.querySelector('h1');
      var name=prod.name||(h1&&h1.innerText)||meta('og:title')||document.title||'';
      var desc=String(prod.description||meta('og:description')||meta('description')||'').slice(0,3000);
      function val(v){if(v&&typeof v==='object'){var u=v.unitText||v.unitCode||'';if(u==='CMT')u='см';else if(u==='MMT')u='мм';else if(u==='MTR')u='м';return (v.value||v.name||'')+' '+u}return v||''}
      var props=(Array.isArray(prod.additionalProperty)?prod.additionalProperty:[]).map(function(p){return (p.name||'')+': '+val(p.value)}).join('; ');
      ['width','height','depth'].forEach(function(k){var v=prod[k];if(v)props+='; '+({width:'Ширина',height:'Высота',depth:'Глубина'})[k]+': '+val(v)});
      var facts=Array.from(document.querySelectorAll('[itemprop],tr')).slice(0,100).map(function(e){return (e.innerText||e.content||'').trim()}).filter(Boolean).join('; ');
      var root=document.querySelector('[itemtype*="Product"]')||document.querySelector('main')||document.body;
      var text=((root&&root.innerText)||'').replace(/\s+/g,' ').slice(0,18000);
      return JSON.stringify({url:location.href,name:name,props:(props+'; '+facts).slice(0,12000),desc:desc,images:imgs,text:text});
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
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: base + encoded)
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
