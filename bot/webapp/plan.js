/* План комнаты по скану: контур пола и с какой стороны от каждой стены комната.
   Общий для плана на странице скана и для 3D (room3d.js). Координаты — как в скане, метры.
   План из скана не всегда годится: на iOS 16 (и когда RoomPlan не нашёл пол) это выпуклая оболочка концов стен,
   и в Г-образной комнате она накрывает выемку. Поэтому контур собираем обходом самих стен. */

export function inPoly(poly, x, y) {
  let res = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [x1, y1] = poly[i], [x2, y2] = poly[j];
    if ((y1 > y) !== (y2 > y) && x < (x2 - x1) * (y - y1) / (y2 - y1) + x1) res = !res;
  }
  return res;
}
const dist = (p, q) => Math.hypot(p[0] - q[0], p[1] - q[1]);
function toSeg([px, py], [x1, y1, x2, y2]) {   // от точки до отрезка
  const dx = x2 - x1, dy = y2 - y1, t = Math.max(0, Math.min(1, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy || 1)));
  return Math.hypot(px - x1 - dx * t, py - y1 - dy * t);
}
function crossings([px, py], dx, dy, segs) {   // сколько стен пересекает луч из точки
  let n = 0;
  for (const [x1, y1, x2, y2] of segs) {
    const ex = x2 - x1, ey = y2 - y1, den = dx * ey - dy * ex;
    if (Math.abs(den) < 1e-12) continue;
    const wx = x1 - px, wy = y1 - py, t = (wx * ey - wy * ex) / den, s = (wx * dy - wy * dx) / den;
    if (t > 1e-9 && s >= 0 && s < 1) n++;
  }
  return n;
}
const RAYS = [0.37, 1.61, 2.83, 4.07, 5.29];   // пять сторон: один луч может проскочить в щель угла

function hit(A, B) {   // где отрезки пересекаются
  const [x1, y1, x2, y2] = A, [x3, y3, x4, y4] = B, ax = x2 - x1, ay = y2 - y1, bx = x4 - x3, by = y4 - y3, d = ax * by - ay * bx;
  if (Math.abs(d) < 1e-9) return null;
  const t = ((x3 - x1) * by - (y3 - y1) * bx) / d, u = ((x3 - x1) * ay - (y3 - y1) * ax) / d;
  return t >= 0 && t <= 1 && u >= 0 && u <= 1 ? [x1 + ax * t, y1 + ay * t] : null;
}
// щели между стенами (недоснятый угол): свободные концы ближе 1,5 м соединяем короткой стеной без номера.
// Конец, который чуть заехал за соседнюю стену (перехлёст в углу), — не щель
function gapWalls(segs) {
  const ends = [], fill = [], used = new Set();
  const over = (i, p) => segs.some((m, j) => { const X = j !== i && hit(segs[i], m); return X && dist(X, p) < 0.3; });
  segs.forEach((l, i) => [[l[0], l[1]], [l[2], l[3]]].forEach(p => { if (segs.every((m, j) => j === i || toSeg(p, m) > 0.05) && !over(i, p)) ends.push({ p, i }); }));
  for (const a of ends) {
    if (used.has(a)) continue;
    let best = null;
    for (const b of ends) if (b.i !== a.i && !used.has(b) && dist(a.p, b.p) < 1.5 && (!best || dist(a.p, b.p) < dist(a.p, best.p))) best = b;
    if (best) { used.add(a); used.add(best); fill.push([...a.p, ...best.p]); }
  }
  return fill;
}
function meet(A, B) {   // где сходятся продолжения двух стен; почти параллельные — нигде
  const [x1, y1, x2, y2] = A, [x3, y3, x4, y4] = B, ax = x2 - x1, ay = y2 - y1, bx = x4 - x3, by = y4 - y3;
  const d = ax * by - ay * bx;
  if (Math.abs(d) < 0.17 * Math.hypot(ax, ay) * Math.hypot(bx, by)) return null;
  const t = ((x3 - x1) * by - (y3 - y1) * bx) / d;
  return [x1 + ax * t, y1 + ay * t];
}
function simple(P) {   // контур не пересекает сам себя
  const o = (p, q, r) => Math.sign((q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]));
  const n = P.length;
  for (let i = 0; i < n; i++) for (let j = i + 2; j < n; j++) {
    if (i === 0 && j === n - 1) continue;
    const a = P[i], b = P[(i + 1) % n], c = P[j], d = P[(j + 1) % n];
    if (o(a, b, c) * o(a, b, d) < 0 && o(c, d, a) * o(c, d, b) < 0) return false;
  }
  return true;
}
// обход: из конца стены — в ближний конец соседней (взаимно, до 1,5 м). Один разрыв (стены нет совсем) замыкаем прямой.
// Ответ: контур, заплатки щелей в углах и для каждой стены — комната ли слева от неё (если идти от начала к концу)
function chain(segs) {
  const n = segs.length;
  if (n < 3) return null;
  const end = i => i & 1 ? [segs[i >> 1][2], segs[i >> 1][3]] : [segs[i >> 1][0], segs[i >> 1][1]];
  const near = [];
  for (let i = 0; i < 2 * n; i++) {
    let best = -1, bd = 1.5;
    for (let j = 0; j < 2 * n; j++) if (j >> 1 !== i >> 1) { const d = dist(end(i), end(j)); if (d < bd) { bd = d; best = j; } }
    near.push(best);
  }
  const mate = i => near[i] >= 0 && near[near[i]] === i ? near[i] : -1;
  const loose = [];
  for (let i = 0; i < 2 * n; i++) if (mate(i) < 0) loose.push(i);
  if (loose.length && loose.length !== 2) return null;
  const first = loose.length ? loose[0] : 0, order = [];   // [стена, вошли с конца]
  for (let i = first; ;) {
    order.push([i >> 1, i & 1]);
    const j = mate(i ^ 1);
    if (j < 0 || j === first) break;
    if (order.length >= n) return null;
    i = j;
  }
  if (order.length !== n) return null;
  const run = ([k, r]) => r ? [segs[k][2], segs[k][3], segs[k][0], segs[k][1]] : segs[k];   // стена по ходу обхода
  const poly = [], fill = [];
  for (let s = 0; s < n; s++) {
    const A = run(order[s]), B = run(order[(s + 1) % n]), a = [A[2], A[3]], b = [B[0], B[1]], gap = loose.length && s === n - 1;
    const X = gap ? null : meet(A, B);
    if (X && dist(X, a) < 0.6 && dist(X, b) < 0.6) poly.push(X);
    else if (dist(a, b) < 0.02) poly.push(a);
    else poly.push(a, b);
    // стены не сошлись (недоснятый угол) и не перехлестнулись — щель закрываем короткой стеной без номера
    if (!gap && !hit(A, B) && toSeg(a, B) > 0.05 && toSeg(b, A) > 0.05) fill.push([...a, ...b]);
  }
  let area = 0;
  poly.forEach(([x1, y1], k) => { const [x2, y2] = poly[(k + 1) % poly.length]; area += x1 * y2 - x2 * y1; });
  if (Math.abs(area) < 1 || !simple(poly)) return null;
  const left = [];
  for (const [k, r] of order) left[k] = (area > 0) !== !!r;
  fill.forEach(() => left.push(area > 0));   // заплатки идут по ходу обхода
  return { poly, fill, left };
}

// контур пола, стены (из скана и заплатки щелей), с какой стороны от стены комната, центр и границы
export function outlineOf(scan) {
  const s = scan.sizes || {}, lines = scan.wall_lines || [], walls = scan.walls || [];
  const exact = lines.length > 0 && lines.length === walls.length;
  let plan = (scan.plan || []).filter(p => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1])).map(p => [+p[0], +p[1]]);
  if (plan.length < 3) {
    if (exact && lines.length > 2) plan = lines.map(l => [+l[0], +l[1]]);
    else {
      const L = s.length || Math.sqrt(s.floor_area || 12), W = s.width || (s.floor_area || L * L) / L;
      plan = [[0, 0], [L, 0], [L, W], [0, W]];
    }
  }
  const segs = exact ? lines.map(l => l.map(Number)) : plan.map((p, i) => [...p, ...plan[(i + 1) % plan.length]]);
  const ch = exact ? chain(segs) : null, poly = ch ? ch.poly : plan;
  const fill = ch ? ch.fill : exact ? gapWalls(segs) : [], all = segs.concat(fill);
  const xs = poly.map(p => p[0]).concat(all.flatMap(l => [l[0], l[2]])), ys = poly.map(p => p[1]).concat(all.flatMap(l => [l[1], l[3]]));
  const box = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
  // центр тяжести; если он вне комнаты (узкая Г) — самая далёкая от стен точка внутри
  let A = 0, cx = 0, cy = 0;
  poly.forEach(([x1, y1], i) => { const [x2, y2] = poly[(i + 1) % poly.length], c = x1 * y2 - x2 * y1; A += c; cx += (x1 + x2) * c; cy += (y1 + y2) * c; });
  let center = Math.abs(A) > 1e-6 ? [cx / (3 * A), cy / (3 * A)] : [(box[0] + box[2]) / 2, (box[1] + box[3]) / 2];
  if (!inPoly(poly, ...center)) {
    let best = -1;
    const edges = poly.map((p, i) => [...p, ...poly[(i + 1) % poly.length]]);
    for (let i = 1; i < 24; i++) for (let j = 1; j < 24; j++) {
      const p = [box[0] + (box[2] - box[0]) * i / 24, box[1] + (box[3] - box[1]) * j / 24];
      if (!inPoly(poly, ...p)) continue;
      const d = Math.min(...edges.map(e => toSeg(p, e)));
      if (d > best) { best = d; center = p; }
    }
  }
  // комната слева от стены? По обходу; без него — по плану, если по нему понятно; иначе по самим стенам (чёт-нечет); иначе к центру
  const left = ch ? ch.left : all.map(([x1, y1, x2, y2]) => {
    const len = Math.hypot(x2 - x1, y2 - y1) || 1, nx = -(y2 - y1) / len, ny = (x2 - x1) / len, mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
    const a = [mx + nx * 0.1, my + ny * 0.1], b = [mx - nx * 0.1, my - ny * 0.1];
    if (inPoly(plan, ...a) !== inPoly(plan, ...b)) return inPoly(plan, ...a);
    if (exact) {
      const odd = p => RAYS.filter(t => crossings(p, Math.cos(t), Math.sin(t), all) % 2).length * 2 > RAYS.length;
      if (odd(a) !== odd(b)) return odd(a);
    }
    return (center[0] - mx) * nx + (center[1] - my) * ny > 0;
  });
  return { poly, segs, fill, exact, left, center, box };
}
