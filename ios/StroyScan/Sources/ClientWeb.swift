import UIKit
import simd

// MARK: - Файл для клиента: одна страница, открывается в любом браузере

/// Комната в 3D (крутится пальцем), план с размерами, смета, отделка и заметки — всё в одном .html без интернета.
/// План и смета видны даже там, где скрипты выключены (просмотр файлов на iPhone); 3D — в браузере.
enum ClientWeb {
    struct Extra {
        var client = ""
        var address = ""
        var finishing: String?
        var withEstimate = true
        var withDefects = true
        var defectPhoto: (UUID) -> UIImage? = { _ in nil }
    }

    static func file(_ r: RoomResult, look: Look, extra: Extra) -> URL? {
        let html = page(r, look: look, extra: extra)
        let safe = r.room.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ремонт — \(safe).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    private static func dataURL(_ img: UIImage, side: CGFloat) -> String? {
        let k = min(1, side / max(img.size.width, img.size.height, 1))
        let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return small.jpegData(compressionQuality: 0.75).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }

    /// Стены: из wallLines, а если их нет — по контуру пола
    private static func wallSegments(_ r: RoomResult) -> [SIMD4<Double>] {
        if !r.wallLines.isEmpty { return r.wallLines }
        guard r.plan.count > 2 else { return [] }
        return zip(r.plan, r.plan.dropFirst() + [r.plan[0]]).map { SIMD4($0.0.x, $0.0.y, $0.1.x, $0.1.y) }
    }

    // MARK: Данные для 3D

    static func sceneJSON(_ r: RoomResult, look: Look) -> String {
        let walls = wallSegments(r)
        var openings: [[String: Any]] = []
        for o in r.openings {
            guard let w = o.wall, w < walls.count, let off = o.offset else { continue }
            let l = walls[w]
            let a = SIMD2(l.x, l.y), b = SIMD2(l.z, l.w)
            let len = simd_distance(a, b)
            guard len > 0.01 else { continue }
            let c = a + (b - a) / len * off
            openings.append(["wall": w, "x": r2(c.x), "y": r2(c.y), "w": r2(o.width), "h": r2(o.height),
                             "b": r2(o.bottom ?? (o.kind == "window" ? 0.85 : 0)), "kind": o.kind])
        }
        var boxes: [[String: Any]] = []
        for (i, it) in r.items.enumerated() where look.objects[String(i)]?.hidden != true {
            boxes.append(["x": r2(it.x), "y": r2(it.y), "a": r2(it.angle), "w": r2(it.width), "d": r2(it.depth), "h": r2(it.height),
                          "b": r2(it.bottom), "c": look.objects[String(i)]?.color ?? "#b9b2a6", "t": it.title])
        }
        for a in look.added {
            boxes.append(["x": r2(a.x), "y": r2(a.y), "a": r2(a.angle), "w": r2(a.width), "d": r2(a.depth), "h": r2(a.height),
                          "b": a.kind == "television" ? 0.75 : 0, "c": a.color, "t": RoomResult.itemTitle(a.kind)])
        }
        for p in r.tiling.pieces {
            boxes.append(["x": r2(p.x), "y": r2(p.y), "a": r2(p.angle), "w": r2(p.width), "d": r2(p.depth), "h": r2(p.height),
                          "b": 0, "c": "#9aa7b5", "t": p.name])
        }
        var d: [String: Any] = [
            "poly": r.plan.map { [r2($0.x), r2($0.y)] },
            "walls": walls.map { [r2($0.x), r2($0.y), r2($0.z), r2($0.w)] },
            "h": r2(r.height > 0 ? r.height : 2.7),
            "openings": openings,
            "boxes": boxes,
            "wall": look.wall.color,
            "floor": look.floor.color,
        ]
        if let a = look.accent { d["accent"] = ["wall": a.wall, "color": a.color] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: d),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s.replacingOccurrences(of: "</", with: "<\\/")
    }

    // MARK: План SVG — виден и без скриптов

    static func planSVG(_ r: RoomResult) -> String {
        let pts = r.plan
        guard pts.count > 2 else { return "" }
        let lo = pts.reduce(pts[0]) { simd_min($0, $1) }, hi = pts.reduce(pts[0]) { simd_max($0, $1) }
        let pad = 0.7
        let w = hi.x - lo.x + 2 * pad, h = hi.y - lo.y + 2 * pad
        let k = 600 / max(w, h)
        let X = { (v: Double) in String(format: "%.1f", (v - lo.x + pad) * k) }
        let Y = { (v: Double) in String(format: "%.1f", (v - lo.y + pad) * k) }
        var s = "<svg viewBox=\"0 0 \(Int(w * k)) \(Int(h * k))\" xmlns=\"http://www.w3.org/2000/svg\" class=\"plan\">"
        s += "<polygon points=\"" + pts.map { "\(X($0.x)),\(Y($0.y))" }.joined(separator: " ")
            + "\" fill=\"#eef2f7\" stroke=\"#14202e\" stroke-width=\"5\" stroke-linejoin=\"round\"/>"
        let c = pts.reduce(SIMD2<Double>.zero, +) / Double(pts.count)
        for it in r.items {
            let deg = it.angle * 180 / .pi
            s += "<g transform=\"translate(\(X(it.x)) \(Y(it.y))) rotate(\(String(format: "%.1f", deg)))\">"
            s += "<rect x=\"\(String(format: "%.1f", -it.width / 2 * k))\" y=\"\(String(format: "%.1f", -it.depth / 2 * k))\" "
            s += "width=\"\(String(format: "%.1f", it.width * k))\" height=\"\(String(format: "%.1f", it.depth * k))\" rx=\"4\" fill=\"#d9d3c8\" stroke=\"#8c8476\" stroke-width=\"1.5\"/></g>"
        }
        let walls = wallSegments(r)
        for (i, l) in walls.enumerated() {
            let a = SIMD2(l.x, l.y), b = SIMD2(l.z, l.w)
            let len = simd_distance(a, b)
            guard len > 0.3 else { continue }
            let mid = (a + b) / 2
            var n = SIMD2(-(b.y - a.y), b.x - a.x) / len
            if simd_dot(n, c - mid) > 0 { n = -n }
            let t = mid + n * 0.38
            let label = i < r.walls.count ? r.walls[i].length : len
            s += "<text x=\"\(X(t.x))\" y=\"\(Y(t.y))\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-size=\"22\" font-weight=\"700\" fill=\"#14202e\">"
            s += String(format: "%.2f", label).replacingOccurrences(of: ".", with: ",") + "</text>"
        }
        for o in r.openings {
            guard let wi = o.wall, wi < walls.count, let off = o.offset else { continue }
            let l = walls[wi]
            let a = SIMD2(l.x, l.y), b = SIMD2(l.z, l.w)
            let len = simd_distance(a, b)
            guard len > 0.01 else { continue }
            let u = (b - a) / len
            let p1 = a + u * (off - o.width / 2), p2 = a + u * (off + o.width / 2)
            let color = o.kind == "window" ? "#4aa3df" : "#b07a45"
            s += "<line x1=\"\(X(p1.x))\" y1=\"\(Y(p1.y))\" x2=\"\(X(p2.x))\" y2=\"\(Y(p2.y))\" stroke=\"\(color)\" stroke-width=\"9\" stroke-linecap=\"butt\"/>"
        }
        return s + "</svg>"
    }

    // MARK: Страница

    static func page(_ r: RoomResult, look: Look, extra: Extra) -> String {
        let brand = Brand.current
        let date = Date().formatted(date: .long, time: .omitted)
        let m2 = { (v: Double) in String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
        var body = ""
        body += "<header><div><div class=\"kicker\">\(esc(brand.name.isEmpty ? "Ремонт" : brand.name))</div><h1>\(esc(r.room))</h1>"
        let who = [extra.client, extra.address].filter { !$0.isEmpty }.map(esc).joined(separator: " · ")
        if !who.isEmpty { body += "<div class=\"who\">\(who)</div>" }
        body += "</div><div class=\"date\">\(esc(date))"
        if !brand.phone.isEmpty { body += "<br><a href=\"tel:\(esc(brand.phone))\">\(esc(brand.phone))</a>" }
        body += "</div></header>"

        body += "<section class=\"stats\">"
        for (t, v) in [("Пол", "\(m2(r.floorArea)) м²"), ("Стены", "\(m2(r.wallArea)) м²"), ("Периметр", "\(m2(r.perimeter)) м"),
                       ("Потолок", "\(String(format: "%.2f", r.height).replacingOccurrences(of: ".", with: ",")) м")] {
            body += "<div><span>\(t)</span><b>\(v)</b></div>"
        }
        body += "</section>"

        body += """
        <section class="card"><h2>Комната в 3D</h2>
        <div id="v3d"><canvas id="cv"></canvas>
        <div class="tools"><button data-a="left">⟲</button><button data-a="top">Сверху</button><button data-a="right">⟳</button></div>
        <noscript><p class="muted">3D открывается в браузере: Chrome, Safari, Яндекс. План и смета — ниже.</p></noscript></div>
        <p class="muted">Крутите пальцем или мышью, приближайте двумя пальцами или колесом.</p></section>
        """

        body += "<section class=\"card\"><h2>План с размерами</h2>\(planSVG(r))<p class=\"muted\">Длины стен в метрах. Синие — окна, коричневые — двери.</p></section>"

        if let photo = r.photo.flatMap(UIImage.init(data:)), let src = dataURL(photo, side: 1400) {
            body += "<section class=\"card\"><h2>Фото комнаты</h2><img class=\"photo\" src=\"\(src)\" alt=\"\"></section>"
        }

        if extra.withEstimate {
            let rows = Estimate.rows(for: r).filter { Estimate.isOn($0) }
            if !rows.isEmpty {
                var total = 0.0
                body += "<section class=\"card\"><h2>Смета</h2><table>"
                for sec in Estimate.Section.allCases {
                    let list = rows.filter { $0.section == sec }
                    guard !list.isEmpty else { continue }
                    body += "<tr class=\"sec\"><td colspan=\"3\">\(sec.rawValue)</td></tr>"
                    for row in list {
                        let price = Estimate.price(row)
                        let cost = Estimate.cost(row, price)
                        total += cost
                        body += "<tr><td>\(esc(row.title))</td><td class=\"n\">\(Estimate.qty(row.qty, row.unit)) \(esc(row.unit)) × \(Estimate.money(price))</td>"
                        body += "<td class=\"n\"><b>\(Estimate.money(cost))</b></td></tr>"
                    }
                }
                body += "<tr class=\"total\"><td colspan=\"2\">Итого</td><td class=\"n\">\(Estimate.money(total))</td></tr></table>"
                body += "<p class=\"muted\">Объёмы — по размерам из скана лидаром iPhone. Цены — ориентировочные, итог уточняется после замера.</p></section>"
            }
        }

        if let f = extra.finishing, !f.isEmpty {
            let lines = f.components(separatedBy: "\n").dropFirst().map { l -> String in
                let t = esc(l)
                if l.hasPrefix("  http") {
                    let u = l.trimmingCharacters(in: .whitespaces)
                    return "<li class=\"link\"><a href=\"\(esc(u))\">\(esc(u))</a></li>"
                }
                return "<li>\(t.hasPrefix("• ") ? String(t.dropFirst(2)) : t)</li>"
            }
            body += "<section class=\"card\"><h2>Отделка и что купить</h2><ul>\(lines.joined())</ul></section>"
        }

        if extra.withDefects && !r.defects.isEmpty {
            body += "<section class=\"card\"><h2>Дефекты и заметки</h2><ol class=\"defects\">"
            for d in r.defects {
                let place = d.wall.map { "стена \($0 + 1), \(Int((d.height * 100).rounded())) см от пола" } ?? (d.height < 0.1 ? "на полу" : "потолок")
                body += "<li><b>\(esc(d.title))</b>\(d.fixed ? " <span class=\"ok\">исправлено</span>" : "") <span class=\"muted\">· \(place)</span>"
                if !d.note.isEmpty { body += "<div>\(esc(d.note))</div>" }
                if d.hasPhoto, let img = extra.defectPhoto(d.id), let src = dataURL(img, side: 700) {
                    body += "<img src=\"\(src)\" alt=\"\">"
                }
                body += "</li>"
            }
            body += "</ol></section>"
        }
        body += "<footer>Сделано в СтройСкан · размеры сняты лидаром iPhone, точность ±1–2 см</footer>"

        return """
        <!doctype html>
        <html lang="ru"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(r.room)) — ремонт</title>
        <style>\(css)</style></head>
        <body><main>\(body)</main>
        <script>const SCENE = \(sceneJSON(r, look: look));</script>
        <script>\(js)</script>
        </body></html>
        """
    }

    private static let css = """
    :root{--ink:#14202e;--sig:#f5c518;--draft:#3d6fae;--bg:#f3f5f8;--card:#fff;--muted:#6b7684}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
    main{max-width:820px;margin:0 auto;padding:0 16px 40px}
    header{display:flex;justify-content:space-between;gap:16px;align-items:flex-end;background:var(--ink);color:#fff;margin:0 -16px 16px;padding:28px 20px 22px;border-bottom:4px solid var(--sig)}
    header h1{margin:4px 0 0;font-size:30px;line-height:1.1}.kicker{color:var(--sig);font-weight:800;letter-spacing:.08em;text-transform:uppercase;font-size:12px}
    .who{opacity:.8;margin-top:6px}.date{text-align:right;opacity:.75;font-size:13px}.date a{color:#fff}
    .stats{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:14px}
    .stats div{background:var(--card);border-radius:14px;padding:10px 12px}.stats span{display:block;color:var(--muted);font-size:12px}.stats b{font-size:18px}
    .card{background:var(--card);border-radius:20px;padding:16px;margin-bottom:14px}.card h2{margin:0 0 10px;font-size:20px}
    #v3d{position:relative;height:min(70vw,460px);min-height:280px;background:linear-gradient(#dfe5ec,#c9d1db);border-radius:14px;overflow:hidden;touch-action:none}
    #cv{width:100%;height:100%;display:block;cursor:grab}
    .tools{position:absolute;right:10px;bottom:10px;display:flex;gap:6px}
    .tools button{border:0;background:rgba(20,32,46,.85);color:#fff;font-weight:700;border-radius:10px;padding:8px 12px;font-size:15px}
    .plan{width:100%;height:auto;max-height:520px}.photo{width:100%;border-radius:14px}
    table{width:100%;border-collapse:collapse;font-size:14px}td{padding:7px 4px;border-bottom:1px solid #e7ebf0;vertical-align:top}
    td.n{text-align:right;white-space:nowrap}tr.sec td{font-weight:800;padding-top:14px;color:var(--draft)}
    tr.total td{font-size:18px;font-weight:800;border:0;padding-top:12px}
    ul,ol{padding-left:20px;margin:0}li{margin-bottom:8px}li.link{list-style:none;font-size:13px;word-break:break-all}
    .defects img{display:block;max-width:100%;max-height:260px;border-radius:10px;margin-top:6px}
    .muted{color:var(--muted);font-size:13px}.ok{color:#1f9d55;font-weight:700}
    footer{text-align:center;color:var(--muted);font-size:12px;margin-top:20px}
    @media (max-width:560px){.stats{grid-template-columns:repeat(2,1fr)}header h1{font-size:24px}}
    """

    /// 3D на обычном canvas: пол, дальние стены с окнами и дверями, мебель коробками. Ближние стены срезаны, как в кукольном домике
    private static let js = """
    (function(){
    const S=SCENE,cv=document.getElementById('cv');if(!cv||!S.poly||S.poly.length<3)return;
    const ctx=cv.getContext('2d');const H=S.h;
    let cx=0,cz=0;S.poly.forEach(p=>{cx+=p[0];cz+=p[1]});cx/=S.poly.length;cz/=S.poly.length;
    let span=1;S.poly.forEach(p=>{span=Math.max(span,Math.hypot(p[0]-cx,p[1]-cz))});
    let yaw=0.7,pitch=0.75,dist=span*3.2;
    function inside(x,z){let c=false;const p=S.poly;for(let i=0,j=p.length-1;i<p.length;j=i++){const a=p[i],b=p[j];if((a[1]>z)!==(b[1]>z)&&x<(b[0]-a[0])*(z-a[1])/(b[1]-a[1])+a[0])c=!c}return c}
    function hex(h){h=(h||'#cccccc').replace('#','');if(h.length===3)h=h.split('').map(c=>c+c).join('');const n=parseInt(h,16);return[(n>>16)&255,(n>>8)&255,n&255]}
    function shade(rgb,k){return 'rgb('+rgb.map(v=>Math.max(0,Math.min(255,Math.round(v*k)))).join(',')+')'}
    const L=(()=>{const v=[0.4,0.85,0.35],n=Math.hypot(...v);return v.map(x=>x/n)})();
    let W=0,Hh=0,f=1,cam,fw,rt,up;
    function sub(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]]}function dot(a,b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]}
    function cross(a,b){return[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]}function nrm(a){const l=Math.hypot(...a)||1;return a.map(x=>x/l)}
    function setup(){const r=cv.getBoundingClientRect(),d=window.devicePixelRatio||1;W=r.width;Hh=r.height;cv.width=W*d;cv.height=Hh*d;ctx.setTransform(d,0,0,d,0,0);
     const c=[cx,H*0.35,cz];cam=[cx+dist*Math.cos(pitch)*Math.sin(yaw),H*0.35+dist*Math.sin(pitch),cz+dist*Math.cos(pitch)*Math.cos(yaw)];
     fw=nrm(sub(c,cam));rt=nrm(cross(fw,[0,1,0]));up=cross(rt,fw);f=Math.min(W,Hh)*1.45}
    function P(p){const v=sub(p,cam);const z=Math.max(0.05,dot(v,fw));return[W/2+dot(v,rt)*f/z,Hh/2-dot(v,up)*f/z,z]}
    const polys=[];
    function quad(pts,rgb,n,p){polys.push({pts,rgb,n,p})}
    function build(){polys.length=0;const camXZ=[cam[0],cam[2]];
     S.walls.forEach((w,i)=>{const a=[w[0],w[1]],b=[w[2],w[3]];const len=Math.hypot(b[0]-a[0],b[1]-a[1]);if(len<0.05)return;
      let n=[-(b[1]-a[1])/len,(b[0]-a[0])/len];const m=[(a[0]+b[0])/2,(a[1]+b[1])/2];if(!inside(m[0]+n[0]*0.08,m[1]+n[1]*0.08))n=[-n[0],-n[1]];
      const back=(camXZ[0]-m[0])*n[0]+(camXZ[1]-m[1])*n[1]>0;const top=back?H:0.12;
      const col=hex(S.accent&&S.accent.wall===i?S.accent.color:S.wall);
      quad([[a[0],0,a[1]],[b[0],0,b[1]],[b[0],top,b[1]],[a[0],top,a[1]]],col,[n[0],0,n[1]]);
      if(!back)return;
      S.openings.filter(o=>o.wall===i).forEach(o=>{const u=[(b[0]-a[0])/len,(b[1]-a[1])/len];const e=0.012;
       const p1=[o.x-u[0]*o.w/2+n[0]*e,o.y-u[1]*o.w/2+n[1]*e],p2=[o.x+u[0]*o.w/2+n[0]*e,o.y+u[1]*o.w/2+n[1]*e];const y0=o.b,y1=Math.min(H,o.b+o.h);
       quad([[p1[0],y0,p1[1]],[p2[0],y0,p2[1]],[p2[0],y1,p2[1]],[p1[0],y1,p1[1]]],o.kind==='window'?[150,200,235]:[150,105,70],[n[0],0,n[1]],1)});
     });
     S.boxes.forEach(bx=>{const c=Math.cos(bx.a),s=Math.sin(bx.a);const ux=[c,s],uz=[-s,c];const hw=bx.w/2,hd=bx.d/2,y0=bx.b,y1=bx.b+bx.h;
      const k=[[1,1],[-1,1],[-1,-1],[1,-1]].map(([i,j])=>[bx.x+ux[0]*hw*i+uz[0]*hd*j,bx.y+ux[1]*hw*i+uz[1]*hd*j]);const col=hex(bx.c);
      quad(k.map(p=>[p[0],y1,p[1]]),col,[0,1,0]);
      for(let i=0;i<4;i++){const p=k[i],q=k[(i+1)%4];const mx=(p[0]+q[0])/2-bx.x,mz=(p[1]+q[1])/2-bx.y;const l=Math.hypot(mx,mz)||1;
       quad([[p[0],y0,p[1]],[q[0],y0,q[1]],[q[0],y1,q[1]],[p[0],y1,p[1]]],col,[mx/l,0,mz/l])}
     });}
    function draw(){setup();build();ctx.clearRect(0,0,W,Hh);
     const fl=hex(S.floor);ctx.beginPath();S.poly.forEach((p,i)=>{const q=P([p[0],0,p[1]]);i?ctx.lineTo(q[0],q[1]):ctx.moveTo(q[0],q[1])});ctx.closePath();
     ctx.fillStyle=shade(fl,0.95);ctx.fill();ctx.strokeStyle='rgba(20,32,46,.35)';ctx.lineWidth=1;ctx.stroke();
     const list=polys.map(p=>{const pr=p.pts.map(P);const c=p.pts.reduce((s,v)=>[s[0]+v[0],s[1]+v[1],s[2]+v[2]],[0,0,0]).map(v=>v/p.pts.length);
       const toCam=sub(cam,c);return{p,pr,z:Math.hypot(...toCam),face:dot(p.n,toCam)>0}}).filter(o=>o.face);
     list.forEach(o=>{if(o.p.p)o.z-=0.02});list.sort((a,b)=>b.z-a.z);
     list.forEach(o=>{const k=0.8+0.25*Math.max(0,dot(o.p.n,L));ctx.beginPath();o.pr.forEach((q,i)=>i?ctx.lineTo(q[0],q[1]):ctx.moveTo(q[0],q[1]));ctx.closePath();
      ctx.fillStyle=shade(o.p.rgb,k);ctx.fill();ctx.strokeStyle='rgba(20,32,46,.25)';ctx.stroke()});}
    let drag=null,pinch=null;const pts=new Map();
    cv.addEventListener('pointerdown',e=>{cv.setPointerCapture(e.pointerId);pts.set(e.pointerId,[e.clientX,e.clientY]);drag=[e.clientX,e.clientY,yaw,pitch];
     if(pts.size===2){const v=[...pts.values()];pinch=[Math.hypot(v[0][0]-v[1][0],v[0][1]-v[1][1]),dist]}});
    cv.addEventListener('pointermove',e=>{if(!pts.has(e.pointerId))return;pts.set(e.pointerId,[e.clientX,e.clientY]);
     if(pts.size===2&&pinch){const v=[...pts.values()];const d=Math.hypot(v[0][0]-v[1][0],v[0][1]-v[1][1]);dist=Math.max(span*1.2,Math.min(span*8,pinch[1]*pinch[0]/Math.max(d,1)));draw();return}
     if(drag){yaw=drag[2]-(e.clientX-drag[0])*0.008;pitch=Math.max(0.15,Math.min(1.5,drag[3]+(e.clientY-drag[1])*0.006));draw()}});
    const end=e=>{pts.delete(e.pointerId);if(pts.size<2)pinch=null;if(!pts.size)drag=null};
    cv.addEventListener('pointerup',end);cv.addEventListener('pointercancel',end);
    cv.addEventListener('wheel',e=>{e.preventDefault();dist=Math.max(span*1.2,Math.min(span*8,dist*(1+e.deltaY*0.001)));draw()},{passive:false});
    document.querySelectorAll('.tools button').forEach(b=>b.addEventListener('click',()=>{const a=b.dataset.a;
     if(a==='left')yaw+=Math.PI/2;if(a==='right')yaw-=Math.PI/2;if(a==='top')pitch=pitch>1.3?0.75:1.5;draw()}));
    window.addEventListener('resize',draw);draw();
    })();
    """
}
