/* Ремонт в 3D по скану с iPhone: комната в точных размерах, отделка, свет и мебель.
   Страница грузит этот модуль (и three.js), только когда открыли 3D.
   Координаты — как в скане: план (x, y) в метрах, в 3D это (x, высота, y).
   Ключи ремонта (look) те же, что у бота и приложения СтройСкан (bot/look.py, Look.swift). */
import * as T from "./vendor/three-r186.min.js";
import { inPoly, outlineOf } from "./plan.js";

const PI = Math.PI;
const WALL_T = 0.12;     // стена наружу от внутренней поверхности
const EYE = 1.4;         // камера «из комнаты» — на высоте фотографа интерьеров
const CUT = 0.28;        // стены между камерой и комнатой в виде сверху срезаны до этой высоты
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const clone = o => JSON.parse(JSON.stringify(o));

// ---------- что можно выбрать (как в приложении СтройСкан) ----------
export const TITLES = {
  sofa: "Диван", bed: "Кровать", chair: "Стул", table: "Стол", storage: "Шкаф", refrigerator: "Холодильник",
  stove: "Плита", oven: "Духовка", sink: "Раковина", toilet: "Унитаз", bathtub: "Ванна", washerDryer: "Стиральная машина",
  television: "Телевизор", dishwasher: "Посудомойка", fireplace: "Камин", stairs: "Лестница", object: "Предмет",
};
export const VARIANTS = {
  sofa: [["straight", "Прямой"], ["corner", "Угловой"], ["chesterfield", "Честерфилд"], ["modular", "Модульный"]],
  bed: [["upholstered", "Мягкое изголовье"], ["platform", "Низкая"], ["classic", "Классика"]],
  chair: [["dining", "Стул"], ["armchair", "Кресло"], ["stool", "Табурет"]],
  table: [["dining_rect", "Обеденный"], ["dining_round", "Круглый"], ["coffee", "Журнальный"], ["desk", "Письменный"]],
  storage: [["wardrobe", "Шкаф"], ["dresser", "Комод"], ["shelving", "Стеллаж"], ["tv_stand", "Тумба ТВ"]],
};
export const WALL_FINISHES = [["paint", "Краска"], ["wallpaper", "Обои"], ["plaster", "Штукатурка"], ["panels", "Панели"], ["tile", "Плитка"], ["brick", "Кирпич"]];
export const PATTERNS = [["plain", "Однотонные"], ["stripes", "Полоска"], ["geometric", "Геометрия"], ["floral", "Цветы"], ["damask", "Дамаск"], ["linen", "Под лён"]];
export const FLOORS = [["laminate", "Ламинат"], ["parquet", "Паркет ёлочкой"], ["tile", "Плитка"], ["stone", "Под камень"], ["carpet", "Ковролин"], ["concrete", "Микроцемент"]];
export const LIGHTS = [["chandelier_classic", "Люстра классика"], ["chandelier_modern", "Люстра современная"], ["pendant", "Подвесы"],
  ["spots", "Споты"], ["track", "Трек"], ["ring", "Кольцо"], ["none", "Без люстры"]];
export const CURTAINS = [["curtains", "Шторы с тюлем"], ["blinds", "Жалюзи"], ["roman", "Римские"], ["none", "Без штор"]];
export const COLORS = {
  wall: ["#f4f1ea", "#e9e4da", "#dcd3c4", "#c9c2b6", "#b8bfb4", "#a7b6c2", "#e3c9b8", "#7c8b7a", "#4a5a6a", "#8e4a36", "#3a3b3d"],
  fabric: ["#ece8e1", "#cfc6b6", "#a9a195", "#8c8c88", "#5b5f66", "#2f3a4a", "#4f6250", "#8a5a44", "#c49a5a", "#7a2e35", "#1f1f21"],
  wood: ["#f2f0eb", "#e3cba4", "#d9be96", "#b08d68", "#8a6546", "#6e4a2e", "#4e3526", "#2b211c", "#1e1e1f"],
  floor: ["#e2cfaf", "#d0b38c", "#b8946e", "#a07a55", "#7a5234", "#4e3526", "#c9c6bf", "#8e8c88", "#edeae4", "#3a3a3c"],
  appliance: ["#f4f4f2", "#d6d7d9", "#8e9094", "#2b2c2e", "#e8dcc6"],
  ceramic: ["#f7f7f5", "#eceae4", "#d9d6cf", "#2b2c2e"],
  ceiling: ["#ffffff", "#f4f1ea", "#e9e4da", "#d5d3cf", "#3a3b3d"],
};
// что можно добавить: вид, вариант, подпись
export const ADDABLE = [
  ["sofa", "straight", "Диван"], ["sofa", "corner", "Угловой диван"], ["chair", "armchair", "Кресло"], ["chair", "dining", "Стул"],
  ["bed", "upholstered", "Кровать"], ["table", "dining_rect", "Обеденный стол"], ["table", "dining_round", "Круглый стол"],
  ["table", "coffee", "Журнальный столик"], ["table", "desk", "Письменный стол"], ["storage", "wardrobe", "Шкаф"],
  ["storage", "dresser", "Комод"], ["storage", "shelving", "Стеллаж"], ["storage", "tv_stand", "Тумба под ТВ"],
  ["television", "default", "Телевизор"], ["refrigerator", "default", "Холодильник"], ["stove", "default", "Плита"],
  ["sink", "default", "Раковина"], ["dishwasher", "default", "Посудомойка"], ["washerDryer", "default", "Стиральная машина"],
  ["toilet", "default", "Унитаз"], ["bathtub", "default", "Ванна"], ["fireplace", "default", "Камин"],
];
export const MAX_ADDED = 30;

// стиль → отделка по умолчанию и цвета мебели (как RenoStyle в приложении)
export const STYLES = {
  scandi: { wall: ["paint", "#f2efe9"], floor: ["laminate", "#d0b38c"], ceiling: ["pendant", "#ffffff"], curtains: "curtains",
    pal: { fabric: "#bfb8ac", wood: "#d9be96", metal: "#1f1f21", accent: "#c9a66b", appliance: "#f2f2f0", trim: "#f7f7f5",
      door: "#f4f2ee", bedding: "#f5f2ed", curtain: "#efebe3", leather: false } },
  loft: { wall: ["brick", "#8e4a36"], floor: ["concrete", "#8e8c88"], ceiling: ["track", "#dad8d4"], curtains: "blinds",
    pal: { fabric: "#6b4a35", wood: "#5a3e2b", metal: "#141417", accent: "#2e3a4a", appliance: "#3a3b3d", trim: "#1f1f21",
      door: "#3b2f28", bedding: "#dbd9d4", curtain: "#9a968f", leather: true } },
  modern: { wall: ["paint", "#e4e0da"], floor: ["parquet", "#a98260"], ceiling: ["spots", "#ffffff"], curtains: "curtains",
    pal: { fabric: "#8c8c88", wood: "#8a6546", metal: "#1a1a1c", accent: "#4f6250", appliance: "#dadbdd", trim: "#fafafa",
      door: "#edebe7", bedding: "#f7f7f5", curtain: "#9a968f", leather: false } },
  classic: { wall: ["wallpaper", "#e6d9c2", "damask"], floor: ["parquet", "#7a5234"], ceiling: ["chandelier_classic", "#ffffff"], curtains: "curtains",
    pal: { fabric: "#d9cbb0", wood: "#6e4a2e", metal: "#c79e54", accent: "#2f4f3e", appliance: "#eeeae2", trim: "#faf7f0",
      door: "#f2eee6", bedding: "#f7f2e6", curtain: "#c9b48a", leather: false } },
  japandi: { wall: ["plaster", "#d9d0c1"], floor: ["laminate", "#b8946e"], ceiling: ["pendant", "#f4f1ea"], curtains: "roman",
    pal: { fabric: "#cfc6b6", wood: "#b08d68", metal: "#1a1a1a", accent: "#6f7f63", appliance: "#3a3936", trim: "#735c45",
      door: "#b08d68", bedding: "#e8e0d4", curtain: "#d8cdbb", leather: false } },
  budget: { wall: ["wallpaper", "#ede8df", "linen"], floor: ["laminate", "#c4a480"], ceiling: ["chandelier_modern", "#ffffff"], curtains: "curtains",
    pal: { fabric: "#9a9a94", wood: "#c9a57a", metal: "#b8babf", accent: "#5b7fa6", appliance: "#f2f2f0", trim: "#f7f7f5",
      door: "#e9e4da", bedding: "#f7f7f5", curtain: "#dad3c6", leather: false } },
};

export const isSoft = (kind, v) => kind === "sofa" || kind === "bed" || (kind === "chair" && v === "armchair");
export function colorsFor(kind, v) {
  if (isSoft(kind, v)) return COLORS.fabric;
  if (["table", "storage", "chair", "stairs"].includes(kind)) return COLORS.wood;
  if (["sink", "toilet", "bathtub", "fireplace"].includes(kind)) return COLORS.ceramic;
  return COLORS.appliance;
}
export function defaultColor(kind, v, pal) {
  if (isSoft(kind, v)) return pal.fabric;
  if (["table", "storage", "chair", "stairs"].includes(kind)) return pal.wood;
  if (kind === "television") return "#2b2c2e";
  if (["sink", "toilet", "bathtub"].includes(kind)) return "#f7f7f5";
  if (kind === "fireplace") return "#eceae4";
  return pal.appliance;
}
// вариант отсканированной мебели, пока его не меняли
export function defaultVariant(o) {
  const w = o.width || 0, d = o.depth || 0, h = o.height || 0;
  switch (o.kind) {
    case "sofa": return d > 1.3 && w > 1.8 ? "corner" : "straight";
    case "bed": return "upholstered";
    case "chair": return w > 0.66 ? "armchair" : h < 0.62 ? "stool" : "dining";
    case "table": return h && h < 0.56 ? "coffee" : "dining_rect";
    case "storage": if (h > 1.35) return d < 0.45 ? "shelving" : "wardrobe"; return h < 0.62 && w > 1 ? "tv_stand" : "dresser";
    default: return "default";
  }
}
// обычный размер новой мебели: ширина, глубина, высота
export function sizeOf(kind, v) {
  const S = {
    "sofa corner": [2.6, 1.65, 0.85], "sofa chesterfield": [2.2, 0.95, 0.76], "sofa modular": [2.8, 1.05, 0.72], sofa: [2.1, 0.95, 0.85],
    "bed platform": [1.7, 2.15, 0.75], "bed classic": [1.7, 2.15, 1.15], bed: [1.8, 2.2, 1.15],
    "chair armchair": [0.8, 0.85, 0.85], "chair stool": [0.4, 0.4, 0.65], chair: [0.46, 0.52, 0.86],
    "table dining_round": [1.1, 1.1, 0.75], "table coffee": [1.1, 0.6, 0.42], "table desk": [1.2, 0.6, 0.75], table: [1.6, 0.9, 0.75],
    "storage dresser": [1.2, 0.45, 0.85], "storage shelving": [0.9, 0.35, 1.9], "storage tv_stand": [1.8, 0.42, 0.5], storage: [1.6, 0.6, 2.3],
    television: [1.23, 0.08, 0.72], refrigerator: [0.6, 0.66, 1.9], stove: [0.6, 0.6, 0.85], sink: [0.8, 0.48, 0.85],
    dishwasher: [0.6, 0.57, 0.82], washerDryer: [0.6, 0.55, 0.85], toilet: [0.38, 0.66, 0.78], bathtub: [1.7, 0.75, 0.58], fireplace: [1.2, 0.4, 1.1],
  };
  return S[`${kind} ${v}`] || S[kind] || [0.8, 0.5, 0.8];
}
// что ставят спиной к стене
export const againstWall = (kind, v) => ["sofa", "bed", "storage", "television", "refrigerator", "stove", "sink", "dishwasher",
  "washerDryer", "toilet", "bathtub", "fireplace"].includes(kind) || (kind === "table" && v === "desk");

// ---------- ремонт (look): недостающее — из стиля ----------
const HEX = /^#[0-9a-f]{6}$/i;
const hex = v => typeof v === "string" && HEX.test(v) ? v.toLowerCase() : null;
const oneOf = (v, list, d) => list.some(x => x[0] === v) ? v : d;
const num = v => typeof v === "number" && isFinite(v) ? v : null;

export function resolveLook(raw) {
  const r = raw && typeof raw === "object" ? raw : {};
  const style = STYLES[r.style] ? r.style : "scandi", s = STYLES[style];
  const surf = (p, base) => ({ finish: oneOf(p?.finish, WALL_FINISHES, base.finish), color: hex(p?.color) || base.color,
    pattern: oneOf(p?.pattern, PATTERNS, base.pattern || "plain") });
  const wall = surf(r.wall, { finish: s.wall[0], color: s.wall[1], pattern: s.wall[2] || "plain" });
  const look = {
    style, wall, accent: null,
    floor: { finish: oneOf(r.floor?.finish, FLOORS, s.floor[0]), color: hex(r.floor?.color) || s.floor[1] },
    ceiling: { light: oneOf(r.ceiling?.light, LIGHTS, s.ceiling[0]), color: hex(r.ceiling?.color) || s.ceiling[1] },
    curtains: oneOf(r.curtains, CURTAINS, s.curtains), objects: {}, added: [],
  };
  if (r.accent && Number.isInteger(r.accent.wall) && r.accent.wall >= 0) look.accent = { wall: r.accent.wall, ...surf(r.accent, wall) };
  for (const [k, v] of Object.entries(r.objects && typeof r.objects === "object" ? r.objects : {})) {
    if (!/^\d{1,3}$/.test(k) || !v || typeof v !== "object") continue;
    const o = {};
    if (typeof v.variant === "string") o.variant = v.variant;
    if (hex(v.color)) o.color = hex(v.color);
    if (v.hidden === true) o.hidden = true;
    if (Object.keys(o).length) look.objects[k] = o;
  }
  for (const a of Array.isArray(r.added) ? r.added.slice(0, MAX_ADDED) : []) {
    if (!a || !TITLES[a.kind] || [a.width, a.depth, a.height, a.x, a.y].some(v => num(v) === null)) continue;
    const vs = VARIANTS[a.kind];
    const variant = vs ? oneOf(a.variant, vs, vs[0][0]) : "default";
    look.added.push({ kind: a.kind, variant, color: hex(a.color) || defaultColor(a.kind, variant, s.pal),
      width: a.width, depth: a.depth, height: a.height, x: a.x, y: a.y, angle: num(a.angle) || 0 });
  }
  return look;
}
// новый стиль: отделка и свет из стиля; выбранные варианты и расстановка остаются, цвета — из стиля
export function withStyle(look, key) {
  const s = STYLES[key] || STYLES.scandi;
  const objects = {};
  for (const [k, o] of Object.entries(look.objects || {})) {
    const n = { ...o }; delete n.color;
    if (Object.keys(n).length) objects[k] = n;
  }
  return resolveLook({ style: key, objects,
    added: (look.added || []).map(a => ({ ...a, color: defaultColor(a.kind, a.variant, s.pal) })) });
}
// ремонт → JSON для бота (без пустого, числа до миллиметра)
export function toContract(look) {
  const r = v => Math.round(v * 1000) / 1000;
  const out = { style: look.style, wall: { ...look.wall }, floor: { ...look.floor }, ceiling: { ...look.ceiling }, curtains: look.curtains };
  if (look.accent) out.accent = { ...look.accent };
  const objs = Object.entries(look.objects || {}).filter(([, o]) => Object.keys(o).length);
  if (objs.length) out.objects = Object.fromEntries(objs);
  if (look.added?.length) out.added = look.added.map(a => ({ kind: a.kind, variant: a.variant, color: a.color,
    width: r(a.width), depth: r(a.depth), height: r(a.height), x: r(a.x), y: r(a.y), angle: Math.round(a.angle * 1e4) / 1e4 }));
  return out;
}

// ---------- плоская геометрия ----------
function corners(x, y, w, d, a) {
  const ux = Math.cos(a), uy = Math.sin(a), vx = -uy, vy = ux;
  return [[-1, -1], [1, -1], [1, 1], [-1, 1]].map(([p, q]) => [x + ux * p * w / 2 + vx * q * d / 2, y + uy * p * w / 2 + vy * q * d / 2]);
}
function overlap(A, B, shrink = 0.02) {   // пересекаются ли прямоугольники (касание — нет)
  for (const P of [A, B]) for (let i = 0; i < 2; i++) {
    const ex = P[i + 1][0] - P[i][0], ey = P[i + 1][1] - P[i][1], l = Math.hypot(ex, ey) || 1, ax = ex / l, ay = ey / l;
    const pa = A.map(p => p[0] * ax + p[1] * ay), pb = B.map(p => p[0] * ax + p[1] * ay);
    if (Math.max(...pa) - shrink <= Math.min(...pb) || Math.max(...pb) - shrink <= Math.min(...pa)) return false;
  }
  return true;
}
function cast(px, py, dx, dy, segs) {   // расстояние по лучу до ближайшей стены
  let best = 50;
  for (const [x1, y1, x2, y2] of segs) {
    const ex = x2 - x1, ey = y2 - y1, den = dx * ey - dy * ex;
    if (Math.abs(den) < 1e-9) continue;
    const wx = x1 - px, wy = y1 - py, t = (wx * ey - wy * ex) / den, s = (wx * dy - wy * dx) / den;
    if (t > 1e-6 && s >= -1e-9 && s <= 1 + 1e-9) best = Math.min(best, t);
  }
  return best;
}

// комната по скану: контур пола, стены (нормаль внутрь), окна и двери на стенах
function roomOf(scan) {
  const s = scan.sizes || {}, wallsIn = scan.walls || [];
  // контур — обходом стен (plan.js): план из скана бывает выпуклой оболочкой и накрывает выемку Г-образной комнаты
  const { poly, segs, fill, exact, left, center, box } = outlineOf(scan);
  const H = clamp(s.height || Math.max(0, ...wallsIn.map(w => w.height || 0)) || 2.7, 2.1, 5);
  const walls = segs.concat(fill).map((l, n) => {
    const i = n < segs.length ? n : -1;
    let [x1, y1, x2, y2] = l;
    const len = Math.hypot(x2 - x1, y2 - y1);
    if (!(len > 0.05)) return null;
    let dx = (x2 - x1) / len, dy = (y2 - y1) / len, flip = false;
    // стену разворачиваем так, чтобы (−dy, dx) смотрело наружу: тогда сборка в 3D без зеркал
    if (left[n]) { flip = true; [x1, y1, x2, y2] = [x2, y2, x1, y1]; dx = -dx; dy = -dy; }
    return { i, a: [x1, y1], b: [x2, y2], len, dx, dy, nx: dy, ny: -dx, flip, holes: [] };
  });
  const live = walls.filter(Boolean);
  walls.length = segs.length;   // номера стен — как в скане, заплатки только в live
  // окна и двери
  const ops = (scan.openings || []).map((o, k) => {
    const kind = ["window", "door", "opening"].includes(o.kind) ? o.kind : "opening";
    return { k, kind, w: o.width || (kind === "window" ? 1.2 : 0.85), h: o.height || (kind === "window" ? 1.4 : 2.05),
      bottom: kind === "window" ? (o.bottom ?? 0.85) : 0,
      W: exact && Number.isInteger(o.wall) && walls[o.wall] ? walls[o.wall] : null, off: num(o.offset) };
  });
  ops.forEach(o => { if (o.W) o.off = o.off === null ? o.W.len / 2 : o.W.flip ? o.W.len - o.off : o.off; });
  // без привязки (старые сканы): окна — на длинные стены, двери — к углу на стены без окон
  const byLen = [...live].sort((a, b) => b.len - a.len);
  const wins = ops.filter(o => !o.W && o.kind === "window"), doors = ops.filter(o => !o.W && o.kind !== "window");
  let wi = 0;
  for (const W of byLen) {
    if (wi >= wins.length) break;
    const n = Math.min(wins.length - wi, Math.max(1, Math.floor(W.len / 1.7)));
    for (let j = 0; j < n; j++) { const o = wins[wi++]; o.W = W; o.off = W.len * (j + 1) / (n + 1); }
  }
  const taken = new Set(ops.filter(o => o.W && o.kind === "window").map(o => o.W));
  const free = [...byLen].reverse().filter(W => !taken.has(W));
  doors.forEach((o, j) => { const W = free[j % Math.max(1, free.length)] || byLen[byLen.length - 1]; o.W = W; o.off = 0.15 + o.w / 2 + (j >= free.length ? 1 : 0); });
  // проёмы в стенах, без наложений
  for (const o of ops) {
    const W = o.W;
    if (!W) continue;
    const w = Math.min(o.w, W.len - 0.12);
    const u0 = clamp(o.off - w / 2, 0.06, W.len - 0.06 - w), v0 = o.kind === "window" ? clamp(o.bottom, 0.05, H - 0.4) : 0;
    const hole = { op: o, kind: o.kind, u0, u1: u0 + w, v0, v1: Math.min(v0 + o.h, H - 0.05) };
    if (hole.u1 - hole.u0 < 0.2 || W.holes.some(h => hole.u0 < h.u1 + 0.06 && hole.u1 > h.u0 - 0.06)) continue;
    W.holes.push(hole);
  }
  live.forEach(W => W.holes.sort((a, b) => a.u0 - b.u0));
  return { poly, walls, live, exact, H, box, center, segs: live.map(W => [...W.a, ...W.b]) };
}

// ---------- цвет ----------
const rgbOf = h => { const v = parseInt(h.slice(1), 16); return [v >> 16 & 255, v >> 8 & 255, v & 255]; };
const tone = (h, k) => rgbOf(h).map(v => k >= 0 ? v + (255 - v) * k : v * (1 + k));   // k>0 светлее, k<0 темнее
const css = (c, a = 1) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`;
const luma = h => { const [r, g, b] = rgbOf(h); return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255; };
const hexOf = c => "#" + c.map(v => clamp(Math.round(v), 0, 255).toString(16).padStart(2, "0")).join("");
function rng(seed) { let s = (seed * 2654435761) >>> 0 || 1; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }

// ---------- текстуры рисуем на холсте: доски, плитка со швами, штукатурка, обои ----------
const TEX = new Map();
let ANISO = 4;
function tex(key, meters, draw, { w = 1024, h = w, color = true, wrap = true } = {}) {
  if (TEX.has(key)) return TEX.get(key);
  const c = document.createElement("canvas");
  c.width = w; c.height = h;
  draw(c.getContext("2d"), w, h);
  const t = new T.CanvasTexture(c);
  if (wrap) t.wrapS = t.wrapT = T.RepeatWrapping;
  t.anisotropy = ANISO;
  t.colorSpace = color ? T.SRGBColorSpace : T.NoColorSpace;
  const [mx, my] = Array.isArray(meters) ? meters : [meters, meters];
  t.repeat.set(1 / mx, 1 / my);
  TEX.set(key, t);
  return t;
}
function speckle(g, w, h, r, amp) {
  const d = g.getImageData(0, 0, w, h), a = d.data;
  for (let i = 0; i < a.length; i += 4) { const n = (r() - 0.5) * amp; a[i] += n; a[i + 1] += n; a[i + 2] += n; }
  g.putImageData(d, 0, 0);
}
function blobs(g, w, h, r, n, rad, cols) {   // мягкие пятна, бесшовно
  for (let i = 0; i < n; i++) {
    const x = r() * w, y = r() * h, R = rad * (0.4 + r()), c = cols[(r() * cols.length) | 0];
    for (const ox of [-w, 0, w]) for (const oy of [-h, 0, h]) {
      const X = x + ox, Y = y + oy;
      if (X + R < 0 || X - R > w || Y + R < 0 || Y - R > h) continue;
      const gr = g.createRadialGradient(X, Y, 0, X, Y, R);
      gr.addColorStop(0, css(c, c[3])); gr.addColorStop(1, css(c, 0));
      g.fillStyle = gr; g.fillRect(X - R, Y - R, 2 * R, 2 * R);
    }
  }
}
function spots(g, x, y, w, h, r, n, rad, cols) {   // пятна внутри прямоугольника
  for (let i = 0; i < n; i++) {
    const X = x + r() * w, Y = y + r() * h, R = rad * (0.4 + r()), c = cols[(r() * cols.length) | 0];
    const gr = g.createRadialGradient(X, Y, 0, X, Y, R);
    gr.addColorStop(0, css(c, c[3])); gr.addColorStop(1, css(c, 0));
    g.fillStyle = gr; g.fillRect(X - R, Y - R, 2 * R, 2 * R);
  }
}
function plank(g, x, y, w, h, base, seed, vertical = false) {
  const r = rng(seed);
  g.save(); g.beginPath(); g.rect(x, y, w, h); g.clip();
  g.fillStyle = css(tone(base, (r() - 0.5) * 0.2)); g.fillRect(x, y, w, h);
  const len = vertical ? h : w, across = vertical ? w : h;
  for (let i = 0, n = 14 + (r() * 12 | 0); i < n; i++) {   // волокна
    g.strokeStyle = css(tone(base, r() < 0.75 ? -0.22 - r() * 0.25 : 0.18), 0.05 + r() * 0.13);
    g.lineWidth = 0.6 + r() * 2;
    const p0 = r() * across, amp = 0.6 + r() * 3, f = 0.003 + r() * 0.012, ph = r() * 6;
    g.beginPath();
    for (let s = 0; s <= len + 16; s += 16) {
      const q = p0 + Math.sin(s * f + ph) * amp;
      vertical ? (s ? g.lineTo(x + q, y + s) : g.moveTo(x + q, y)) : (s ? g.lineTo(x + s, y + q) : g.moveTo(x, y + q));
    }
    g.stroke();
  }
  if (r() < 0.22) {   // сучок
    const kx = vertical ? x + r() * w : x + r() * w, ky = vertical ? y + r() * h : y + r() * h;
    g.fillStyle = css(tone(base, -0.45), 0.35);
    g.beginPath(); g.ellipse(kx, ky, vertical ? 3 : 9, vertical ? 9 : 3, 0, 0, 2 * PI); g.fill();
  }
  g.restore();
  g.strokeStyle = "rgba(24,14,6,.5)"; g.lineWidth = 1.6; g.strokeRect(x + 0.8, y + 0.8, w - 1.6, h - 1.6);
}
const TX = {
  // ламинат: доски 1,2 × 0,2 м вразбежку
  laminate: c => tex("lam" + c, 2.4, (g, S) => {
    const px = S / 2.4, pw = 0.2 * px, pl = 1.2 * px;
    for (let row = 0; row < 12; row++) {
      const off = rng(row * 97 + 3)() * pl;
      for (let j = 0; j < 3; j++) plank(g, -off + j * pl, row * pw, pl, pw, c, row * 31 + (j % 2) * 7 + 1);
    }
  }),
  // паркет ёлочкой: плашки 36 × 9 см; холст — ровно две решётки узора, поэтому без швов
  parquet: c => tex("par" + c, 8 * 0.09 * Math.SQRT2, (g, S) => {
    const px = S / (8 * 0.09 * Math.SQRT2), W = 0.09 * px, L = 4 * W;
    g.fillStyle = css(tone(c, -0.4)); g.fillRect(0, 0, S, S);
    g.save(); g.rotate(-PI / 4);
    const vis = (x, y) => { const X = (x + y) / Math.SQRT2, Y = (y - x) / Math.SQRT2; return X > -L && X < S + L && Y > -L && Y < S + L; };
    for (let m = -6; m <= 6; m++) for (let n = -40; n <= 40; n++) {
      const seed = ((n % 8 + 8) % 8) * 13 + ((m % 2 + 2) % 2) * 101 + 5;
      const hx = n * W + m * L, hy = n * W - m * L, vx = L + n * W + m * L, vy = (n + 1) * W - L - m * L;
      if (vis(hx + L / 2, hy + W / 2)) plank(g, hx, hy, L, W, c, seed);
      if (vis(vx + W / 2, vy + L / 2)) plank(g, vx, vy, W, L, c, seed + 57, true);
    }
    g.restore();
  }),
  // плитка 60 × 60 со швом 3 мм; «камень» — с прожилками
  tile: (c, size = 0.6, stone = false, key = "t") => tex(`${key}${c}${size}${stone}`, size * 2, (g, S) => {
    const px = S / (size * 2), gr = Math.max(2, 0.003 * px), dark = luma(c) > 0.45;
    g.fillStyle = css(dark ? tone(c, -0.3) : tone(c, 0.35)); g.fillRect(0, 0, S, S);
    for (let i = 0; i < 2; i++) for (let j = 0; j < 2; j++) {
      const r = rng(i * 7 + j * 3 + 11), x = i * S / 2 + gr / 2, y = j * S / 2 + gr / 2, w = S / 2 - gr;
      g.save(); g.beginPath(); g.rect(x, y, w, w); g.clip();
      g.fillStyle = css(tone(c, (r() - 0.5) * (stone ? 0.12 : 0.05))); g.fillRect(x, y, w, w);
      if (stone) {
        spots(g, x, y, w, w, r, 8, w * 0.35, [[...tone(c, 0.12), 0.25], [...tone(c, -0.1), 0.2]]);
        for (let k = 0; k < 7; k++) {
          g.strokeStyle = css(tone(c, r() < 0.5 ? -0.35 : 0.3), 0.12 + r() * 0.2); g.lineWidth = 0.8 + r() * 3.2;
          g.beginPath(); g.moveTo(x + r() * w, y);
          g.bezierCurveTo(x + r() * w, y + w * 0.3, x + r() * w, y + w * 0.7, x + r() * w, y + w); g.stroke();
        }
      }
      const sh = g.createLinearGradient(x, y, x + w, y + w);
      sh.addColorStop(0, "rgba(255,255,255,.07)"); sh.addColorStop(1, "rgba(0,0,0,.05)");
      g.fillStyle = sh; g.fillRect(x, y, w, w);
      g.restore();
    }
    speckle(g, S, S, rng(5), stone ? 14 : 6);
  }),
  carpet: c => tex("carpet" + c, 0.5, (g, S) => {
    g.fillStyle = css(rgbOf(c)); g.fillRect(0, 0, S, S);
    blobs(g, S, S, rng(4), 30, S * 0.15, [[...tone(c, 0.08), 0.35], [...tone(c, -0.08), 0.35]]);
    speckle(g, S, S, rng(6), 46);
  }, { w: 512 }),
  concrete: c => tex("conc" + c, 2, (g, S) => {
    g.fillStyle = css(rgbOf(c)); g.fillRect(0, 0, S, S);
    const r = rng(8);
    blobs(g, S, S, r, 90, S * 0.12, [[...tone(c, 0.1), 0.22], [...tone(c, -0.1), 0.2], [...tone(c, 0.04), 0.3]]);
    for (let i = 0; i < 30; i++) {   // следы шпателя
      g.strokeStyle = css(tone(c, r() < 0.5 ? 0.12 : -0.08), 0.05); g.lineWidth = 20 + r() * 50;
      g.beginPath(); g.arc(r() * S, r() * S, 80 + r() * 260, r() * 6, r() * 6 + 0.8); g.stroke();
    }
    speckle(g, S, S, r, 12);
  }),
  paint: c => tex("paint" + c, 1, (g, S) => {
    g.fillStyle = css(rgbOf(c)); g.fillRect(0, 0, S, S);
    blobs(g, S, S, rng(2), 18, S * 0.25, [[...tone(c, 0.025), 0.5], [...tone(c, -0.025), 0.5]]);
    speckle(g, S, S, rng(3), 5);
  }, { w: 512 }),
  plaster: c => tex("plas" + c, 1.6, (g, S) => {
    g.fillStyle = css(rgbOf(c)); g.fillRect(0, 0, S, S);
    const r = rng(12);
    blobs(g, S, S, r, 80, S * 0.16, [[...tone(c, 0.08), 0.45], [...tone(c, -0.07), 0.4]]);
    for (let i = 0; i < 60; i++) {   // мазки кельмы
      g.strokeStyle = css(tone(c, r() < 0.55 ? 0.1 : -0.06), 0.06); g.lineWidth = 16 + r() * 40;
      g.beginPath(); g.arc(r() * S, r() * S, 60 + r() * 200, r() * 6, r() * 6 + 0.6 + r()); g.stroke();
    }
    speckle(g, S, S, r, 6);
  }),
  wallpaper: (c, p) => tex(`wp${c}${p}`, 0.53, (g, S) => {
    g.fillStyle = css(rgbOf(c)); g.fillRect(0, 0, S, S);
    const m = luma(c) > 0.5 ? tone(c, -0.16) : tone(c, 0.18), r = rng(21);
    const wrap = f => { for (const ox of [-S, 0, S]) for (const oy of [-S, 0, S]) f(ox, oy); };
    if (p === "stripes") {
      for (const x0 of [0, S / 2]) { g.fillStyle = css(m, 0.4); g.fillRect(x0, 0, S * 0.14, S); g.fillStyle = css(m, 0.7); g.fillRect(x0 + S * 0.18, 0, S * 0.02, S); }
    } else if (p === "geometric") {
      g.strokeStyle = css(m, 0.7); g.lineWidth = S * 0.008;
      for (const k of [0.5, 0.3]) {
        g.beginPath(); g.moveTo(S / 2, S / 2 - S * k); g.lineTo(S / 2 + S * k, S / 2); g.lineTo(S / 2, S / 2 + S * k); g.lineTo(S / 2 - S * k, S / 2); g.closePath(); g.stroke();
      }
      g.fillStyle = css(m, 0.8);
      for (const [x, y] of [[0, 0], [S, 0], [0, S], [S, S], [S / 2, S / 2]]) g.fillRect(x - S * 0.02, y - S * 0.02, S * 0.04, S * 0.04);
    } else if (p === "floral") {
      const flower = (x, y, s, rot) => wrap((ox, oy) => {
        g.save(); g.translate(x + ox, y + oy); g.rotate(rot);
        g.fillStyle = css(m, 0.55);
        for (let k = 0; k < 5; k++) { g.rotate(2 * PI / 5); g.beginPath(); g.ellipse(0, -s * 0.55, s * 0.28, s * 0.55, 0, 0, 2 * PI); g.fill(); }
        g.fillStyle = css(tone(c, -0.3), 0.6); g.beginPath(); g.arc(0, 0, s * 0.22, 0, 2 * PI); g.fill();
        g.fillStyle = css(m, 0.4);
        for (const k of [-1, 1]) { g.beginPath(); g.ellipse(k * s * 1.1, s * 0.9, s * 0.5, s * 0.2, k * 0.7, 0, 2 * PI); g.fill(); }
        g.restore();
      });
      flower(S * 0.25, S * 0.25, S * 0.07, 0.2); flower(S * 0.75, S * 0.75, S * 0.07, 1.1);
      flower(S * 0.76, S * 0.22, S * 0.035, 0.5); flower(S * 0.22, S * 0.74, S * 0.035, 2);
    } else if (p === "damask") {
      const motif = (x, y, s) => wrap((ox, oy) => {
        const cx = x + ox, cy = y + oy;
        g.fillStyle = css(m, 0.55); g.beginPath();
        for (const k of [1, -1]) {
          g.moveTo(cx, cy - s);
          g.bezierCurveTo(cx + k * s * 0.55, cy - s * 0.7, cx + k * s * 0.15, cy - s * 0.25, cx + k * s * 0.62, cy);
          g.bezierCurveTo(cx + k * s * 0.95, cy + s * 0.3, cx + k * s * 0.3, cy + s * 0.75, cx, cy + s);
        }
        g.fill();
        g.fillStyle = css(rgbOf(c), 0.9); g.beginPath(); g.ellipse(cx, cy, s * 0.14, s * 0.3, 0, 0, 2 * PI); g.fill();
        g.fillStyle = css(m, 0.6);
        for (const k of [1, -1]) { g.beginPath(); g.arc(cx + k * s * 0.45, cy - s * 0.55, s * 0.06, 0, 2 * PI); g.fill(); }
      });
      motif(S / 2, S / 2, S * 0.3); motif(0, 0, S * 0.3);
    } else if (p === "linen") {
      for (let y = 0; y < S; y += 2) { g.fillStyle = css(r() < 0.5 ? tone(c, -0.1) : tone(c, 0.08), 0.12 + r() * 0.12); g.fillRect(0, y, S, 1); }
      for (let x = 0; x < S; x += 2) { g.fillStyle = css(r() < 0.5 ? tone(c, -0.1) : tone(c, 0.08), 0.08 + r() * 0.1); g.fillRect(x, 0, 1, S); }
    }
    speckle(g, S, S, r, 7);
  }, { w: 512 }),
  panels: c => tex("pan" + c, 0.5, (g, S) => {
    const n = 10, sw = S / n, gap = Math.max(3, S * 0.012);
    g.fillStyle = css(tone(c, -0.6)); g.fillRect(0, 0, S, S);
    for (let k = 0; k < n; k++) plank(g, k * sw + gap / 2, -2, sw - gap, S + 4, c, k * 13 + 2, true);
  }, { w: 512 }),
  brick: c => tex("brick" + c, [1.04, 1.05], (g, S) => {
    const sx = S / 1.04, sy = S / 1.05, bh = 0.065 * sy, rh = 0.075 * sy, bl = 0.25 * sx, ml = 0.26 * sx;
    g.fillStyle = css(tone(c, 0.55)); g.fillRect(0, 0, S, S);
    for (let row = 0; row < 14; row++) {
      const off = row % 2 ? ml / 2 : 0;
      for (let k = -1; k < 5; k++) {
        const r = rng(row * 17 + ((k % 4) + 4) % 4 * 5 + 3), x = off + k * ml, y = row * rh + (rh - bh) / 2;
        const base = hexOf(tone(c, (r() - 0.5) * 0.32 - (r() < 0.12 ? 0.22 : 0)));
        g.save(); g.beginPath(); g.rect(x, y, bl, bh); g.clip();
        g.fillStyle = css(rgbOf(base)); g.fillRect(x, y, bl, bh);
        spots(g, x, y, bl, bh, r, 4, bh * 0.9, [[...tone(base, -0.18), 0.4], [...tone(base, 0.15), 0.35]]);
        const e = g.createLinearGradient(0, y, 0, y + bh);
        e.addColorStop(0, "rgba(255,255,255,.08)"); e.addColorStop(1, "rgba(0,0,0,.18)");
        g.fillStyle = e; g.fillRect(x, y, bl, bh);
        g.restore();
      }
    }
    speckle(g, S, S, rng(9), 24);
  }),
  // плитка на стене: «кабанчик» 20 × 10 см вразбежку
  walltile: c => tex("wt" + c, 0.8, (g, S) => {
    const px = S / 0.8, tw = 0.2 * px, th = 0.1 * px, gr = Math.max(2, 0.002 * px);
    g.fillStyle = css(luma(c) > 0.45 ? tone(c, -0.22) : tone(c, 0.3)); g.fillRect(0, 0, S, S);
    for (let row = 0; row < 8; row++) for (let k = -1; k < 5; k++) {
      const x = (row % 2 ? tw / 2 : 0) + k * tw + gr / 2, y = row * th + gr / 2, r = rng(row * 5 + ((k % 4) + 4) % 4);
      g.fillStyle = css(tone(c, (r() - 0.5) * 0.05)); g.fillRect(x, y, tw - gr, th - gr);
      const e = g.createLinearGradient(0, y, 0, y + th);
      e.addColorStop(0, "rgba(255,255,255,.35)"); e.addColorStop(0.15, "rgba(255,255,255,0)"); e.addColorStop(0.85, "rgba(0,0,0,0)"); e.addColorStop(1, "rgba(0,0,0,.18)");
      g.fillStyle = e; g.fillRect(x, y, tw - gr, th - gr);
    }
  }),
  // ткань и дерево мебели: светлая фактура, цвет задаёт материал
  weave: () => tex("weave", [0.25, 0.25], (g, S) => {
    g.fillStyle = "#f2f2f2"; g.fillRect(0, 0, S, S);
    const r = rng(1);
    for (let y = 0; y < S; y += 2) { g.fillStyle = `rgba(0,0,0,${0.03 + r() * 0.06})`; g.fillRect(0, y, S, 1); }
    for (let x = 0; x < S; x += 2) { g.fillStyle = `rgba(0,0,0,${0.02 + r() * 0.05})`; g.fillRect(x, 0, 1, S); }
    speckle(g, S, S, r, 16);
  }, { w: 256 }),
  grain: () => tex("grain", [1, 1], (g, S) => {
    g.fillStyle = "#f4f4f4"; g.fillRect(0, 0, S, S);
    const r = rng(2);
    for (let i = 0; i < 90; i++) {
      g.strokeStyle = `rgba(60,40,20,${0.04 + r() * 0.1})`; g.lineWidth = 0.6 + r() * 2.4;
      const y0 = r() * S, amp = 1 + r() * 5, f = 0.004 + r() * 0.01;
      g.beginPath(); for (let x = 0; x <= S; x += 16) (x ? g.lineTo(x, y0 + Math.sin(x * f) * amp) : g.moveTo(0, y0)); g.stroke();
    }
  }, { w: 512 }),
  // мягкая тень под мебелью
  shadow: () => tex("shadow", 1, (g, S) => {
    g.shadowColor = "rgba(0,0,0,1)"; g.shadowBlur = S * 0.09; g.shadowOffsetX = S * 2;
    g.fillStyle = "#000"; g.beginPath();
    if (g.roundRect) g.roundRect(-S * 2 + S * 0.18, S * 0.18, S * 0.64, S * 0.64, S * 0.08); else g.rect(-S * 2 + S * 0.18, S * 0.18, S * 0.64, S * 0.64);
    g.fill();
  }, { w: 128, wrap: false }),
  // затенение углов: тёмное у края, прозрачное дальше
  ao: () => tex("ao", 1, (g, w, h) => {
    const gr = g.createLinearGradient(0, 0, 0, h);
    gr.addColorStop(0, "rgba(0,0,0,0)"); gr.addColorStop(0.6, "rgba(0,0,0,.18)"); gr.addColorStop(1, "rgba(0,0,0,1)");
    g.fillStyle = gr; g.fillRect(0, 0, w, h);
  }, { w: 4, h: 64, wrap: false }),
  // за окном: небо и деревья вдалеке
  sky: () => tex("sky", 1, (g, S) => {
    const gr = g.createLinearGradient(0, 0, 0, S);
    gr.addColorStop(0, "#8fb9e6"); gr.addColorStop(0.55, "#dcebf7"); gr.addColorStop(0.62, "#eef4f7"); gr.addColorStop(1, "#c9d3c1");
    g.fillStyle = gr; g.fillRect(0, 0, S, S);
    const r = rng(33);
    for (let i = 0; i < 70; i++) {
      g.fillStyle = css(tone("#6f8a62", (r() - 0.5) * 0.3), 0.85);
      g.beginPath(); g.arc(r() * S, S * (0.62 + r() * 0.1), S * (0.03 + r() * 0.06), 0, 2 * PI); g.fill();
    }
    g.fillStyle = "#a9b79c"; g.fillRect(0, S * 0.7, S, S * 0.3);
  }, { w: 256, wrap: false }),
  blinds: c => tex("bl" + c, [1, 0.05], (g, w, h) => {
    g.fillStyle = css(rgbOf(c)); g.fillRect(0, 0, w, h);
    const gr = g.createLinearGradient(0, 0, 0, h);
    gr.addColorStop(0, "rgba(255,255,255,.35)"); gr.addColorStop(0.7, "rgba(0,0,0,0)"); gr.addColorStop(0.92, "rgba(0,0,0,.35)"); gr.addColorStop(1, "rgba(0,0,0,.6)");
    g.fillStyle = gr; g.fillRect(0, 0, w, h);
  }, { w: 8, h: 32 }),
};

// ---------- материалы ----------
const MAT = new Map();
const mat = (key, make) => MAT.get(key) || (MAT.set(key, make()), MAT.get(key));
const std = (color, rough = 0.6, metal = 0, extra = {}) => mat(`s${color}${rough}${metal}${JSON.stringify(extra)}`,
  () => new T.MeshStandardMaterial({ color, roughness: rough, metalness: metal, ...extra }));
const fabric = (c, leather = false) => mat(`f${c}${leather}`, () => leather
  ? new T.MeshPhysicalMaterial({ color: c, roughness: 0.42, clearcoat: 0.35, clearcoatRoughness: 0.45, bumpMap: TX.weave(), bumpScale: 0.3 })
  : new T.MeshPhysicalMaterial({ color: c, roughness: 0.95, map: TX.weave(), bumpMap: TX.weave(), bumpScale: 0.8,
    sheen: 1, sheenRoughness: 0.65, sheenColor: new T.Color(hexOf(tone(c, 0.45))) }));
const wood = c => mat("w" + c, () => new T.MeshStandardMaterial({ color: c, roughness: 0.5, map: TX.grain() }));
const metal = c => std(c, 0.32, 0.85);
const ceramic = c => std(c, 0.12, 0);
const appliance = c => std(c, 0.28, luma(c) < 0.5 ? 0.45 : 0.08);
const glow = (c = "#ffe2b8", k = 3) => mat(`g${c}${k}`, () => new T.MeshStandardMaterial({ color: "#ffffff", emissive: c, emissiveIntensity: k }));
const glassM = () => mat("glass", () => new T.MeshStandardMaterial({ color: "#c8d8e4", roughness: 0.04, metalness: 0.1, transparent: true, opacity: 0.16, depthWrite: false }));
const screenM = () => mat("screen", () => new T.MeshStandardMaterial({ color: "#0b0e12", roughness: 0.07, metalness: 0.3, emissive: "#0d1520", emissiveIntensity: 0.4 }));

function surfaceMat(where, finish, color, pattern) {
  return mat(`${where}${finish}${color}${pattern}`, () => {
    let map, rough = 0.9, bump = 0.8;
    if (where === "floor") {
      if (finish === "parquet") { map = TX.parquet(color); rough = 0.36; bump = 1.2; }
      else if (finish === "tile") { map = TX.tile(color); rough = 0.14; bump = 1.2; }
      else if (finish === "stone") { map = TX.tile(color, 0.6, true); rough = 0.22; bump = 1; }
      else if (finish === "carpet") { map = TX.carpet(color); rough = 1; bump = 1.5; }
      else if (finish === "concrete") { map = TX.concrete(color); rough = 0.62; bump = 0.6; }
      else { map = TX.laminate(color); rough = 0.52; bump = 1.2; }
    } else {
      if (finish === "wallpaper") { map = TX.wallpaper(color, pattern); rough = 0.86; bump = 0.8; }
      else if (finish === "plaster") { map = TX.plaster(color); rough = 0.55; bump = 0.6; }
      else if (finish === "panels") { map = TX.panels(color); rough = 0.6; bump = 1.5; }
      else if (finish === "tile") { map = TX.walltile(color); rough = 0.14; bump = 1.2; }
      else if (finish === "brick") { map = TX.brick(color); rough = 0.95; bump = 2.5; }
      else { map = TX.paint(color); rough = 0.93; bump = 0.4; }
    }
    return new T.MeshStandardMaterial({ map, bumpMap: map, bumpScale: bump, roughness: rough });
  });
}

// ---------- мебель из простых тел, в точных размерах ----------
// Своя система: ширина по X, глубина по Z (спинка сзади, −Z), низ на полу (y = 0)
function mesh(g, geo, m, x = 0, y = 0, z = 0) {
  const o = new T.Mesh(geo, m);
  o.position.set(x, y, z); o.castShadow = o.receiveShadow = true;
  g.add(o);
  return o;
}
function rb(w, h, d, r) {
  r = Math.min(r, w / 2 - 0.002, h / 2 - 0.002, d / 2 - 0.002);
  return r > 0.004 ? new T.RoundedBoxGeometry(w, h, d, 3, r) : new T.BoxGeometry(Math.max(w, 0.002), Math.max(h, 0.002), Math.max(d, 0.002));
}
const box = (g, w, h, d, m, x = 0, y = 0, z = 0, r = 0) => mesh(g, rb(w, h, d, r), m, x, y + h / 2, z);
const cyl = (g, r1, r2, h, m, x = 0, y = 0, z = 0, seg = 24) => mesh(g, new T.CylinderGeometry(r1, r2, h, seg), m, x, y + h / 2, z);
const ball = (g, r, m, x = 0, y = 0, z = 0, sx = 1, sy = 1, sz = 1) => { const o = mesh(g, new T.SphereGeometry(r, 24, 16), m, x, y, z); o.scale.set(sx, sy, sz); return o; };
function legs(g, w, d, h, m, inset = 0.05, r = 0.018, round = true) {
  for (const sx of [-1, 1]) for (const sz of [-1, 1]) {
    const x = sx * (w / 2 - inset), z = sz * (d / 2 - inset);
    round ? cyl(g, r, r * 0.7, h, m, x, 0, z, 12) : box(g, r * 2, h, r * 2, m, x, 0, z);
  }
}
const BOOKS = ["#7a2e35", "#2f3a4a", "#c9b48a", "#4f6250", "#e8e2d6", "#8a5a44", "#5b5f66", "#b08d68", "#d9cbb0"];
function books(g, x0, x1, y, z, depth, seed) {
  const r = rng(seed);
  for (let x = x0; x < x1 - 0.03;) {
    const w = 0.02 + r() * 0.035, h = 0.17 + r() * 0.12;
    if (r() < 0.12) { x += 0.06; continue; }
    box(g, w, h, depth * (0.7 + r() * 0.25), std(BOOKS[(r() * BOOKS.length) | 0], 0.8), x + w / 2, y, z);
    x += w + 0.002;
  }
}

function sofaBody(g, w, d, h, C, o = {}) {
  const { left = true, right = true, back = true, pillows = true, chester = false } = o;
  const legH = chester ? 0.07 : 0.1, baseTop = legH + 0.2, seatTop = baseTop + 0.13;
  const armW = clamp(w * 0.08, 0.12, chester ? 0.22 : 0.2), backD = back ? clamp(d * 0.2, 0.15, 0.24) : 0;
  const backTop = Math.max(h, seatTop + 0.3), armTop = chester ? backTop - 0.03 : Math.min(backTop - 0.08, seatTop + 0.2);
  legs(g, w, d, legH, C.leg, 0.06, chester ? 0.028 : 0.02);
  box(g, w, baseTop - legH, d, C.main, 0, legH, 0, 0.025);
  if (back) box(g, w, backTop - legH, backD, C.main, 0, legH, -d / 2 + backD / 2, 0.04);
  const x0 = -w / 2 + (left ? armW : 0), x1 = w / 2 - (right ? armW : 0), inner = x1 - x0;
  for (const [on, s] of [[left, -1], [right, 1]]) {
    if (!on) continue;
    box(g, armW, armTop - legH, d, C.main, s * (w / 2 - armW / 2), legH, 0, 0.045);
    if (chester) { const roll = mesh(g, new T.CylinderGeometry(armW * 0.62, armW * 0.62, d, 24), C.main, s * (w / 2 - armW / 2), armTop, 0); roll.rotation.x = PI / 2; }
  }
  const n = inner > 2.1 ? 3 : inner > 1.25 ? 2 : 1, cw = inner / n, seatD = d - backD - 0.01;
  for (let k = 0; k < n; k++) {
    const x = x0 + cw * (k + 0.5);
    box(g, cw - 0.012, seatTop - baseTop + 0.02, seatD, C.main, x, baseTop - 0.02, backD / 2 + 0.005, 0.05);
    if (back && !chester) {
      const c = box(g, cw - 0.02, backTop - seatTop - 0.03, 0.18, C.main, x, seatTop - 0.01, -d / 2 + backD + 0.08, 0.07);
      c.rotation.x = -0.13;
    }
  }
  if (chester && back) {   // стёжка пуговицами
    const cols = Math.max(3, Math.round(inner / 0.17));
    for (let k = 0; k <= cols; k++) for (const yy of [seatTop + 0.14, seatTop + 0.3]) {
      if (yy > backTop - 0.05) continue;
      ball(g, 0.013, C.dark, x0 + inner * k / cols, yy, -d / 2 + backD + 0.004);
    }
  }
  if (pillows && back && inner > 1.1) for (const s of [-1, 1]) {
    const p = box(g, 0.42, 0.4, 0.13, C.accent, (x0 + x1) / 2 + s * (inner / 2 - 0.3), seatTop + 0.01, -d / 2 + backD + 0.22, 0.06);
    p.rotation.set(-0.3, 0, s * 0.1);
  }
}

const BUILD = {
  sofa(g, w, d, h, v, C) {
    if (v === "corner") {
      const dm = Math.min(d, 1), dc = Math.max(d, 1.5), cw = clamp(w * 0.36, 0.8, 1.1);
      const main = new T.Group(); main.position.z = -d / 2 + dm / 2; g.add(main);
      sofaBody(main, w, dm, h, C, { right: false });
      const ch = new T.Group(); ch.position.set(w / 2 - cw / 2, 0, -d / 2 + dm + (dc - dm) / 2 - 0.01); g.add(ch);
      sofaBody(ch, cw, dc - dm + 0.02, h, C, { left: false, back: false, pillows: false });
      return;
    }
    if (v === "modular") {
      const n = clamp(Math.round(w / 0.9), 2, 4), mw = w / n, hh = Math.min(h, 0.74), backD = clamp(d * 0.22, 0.18, 0.26);
      box(g, w - 0.04, 0.04, d - 0.04, C.dark, 0, 0, 0);
      for (let k = 0; k < n; k++) {
        const x = -w / 2 + mw * (k + 0.5);
        box(g, mw - 0.01, 0.26, d, C.main, x, 0.03, 0, 0.03);
        box(g, mw - 0.02, 0.14, d - backD - 0.02, C.main, x, 0.28, backD / 2, 0.06);
        box(g, mw - 0.02, hh - 0.03, backD, C.main, x, 0.03, -d / 2 + backD / 2, 0.06);
      }
      return;
    }
    sofaBody(g, w, d, h, C, { chester: v === "chesterfield" });
  },
  bed(g, w, d, h, v, C) {
    const legH = v === "platform" ? 0.02 : 0.08, frameH = v === "platform" ? 0.2 : 0.26, hbD = 0.08;
    const frameM = v === "upholstered" ? C.main : C.woodM;
    if (v === "platform") box(g, w - 0.1, legH, d - hbD - 0.1, C.dark, 0, 0, hbD / 2);
    else legs(g, w, d - hbD, legH, C.leg, 0.06, 0.03, false);
    box(g, w, frameH, d - hbD, frameM, 0, legH, hbD / 2, 0.02);
    const mTop = legH + frameH + 0.18;
    box(g, w - 0.06, 0.24, d - hbD - 0.06, C.bedding, 0, legH + frameH - 0.06, hbD / 2, 0.07);
    box(g, w + 0.03, 0.06, (d - hbD) * 0.7, C.duvet, 0, mTop - 0.03, d / 2 - (d - hbD) * 0.35 - 0.02, 0.03);
    box(g, w + 0.05, 0.02, 0.45, C.accentM, 0, mTop + 0.025, d / 2 - 0.35, 0.008);
    const pw = w < 1.2 ? w - 0.2 : (w - 0.25) / 2;
    for (const s of w < 1.2 ? [0] : [-1, 1]) {
      const p = box(g, pw, 0.14, 0.4, C.bedding, s * (pw / 2 + 0.04), mTop - 0.01, -d / 2 + hbD + 0.26, 0.06);
      p.rotation.x = -0.35;
    }
    const hbH = Math.max(h, mTop + 0.35);
    if (v === "classic") {
      box(g, w, hbH - 0.1, 0.05, C.woodM, 0, 0.1, -d / 2 + 0.03, 0.01);
      for (const s of [-1, 1]) { cyl(g, 0.035, 0.035, hbH, C.woodM, s * (w / 2 - 0.01), 0, -d / 2 + 0.03, 16); ball(g, 0.045, C.woodM, s * (w / 2 - 0.01), hbH + 0.03, -d / 2 + 0.03); }
      box(g, w, 0.45, 0.04, C.woodM, 0, 0.1, d / 2 - 0.02, 0.01);
    } else if (v === "platform") {
      box(g, w + 0.3, 0.55, 0.06, C.woodM, 0, legH + 0.2, -d / 2 + 0.03, 0.01);
    } else {
      box(g, w + 0.08, hbH - legH, hbD + 0.02, C.main, 0, legH, -d / 2 + hbD / 2, 0.05);
      const n = Math.max(3, Math.round(w / 0.3));
      for (let k = 1; k < n; k++) box(g, 0.012, hbH - legH - 0.4, 0.01, C.dark, -w / 2 - 0.04 + (w + 0.08) * k / n, mTop + 0.02, -d / 2 + hbD + 0.012);
    }
  },
  chair(g, w, d, h, v, C) {
    if (v === "armchair") {
      sofaBody(g, w, d, h, C, { pillows: false });
      return;
    }
    if (v === "stool") {
      const r = Math.min(w, d) / 2;
      cyl(g, r, r * 0.92, 0.045, C.main, 0, h - 0.045, 0, 28);
      for (let k = 0; k < 4; k++) {
        const a = k * PI / 2 + PI / 4, l = mesh(g, new T.CylinderGeometry(0.015, 0.018, h - 0.04, 10), C.main, Math.cos(a) * r * 0.62, (h - 0.04) / 2, Math.sin(a) * r * 0.62);
        l.rotation.set(Math.sin(a) * 0.1, 0, -Math.cos(a) * 0.1);
      }
      const ring = mesh(g, new T.TorusGeometry(r * 0.62, 0.008, 8, 32), C.main, 0, h * 0.32, 0); ring.rotation.x = PI / 2;
      return;
    }
    const seatY = Math.min(0.47, h * 0.53);
    legs(g, w, d, seatY - 0.04, C.main, 0.035, 0.016, false);
    box(g, w, 0.04, d, C.main, 0, seatY - 0.04, 0, 0.008);
    box(g, w - 0.05, 0.035, d - 0.07, C.pad, 0, seatY, 0.015, 0.015);
    for (const s of [-1, 1]) box(g, 0.032, h - seatY + 0.04, 0.032, C.main, s * (w / 2 - 0.035), seatY - 0.04, -d / 2 + 0.035);
    const b = box(g, w - 0.02, 0.18, 0.025, C.main, 0, h - 0.2, -d / 2 + 0.03, 0.01); b.rotation.x = -0.08;
  },
  table(g, w, d, h, v, C) {
    const m = C.main;
    if (v === "dining_round") {
      const r = Math.min(w, d) / 2;
      cyl(g, r, r, 0.04, m, 0, h - 0.04, 0, 48);
      cyl(g, 0.05, 0.07, h - 0.09, m, 0, 0.05, 0, 16);
      cyl(g, r * 0.42, r * 0.48, 0.05, m, 0, 0, 0, 32);
      ball(g, 0.12, std(C.pal.accent, 0.3), 0, h + 0.02, 0, 1, 0.45, 1);
      return;
    }
    if (v === "coffee") {
      const hh = Math.min(h, 0.46);
      box(g, w, 0.035, d, m, 0, hh - 0.035, 0, 0.012);
      box(g, w - 0.08, 0.02, d - 0.08, m, 0, 0.12, 0);
      legs(g, w, d, hh - 0.035, C.leg, 0.04, 0.014);
      box(g, 0.24, 0.025, 0.17, std("#2f3a4a", 0.8), -w * 0.18, hh, 0.02);
      box(g, 0.22, 0.02, 0.15, std("#c9b48a", 0.8), -w * 0.18, hh + 0.025, 0.02);
      cyl(g, 0.045, 0.035, 0.16, ceramic("#eceae4"), w * 0.22, hh, -0.04, 20);
      return;
    }
    box(g, w, 0.035, d, m, 0, h - 0.035, 0, 0.008);
    if (v === "desk") {
      const dw = Math.min(0.42, w * 0.38);
      box(g, dw, h - 0.035, d - 0.04, m, -w / 2 + dw / 2 + 0.01, 0, 0);
      for (let k = 0; k < 3; k++) box(g, 0.1, 0.012, 0.012, C.metalM, -w / 2 + dw / 2 + 0.01, h * (0.18 + k * 0.27), d / 2 - 0.015);
      for (const s of [-1, 1]) box(g, 0.04, h - 0.035, 0.04, C.leg, w / 2 - 0.05, 0, s * (d / 2 - 0.05));
      return;
    }
    legs(g, w, d, h - 0.035, m, 0.06, 0.03, false);
    box(g, w - 0.14, 0.07, d - 0.14, m, 0, h - 0.105, 0);
    ball(g, 0.13, ceramic("#eceae4"), 0, h + 0.03, 0, 1, 0.42, 1);
  },
  storage(g, w, d, h, v, C) {
    const m = C.main, gap = C.dark;
    if (v === "shelving") {
      for (const s of [-1, 1]) box(g, 0.025, h, d, m, s * (w / 2 - 0.0125), 0, 0);
      box(g, w - 0.05, h - 0.02, 0.01, m, 0, 0.01, -d / 2 + 0.005);
      const n = Math.max(2, Math.round(h / 0.36));
      for (let k = 0; k <= n; k++) {
        const y = 0.02 + (h - 0.045) * k / n;
        box(g, w - 0.05, 0.022, d, m, 0, y, 0);
        if (k < n) books(g, -w / 2 + 0.04, w / 2 - 0.04 - (k % 2 ? 0.2 : 0), y + 0.022, 0, d, k * 11 + 3);
      }
      return;
    }
    if (v === "wardrobe") {
      box(g, w - 0.03, 0.07, d - 0.04, gap, 0, 0, -0.01);
      box(g, w, h - 0.07, d, m, 0, 0.07, 0, 0.006);
      const n = Math.max(2, Math.round(w / 0.5));
      for (let k = 1; k < n; k++) box(g, 0.004, h - 0.12, 0.004, gap, -w / 2 + w * k / n, 0.095, d / 2);
      for (let k = 0; k < n; k++) {
        const x = -w / 2 + w * (k + 0.5) / n + (k % 2 ? -1 : 1) * (w / n / 2 - 0.05);
        box(g, 0.012, 0.28, 0.02, C.metalM, x, 0.95, d / 2 + 0.01, 0.004);
      }
      return;
    }
    const hh = v === "tv_stand" ? Math.min(h, 0.62) : Math.min(h, 1.05), legH = 0.1;
    legs(g, w, d, legH, C.leg, 0.05, 0.015);
    box(g, w, hh - legH, d, m, 0, legH, 0, 0.008);
    if (v === "tv_stand") {
      const n = Math.max(2, Math.round(w / 0.6));
      for (let k = 1; k < n; k++) box(g, 0.004, hh - legH - 0.04, 0.004, gap, -w / 2 + w * k / n, legH + 0.02, d / 2);
      for (let k = 0; k < n; k++) box(g, 0.14, 0.01, 0.015, C.metalM, -w / 2 + w * (k + 0.5) / n, hh - 0.07, d / 2 + 0.008);
    } else {
      const rows = 3, rh = (hh - legH) / rows;
      for (let k = 1; k < rows; k++) box(g, w - 0.03, 0.004, 0.004, gap, 0, legH + rh * k, d / 2);
      for (let k = 0; k < rows; k++) for (const s of w > 0.8 ? [-1, 1] : [0]) ball(g, 0.014, C.metalM, s * w / 4, legH + rh * (k + 0.5), d / 2 + 0.01);
      if (!C.underWindow) cyl(g, 0.06, 0.05, 0.22, ceramic("#eceae4"), w * 0.3, hh, 0, 20);   // под окном ваза упёрлась бы в подоконник
    }
  },
  television(g, w, d, h, v, C) {
    const t = Math.min(d, 0.05);
    box(g, w, h, t, std("#18191b", 0.35, 0.3), 0, 0, 0, 0.004);
    mesh(g, new T.PlaneGeometry(w - 0.02, h - 0.02), screenM(), 0, h / 2, t / 2 + 0.001);
    if (C.onFurniture) { box(g, 0.05, 0.08, 0.05, C.metalM, 0, -0.08, -0.01); box(g, w * 0.32, 0.012, 0.22, C.metalM, 0, -0.085, 0); }
  },
  refrigerator(g, w, d, h, v, C) {
    box(g, w, h, d, C.main, 0, 0, 0, 0.02);
    box(g, w - 0.01, 0.004, 0.004, C.dark, 0, h * 0.62, d / 2);
    for (const [y, l] of [[h * 0.66, 0.34], [h * 0.4, 0.4]]) box(g, 0.02, l, 0.03, C.metalM, -w / 2 + 0.06, y, d / 2 + 0.015, 0.006);
  },
  stove(g, w, d, h, v, C) {
    box(g, w, h - 0.02, d, C.main, 0, 0, 0, 0.01);
    box(g, w, 0.02, d, std("#0e0f11", 0.08, 0.2), 0, h - 0.02, 0, 0.006);
    for (const [x, z, r] of [[-1, -1, 0.08], [1, -1, 0.06], [-1, 1, 0.06], [1, 1, 0.08]]) {
      const o = mesh(g, new T.TorusGeometry(r, 0.004, 6, 32), std("#3a3b3d", 0.4), x * w / 4, h + 0.002, z * d / 4); o.rotation.x = PI / 2;
    }
    box(g, w - 0.08, h * 0.45, 0.01, std("#0e0f11", 0.1, 0.2), 0, 0.12, d / 2);
    box(g, w - 0.14, 0.02, 0.03, C.metalM, 0, 0.12 + h * 0.45 + 0.02, d / 2 + 0.02, 0.008);
  },
  oven(g, w, d, h, v, C) { BUILD.stove(g, w, d, h, v, C); },
  dishwasher(g, w, d, h, v, C) {
    box(g, w, h, d, C.main, 0, 0, 0, 0.01);
    box(g, w - 0.01, 0.08, 0.004, C.dark, 0, h - 0.1, d / 2);
    box(g, w * 0.5, 0.02, 0.025, C.metalM, 0, h - 0.16, d / 2 + 0.012, 0.006);
  },
  washerDryer(g, w, d, h, v, C) {
    box(g, w, h, d, C.main, 0, 0, 0, 0.02);
    box(g, w - 0.02, 0.1, 0.004, C.dark, 0, h - 0.13, d / 2);
    const R = Math.min(w, h) * 0.3;
    const ring = mesh(g, new T.TorusGeometry(R, 0.028, 12, 40), std("#b8babf", 0.3, 0.7), 0, h * 0.45, d / 2 + 0.01);
    ring.scale.z = 0.6;
    const glassD = mesh(g, new T.CylinderGeometry(R - 0.02, R - 0.02, 0.01, 40), std("#1c2229", 0.05, 0.3), 0, h * 0.45, d / 2 + 0.012);
    glassD.rotation.x = PI / 2;
  },
  sink(g, w, d, h, v, C) {
    box(g, w, h - 0.05, d, C.cab, 0, 0, 0, 0.006);
    box(g, w, 0.05, d, C.main, 0, h - 0.05, 0, 0.012);
    const b = mesh(g, new T.CylinderGeometry(Math.min(w, d) * 0.36, Math.min(w, d) * 0.33, 0.012, 36), std("#d8d6d0", 0.1), 0, h + 0.001, 0.02);
    b.scale.x = w / d * 0.8;
    cyl(g, 0.018, 0.022, 0.2, C.metalM, 0, h, -d / 2 + 0.07, 14);
    const sp = box(g, 0.02, 0.02, 0.14, C.metalM, 0, h + 0.18, -d / 2 + 0.13, 0.008); sp.rotation.x = 0.15;
  },
  toilet(g, w, d, h, v, C) {
    const base = cyl(g, w * 0.32, w * 0.38, 0.38, C.main, 0, 0, 0.05, 28); base.scale.z = 1.35;
    ball(g, w * 0.5, C.main, 0, 0.38, 0.06, 1, 0.3, 1.45);
    const seat = mesh(g, new T.TorusGeometry(w * 0.34, 0.03, 10, 32), C.main, 0, 0.42, 0.07); seat.rotation.x = PI / 2; seat.scale.y = 1.35;
    box(g, w * 0.95, 0.36, 0.17, C.main, 0, Math.max(0.42, h - 0.36), -d / 2 + 0.085, 0.03);
    cyl(g, 0.025, 0.025, 0.01, C.metalM, 0, Math.max(0.42, h - 0.36) + 0.36, -d / 2 + 0.085, 16);
  },
  bathtub(g, w, d, h, v, C) {
    box(g, w, h, d, C.main, 0, 0, 0, 0.04);
    box(g, w - 0.14, 0.012, d - 0.14, std(hexOf(tone(C.color, -0.07)), 0.08), 0, h - 0.004, 0, 0.05);
    cyl(g, 0.02, 0.02, 0.18, C.metalM, -w / 2 + 0.1, h, -d / 2 + 0.12, 14);
  },
  fireplace(g, w, d, h, v, C) {
    box(g, w, h, d, C.main, 0, 0, 0, 0.01);
    box(g, w + 0.12, 0.05, d + 0.08, C.main, 0, h, 0.02, 0.01);
    box(g, w * 0.56, h * 0.48, 0.02, std("#121212", 0.9), 0, 0.08, d / 2);
    box(g, w * 0.4, 0.06, 0.02, glow("#ff8a3c", 1.4), 0, 0.12, d / 2 + 0.005);
  },
  stairs(g, w, d, h, v, C) {
    const n = Math.max(3, Math.round(h / 0.18));
    for (let k = 0; k < n; k++) box(g, w, h * (k + 1) / n, d / n, C.main, 0, 0, d / 2 - d / n * (k + 0.5));
  },
  object(g, w, d, h, v, C) { box(g, w, h, d, C.main, 0, 0, 0, Math.min(w, d, h) * 0.12); },
};

// ---------- 3D-сцена ----------
export function createRoom3D({ canvas, scan, look, reduced = false, onPick, onChange }) {
  const room = roomOf(scan);
  let renderer;
  try {
    renderer = new T.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: "high-performance" });
  } catch { return null; }
  if (!renderer.getContext()) return null;
  ANISO = Math.min(8, renderer.capabilities.getMaxAnisotropy());
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
  renderer.toneMapping = T.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = T.PCFShadowMap;
  renderer.shadowMap.autoUpdate = false;
  renderer.setClearColor(0x000000, 0);

  const scene = new T.Scene();
  let pmrem, envTex;
  const makeEnv = () => {   // отражения комнаты в лаке, металле и стекле
    const env = new T.RoomEnvironment();
    pmrem = new T.PMREMGenerator(renderer);
    envTex = pmrem.fromScene(env, 0.04).texture;
    env.dispose();
    scene.environment = envTex;
  };
  makeEnv();
  const camera = new T.PerspectiveCamera(50, 1, 0.05, 120);
  const [bx0, by0, bx1, by1] = room.box, H = room.H, [cx, cy] = room.center;
  const span = Math.hypot(bx1 - bx0, by1 - by0);

  let L = resolveLook(look), pal = STYLES[L.style].pal;
  let mode = "orbit", dirty = true, raf = 0, anim = null, grow = reduced ? 1 : 0, sel = null, inset = 0;
  const pickables = new Set();
  const items = new Map();                 // "o3" / "a0" → { group, spec }
  const wallParts = [];                    // по стенам: группа, стена, отделка, шторы, небо
  const need = () => { dirty = true; };
  const shadows = () => { renderer.shadowMap.needsUpdate = true; dirty = true; };
  const tag = (o, s) => { o.userData.sel = s; pickables.add(o); return o; };
  const free = o => {
    if (!o) return;
    o.traverse(x => { x.geometry?.dispose(); pickables.delete(x); });
    o.parent?.remove(o);
  };

  // свет: солнце через окна, небо, отражённый свет комнаты
  const sun = new T.DirectionalLight(0xfff1dc, 2.6);
  sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  sun.shadow.bias = -0.0004; sun.shadow.normalBias = 0.03; sun.shadow.radius = 4;
  const sc = sun.shadow.camera, half = span / 2 + 1.5;
  sc.left = sc.bottom = -half; sc.right = sc.top = half; sc.near = 0.5; sc.far = 40;
  scene.add(sun, sun.target);
  const hemi = new T.HemisphereLight(0xe8f0fb, 0x9c8a74, 0.35);
  scene.add(hemi);
  {   // солнце светит в стену с самыми большими окнами
    let best = null, area = 0;
    for (const W of room.live) { const a = W.holes.filter(h => h.kind === "window").reduce((s, h) => s + (h.u1 - h.u0) * (h.v1 - h.v0), 0); if (a > area) { area = a; best = W; } }
    const nx = best ? best.nx : -0.5, ny = best ? best.ny : 0.7, tx = best ? -ny : 1, ty = best ? nx : 0;
    sun.target.position.set(cx, 0, cy);
    sun.position.set(cx - nx * 8 + tx * 3, 6.5, cy - ny * 8 + ty * 3);
  }

  const shell = new T.Group(), furn = new T.Group(), lamps = new T.Group(), helpers = new T.Group();
  scene.add(shell, furn, lamps, helpers);

  // ---------- пол, потолок, тень на «чертеже» ----------
  const shape = new T.Shape(room.poly.map(([x, y]) => new T.Vector2(x, -y)));
  const floor = tag(new T.Mesh(new T.ShapeGeometry(shape), null), { type: "floor" });
  floor.rotation.x = -PI / 2; floor.receiveShadow = true;
  const ceiling = tag(new T.Mesh(new T.ShapeGeometry(shape), null), { type: "ceiling" });
  ceiling.rotation.x = -PI / 2; ceiling.position.y = H; ceiling.castShadow = true; ceiling.receiveShadow = true;
  const ground = new T.Mesh(new T.PlaneGeometry(span * 4, span * 4), new T.ShadowMaterial({ opacity: 0.14 }));
  ground.rotation.x = -PI / 2; ground.position.set(cx, -0.004, cy); ground.receiveShadow = true;
  shell.add(floor, ceiling, ground);

  // ---------- стены: проёмы — дырами, двери — вырезом снизу ----------
  function wallGeo(W, ext) {
    const s = new T.Shape(), doors = W.holes.filter(h => h.kind !== "window");
    s.moveTo(0, 0);
    for (const h of doors) { s.lineTo(h.u0, 0); s.lineTo(h.u0, h.v1); s.lineTo(h.u1, h.v1); s.lineTo(h.u1, 0); }
    s.lineTo(W.len + ext, 0); s.lineTo(W.len + ext, H); s.lineTo(0, H); s.closePath();
    for (const h of W.holes.filter(h => h.kind === "window")) {
      const p = new T.Path(); p.moveTo(h.u0, h.v0); p.lineTo(h.u1, h.v0); p.lineTo(h.u1, h.v1); p.lineTo(h.u0, h.v1); p.closePath();
      s.holes.push(p);
    }
    return new T.ExtrudeGeometry(s, { depth: WALL_T, bevelEnabled: false, curveSegments: 1 });
  }
  const aoMat = (k = 0.26) => mat("ao" + k, () => new T.MeshBasicMaterial({ color: 0x000000, alphaMap: null, map: TX.ao(), transparent: true, opacity: k, depthWrite: false, toneMapped: false }));
  function aoStrip(g, w, h, x, y, z, rx, ry, rz) {
    const m = new T.Mesh(new T.PlaneGeometry(w, h), aoMat());
    m.position.set(x, y, z); m.rotation.set(rx, ry, rz, "YXZ"); m.renderOrder = 1;
    g.add(m);
  }
  function buildWalls() {
    for (const W of room.live) {
      // угол наружу выпуклый — продлеваем стену на толщину, чтобы углы были сплошными
      let ext = 0;
      for (const N of room.live) {
        if (N === W || Math.hypot(N.a[0] - W.b[0], N.a[1] - W.b[1]) > 0.3) continue;
        if (N.dx * W.nx + N.dy * W.ny > 0.3) ext = WALL_T;
      }
      const g = new T.Group();
      g.position.set(W.a[0], 0, W.a[1]); g.rotation.y = Math.atan2(-W.dy, W.dx);
      const m = tag(new T.Mesh(wallGeo(W, ext), [null, null]), { type: "wall", i: W.i });
      m.castShadow = m.receiveShadow = true;
      const decor = new T.Group(), dress = new T.Group(), sky = new T.Group();
      g.add(m, decor, dress, sky);
      shell.add(g);
      wallParts.push({ W, g, m, decor, dress, sky, cut: false });
      // затенение у пола, у потолка и в углах
      aoStrip(decor, W.len, 0.34, W.len / 2, 0.003, -0.17, -PI / 2, 0, 0);
      aoStrip(decor, W.len, 0.3, W.len / 2, 0.15, -0.003, 0, PI, 0);
      aoStrip(decor, W.len, 0.3, W.len / 2, H - 0.15, -0.003, 0, PI, PI);
      aoStrip(decor, H, 0.28, 0.14, H / 2, -0.004, 0, PI, PI / 2);
      aoStrip(decor, H, 0.28, W.len - 0.14, H / 2, -0.004, 0, PI, -PI / 2);
    }
  }
  function buildOpenings() {   // плинтус, наличники, двери, окна, батареи, вид за окном
    for (const P of wallParts) {
      P.decor.children.filter(o => !(o.material?.map === TX.ao())).forEach(free);
      P.sky.children.slice().forEach(free);
      const { W, decor, sky } = P, trim = std(pal.trim, 0.45), classic = L.style === "classic";
      const sk = classic ? 0.12 : 0.07;
      let u = 0;
      for (const h of [...W.holes.filter(h => h.kind !== "window"), { u0: W.len, u1: W.len }]) {
        if (h.u0 - u > 0.05) box(decor, h.u0 - u, sk, 0.016, trim, (u + h.u0) / 2, 0, -0.008);
        u = h.u1 + (h.kind ? 0.07 : 0);
      }
      if (classic) box(decor, W.len, 0.08, 0.05, trim, W.len / 2, H - 0.08, -0.025, 0.01);   // карниз
      for (const h of W.holes) {
        const w = h.u1 - h.u0, mid = (h.u0 + h.u1) / 2, hh = h.v1 - h.v0;
        if (h.kind === "window") {
          const zf = WALL_T * 0.45, frame = std(pal.trim === "#1f1f21" ? "#1f1f21" : "#f7f7f5", 0.4), wg = new T.Group();
          decor.add(wg); tag(wg, { type: "window", i: W.i });
          box(wg, w, 0.06, 0.07, frame, mid, h.v0, zf); box(wg, w, 0.06, 0.07, frame, mid, h.v1 - 0.06, zf);
          box(wg, 0.06, hh, 0.07, frame, h.u0 + 0.03, h.v0, zf); box(wg, 0.06, hh, 0.07, frame, h.u1 - 0.03, h.v0, zf);
          const n = Math.max(1, Math.round(w / 0.75));
          for (let k = 1; k < n; k++) box(wg, 0.07, hh - 0.1, 0.07, frame, h.u0 + w * k / n, h.v0 + 0.05, zf);
          const gl = mesh(wg, new T.PlaneGeometry(w - 0.1, hh - 0.1), glassM(), mid, h.v0 + hh / 2, zf + 0.01);
          gl.castShadow = false; gl.rotation.y = PI;
          box(wg, w + 0.12, 0.03, zf + 0.09, std("#f5f4f1", 0.35), mid, h.v0 - 0.03, (zf - 0.09) / 2, 0.006);   // подоконник
          h.rad = null;
          if (h.v0 > 0.6) {   // батарея под окном
            const rw = Math.min(w * 0.8, 1.2), rad = h.rad = new T.Group(); rad.position.set(mid, 0.14, -0.06); decor.add(rad);
            for (let k = 0, n2 = Math.round(rw / 0.08); k < n2; k++) box(rad, 0.06, Math.min(0.5, h.v0 - 0.3), 0.07, std("#f2f2f0", 0.35), -rw / 2 + (k + 0.5) * rw / n2, 0, 0, 0.01);
          }
          const s = new T.Mesh(new T.PlaneGeometry(w + 1.6, hh + 1.2), mat("sky", () => new T.MeshBasicMaterial({ map: TX.sky(), color: new T.Color(1.6, 1.6, 1.6) })));
          s.position.set(mid, h.v0 + hh / 2, WALL_T + 0.9); s.rotation.y = PI;
          sky.add(s);
        } else {
          for (const [x, y, ww, hh2] of [[h.u0 - 0.035, 0, 0.07, h.v1 + 0.07], [h.u1 + 0.035, 0, 0.07, h.v1 + 0.07], [mid, h.v1, w + 0.14, 0.07]])
            box(decor, ww, hh2, 0.014, trim, x, y, -0.007);
          if (h.kind === "door") {
            const leaf = new T.Group(); leaf.position.set(mid, 0, WALL_T / 2); decor.add(leaf);
            const dm = std(pal.door, 0.5);
            box(leaf, w - 0.02, h.v1 - 0.01, 0.04, dm, 0, 0, 0, 0.004);
            if (classic) for (const y of [0.15, h.v1 * 0.52]) box(leaf, w - 0.2, h.v1 * 0.38, 0.012, dm, 0, y, -0.025, 0.01);
            const hx = w / 2 - 0.08;
            for (const z of [-0.03, 0.03]) { box(leaf, 0.13, 0.018, 0.018, metal(pal.metal === "#141417" ? "#1a1a1a" : pal.metal), hx - 0.05, 0.99, z, 0.006); }
          } else {   // проём без двери: за ним коридор
            const cor = new T.Mesh(new T.BoxGeometry(w + 0.6, h.v1 + 0.3, 1.6), std("#e9e6e0", 0.9, 0, { side: T.BackSide }));
            cor.position.set(mid, (h.v1 + 0.3) / 2, WALL_T + 0.8); cor.receiveShadow = true;
            sky.add(cor);
          }
        }
      }
      sky.visible = mode === "room" && !P.cut;
    }
  }
  function buildCurtains() {
    for (const P of wallParts) {
      P.dress.children.slice().forEach(free);
      const kind = L.curtains;
      if (kind === "none") continue;
      const cm = fabric(pal.curtain);
      for (const h of P.W.holes.filter(h => h.kind === "window")) {
        const w = h.u1 - h.u0, mid = (h.u0 + h.u1) / 2, g = new T.Group();
        tag(g, { type: "window", i: P.W.i });
        P.dress.add(g);
        if (kind === "curtains") {
          const top = Math.min(H - 0.05, h.v1 + 0.22), rodW = w + 0.7;
          const rod = mesh(g, new T.CylinderGeometry(0.012, 0.012, rodW, 12), metal(pal.metal), mid, top, -0.12); rod.rotation.z = PI / 2;
          const pw = Math.max(0.4, w * 0.32), ph = top - 0.02;
          for (const s of [-1, 1]) {   // две шторы в складку
            const geo = new T.PlaneGeometry(pw, ph, 36, 1), p = geo.attributes.position;
            for (let k = 0; k < p.count; k++) p.setZ(k, Math.sin((p.getX(k) / pw + 0.5) * PI * 9) * 0.035);
            geo.computeVertexNormals();
            const c = mesh(g, geo, mat("curt" + pal.curtain, () => { const m = cm.clone(); m.side = T.DoubleSide; return m; }), mid + s * (w / 2 + 0.35 - pw / 2), 0.02 + ph / 2, -0.15);
            c.rotation.y = PI;
          }
          const tul = new T.PlaneGeometry(w + 0.4, ph, 48, 1), q = tul.attributes.position;   // тюль
          for (let k = 0; k < q.count; k++) q.setZ(k, Math.sin(q.getX(k) * 26) * 0.02);
          tul.computeVertexNormals();
          const t = mesh(g, tul, mat("tulle", () => new T.MeshStandardMaterial({ color: "#ffffff", roughness: 0.9, transparent: true, opacity: 0.38, side: T.DoubleSide, depthWrite: false })), mid, 0.02 + ph / 2, -0.09);
          t.rotation.y = PI; t.castShadow = false;
        } else if (kind === "blinds") {
          const bh = (h.v1 - h.v0) * 0.55, bm = mat("blinds" + pal.curtain, () => new T.MeshStandardMaterial({ map: TX.blinds(pal.curtain), roughness: 0.5 }));
          const geo = new T.PlaneGeometry(w - 0.08, bh);
          const b = mesh(g, geo, bm, mid, h.v1 - 0.04 - bh / 2, WALL_T * 0.45 - 0.03);
          b.rotation.y = PI;
          const tx = bm.map; tx.repeat.set(1, bh / 0.05);
          box(g, w - 0.06, 0.04, 0.05, std("#f2f2f0", 0.4), mid, h.v1 - 0.05, WALL_T * 0.45 - 0.03);
        } else {   // римская штора: верх окна, мягкие складки
          const top = h.v1 + 0.08, n = 4, fw = w + 0.12;
          box(g, fw, (h.v1 - h.v0) * 0.28, 0.02, cm, mid, top - (h.v1 - h.v0) * 0.28, -0.03, 0.008);
          for (let k = 0; k < n; k++) box(g, fw, 0.07, 0.06, cm, mid, top - (h.v1 - h.v0) * 0.28 - 0.035 + k * 0.05, -0.05, 0.03);
        }
      }
    }
  }
  function paintShell() {
    const accent = L.accent;
    for (const P of wallParts) {
      const s = accent && accent.wall === P.W.i ? accent : L.wall;
      P.m.material = [surfaceMat("wall", s.finish, s.color, s.pattern), std("#efece6", 0.9)];
    }
    floor.material = surfaceMat("floor", L.floor.finish, L.floor.color);
    ceiling.material = mat("ceil" + L.ceiling.color, () => new T.MeshStandardMaterial({ map: TX.paint(L.ceiling.color), roughness: 0.95, side: T.BackSide }));
  }

  // ---------- свет на потолке ----------
  function lampCenter() {
    for (const [, it] of items) {
      const s = it.spec;
      if (!s.hidden && s.kind === "table" && ["dining_rect", "dining_round"].includes(s.variant)) return [s.x, s.y, s];
    }
    return [cx, cy, null];
  }
  function buildLights() {
    lamps.children.slice().forEach(free);
    const g = new T.Group(); lamps.add(g); tag(g, { type: "ceiling" });
    const kind = L.ceiling.light, [lx, ly, table] = lampCenter(), warm = 0xffd29a;
    const brass = metal(L.style === "classic" ? "#c79e54" : pal.metal), bulb = glow();
    const point = (x, y, z, k = 9) => { const l = new T.PointLight(warm, k, 0, 2); l.position.set(x, y, z); g.add(l); };
    const cable = (x, z, top, bottom) => cyl(g, 0.003, 0.003, top - bottom, std("#1b1b1b", 0.6), x, bottom, z, 6);
    if (kind === "chandelier_classic") {
      const y0 = H - 0.62;
      cable(lx, ly, H, y0 + 0.25);
      mesh(g, new T.LatheGeometry([[0, 0], [0.06, 0.03], [0.04, 0.12], [0.07, 0.2], [0, 0.26]].map(p => new T.Vector2(...p)), 24), brass, lx, y0, ly);
      for (let k = 0; k < 6; k++) {
        const a = k * PI / 3, x = lx + Math.cos(a) * 0.3, z = ly + Math.sin(a) * 0.3;
        const arm = mesh(g, new T.TorusGeometry(0.15, 0.008, 8, 16, PI), brass, lx + Math.cos(a) * 0.15, y0 + 0.06, ly + Math.sin(a) * 0.15);
        arm.rotation.set(0, -a, PI);
        cyl(g, 0.025, 0.02, 0.04, brass, x, y0 + 0.05, z, 12);
        cyl(g, 0.009, 0.009, 0.08, std("#f6f1e4", 0.6), x, y0 + 0.09, z, 8);
        ball(g, 0.016, bulb, x, y0 + 0.19, z, 1, 1.6, 1);
        mesh(g, new T.OctahedronGeometry(0.018), mat("crys", () => new T.MeshStandardMaterial({ color: "#ffffff", roughness: 0.02, metalness: 0.3, transparent: true, opacity: 0.7 })), x, y0 - 0.03, z);
      }
      point(lx, y0 + 0.12, ly, 14);
    } else if (kind === "chandelier_modern") {
      const y0 = H - 0.6, r = rng(4);
      cable(lx, ly, H, y0);
      ball(g, 0.05, brass, lx, y0, ly);
      for (let k = 0; k < 12; k++) {
        const th = r() * 2 * PI, ph = Math.acos(r() * 1.6 - 0.8), dx = Math.sin(ph) * Math.cos(th), dy = Math.cos(ph), dz = Math.sin(ph) * Math.sin(th), l = 0.26 + r() * 0.08;
        const rod = mesh(g, new T.CylinderGeometry(0.005, 0.005, l, 6), brass, lx + dx * l / 2, y0 + dy * l / 2, ly + dz * l / 2);
        rod.quaternion.setFromUnitVectors(new T.Vector3(0, 1, 0), new T.Vector3(dx, dy, dz));
        ball(g, 0.028, bulb, lx + dx * l, y0 + dy * l, ly + dz * l);
      }
      point(lx, y0, ly, 14);
    } else if (kind === "pendant") {
      const n = table ? clamp(Math.round(table.width / 0.7), 1, 3) : 1, low = table ? (table.height || 0.75) + 0.75 : H - 0.85;
      const ang = table ? table.angle : 0, paper = L.style === "japandi";
      for (let k = 0; k < n; k++) {
        const t = (k - (n - 1) / 2) * 0.55, x = lx + Math.cos(ang) * t, z = ly + Math.sin(ang) * t, y = Math.max(low, 1.6);
        cable(x, z, H, y + 0.18);
        if (paper) ball(g, 0.2, mat("paper", () => new T.MeshStandardMaterial({ color: "#fbf6ec", emissive: "#ffd9a8", emissiveIntensity: 0.9, roughness: 1 })), x, y + 0.02, z, 1, 0.9, 1);
        else {
          const sh = mesh(g, new T.CylinderGeometry(0.035, 0.17, 0.2, 32, 1, true), mat("shade" + pal.metal, () => new T.MeshStandardMaterial({ color: pal.metal, roughness: 0.35, metalness: 0.7, side: T.DoubleSide })), x, y + 0.1, z);
          sh.castShadow = false;
          ball(g, 0.035, bulb, x, y + 0.03, z);
        }
        point(x, y - 0.05, z, 7);
      }
    } else if (kind === "spots") {
      const nx = clamp(Math.round((bx1 - bx0) / 1.3), 2, 4), ny = clamp(Math.round((by1 - by0) / 1.3), 2, 3);
      let lit = 0;
      for (let i = 0; i < nx; i++) for (let j = 0; j < ny; j++) {
        const x = bx0 + (bx1 - bx0) * (i + 0.5) / nx, z = by0 + (by1 - by0) * (j + 0.5) / ny;
        if (!inPoly(room.poly, x, z)) continue;
        cyl(g, 0.045, 0.045, 0.008, std("#f4f4f2", 0.4), x, H - 0.008, z, 24);
        cyl(g, 0.03, 0.03, 0.004, glow("#fff1d8", 4), x, H - 0.011, z, 20);
        if ((i + j) % 2 === 0 && lit++ < 4) {
          const s = new T.SpotLight(0xffe7c4, 16, 0, 1.0, 0.9, 2); s.position.set(x, H - 0.02, z); s.target.position.set(x, 0, z);
          g.add(s, s.target);
        }
      }
    } else if (kind === "track") {
      const len = Math.min(3, (bx1 - bx0) * 0.6);
      box(g, len, 0.035, 0.045, std("#161616", 0.4, 0.4), cx, H - 0.035, cy);
      for (let k = 0; k < 4; k++) {
        const x = cx - len / 2 + len * (k + 0.5) / 4, hd = new T.Group(); hd.position.set(x, H - 0.05, cy); g.add(hd);
        const c = mesh(hd, new T.CylinderGeometry(0.035, 0.035, 0.12, 20), std("#161616", 0.4, 0.4), 0, -0.07, 0); c.rotation.x = k % 2 ? 0.5 : -0.5;
        ball(hd, 0.026, bulb, 0, -0.12, k % 2 ? 0.03 : -0.03, 1, 0.3, 1);
        if (k < 3) {
          const s = new T.SpotLight(0xffe2b8, 18, 0, 0.8, 0.8, 2); s.position.set(x, H - 0.1, cy);
          s.target.position.set(x, 0.3, cy + (k % 2 ? 1.6 : -1.6)); g.add(s, s.target);
        }
      }
    } else if (kind === "ring") {
      const y0 = H - 0.55, R = clamp(span * 0.06, 0.28, 0.45);
      for (let k = 0; k < 3; k++) { const a = k * 2 * PI / 3; cable(lx + Math.cos(a) * R, ly + Math.sin(a) * R, H, y0); }
      const t = mesh(g, new T.TorusGeometry(R, 0.018, 12, 64), glow("#fff4e2", 2.2), lx, y0, ly); t.rotation.x = PI / 2;
      point(lx, y0 - 0.05, ly, 12);
    }
    g.traverse(o => { if (o.isMesh) o.castShadow = false; });
  }

  // ---------- мебель ----------
  const objs = scan.objects || [];
  function flipOf(o, kind, variant) {   // спинкой к ближней стене, стулья — лицом к столу
    const a = o.angle || 0, vx = -Math.sin(a), vy = Math.cos(a);
    if (kind === "chair" && variant !== "armchair") {
      let best = null;
      for (const t of objs) if (t.kind === "table") { const d = Math.hypot(t.x - o.x, t.y - o.y); if (d < 1.6 && (!best || d < best.d)) best = { d, t }; }
      if (best) return (best.t.x - o.x) * vx + (best.t.y - o.y) * vy < 0;
    }
    if (!againstWall(kind, variant) && kind !== "chair") return false;
    return cast(o.x, o.y, vx, vy, room.segs) < cast(o.x, o.y, -vx, -vy, room.segs);
  }
  const flips = objs.map(o => flipOf(o, o.kind, defaultVariant(o)));
  function specOf(key) {
    if (key[0] === "o") {
      const i = +key.slice(1), o = objs[i], ch = L.objects[String(i)] || {};
      const kind = TITLES[o.kind] ? o.kind : "object", vs = VARIANTS[kind];
      const variant = vs && vs.some(v => v[0] === ch.variant) ? ch.variant : defaultVariant(o);
      return { key, i, kind, variant, color: ch.color || defaultColor(kind, variant, pal), hidden: !!ch.hidden,
        width: o.width || 0.5, depth: o.depth || 0.5, height: o.height || 0.8, x: o.x || 0, y: o.y || 0, angle: o.angle || 0, flip: flips[i] };
    }
    const j = +key.slice(1), a = L.added[j];
    return { key, j, added: true, ...a, flip: false };
  }
  function supportOf(s) {   // телевизор — на тумбу или стол под ним
    for (const [k, it] of items) {
      const o = it.spec;
      if (k === s.key || o.hidden || o.kind === "television" || !it.top || it.top > 1.3) continue;
      const c = corners(o.x, o.y, o.width, o.depth, o.angle);
      if (inPoly(c, s.x, s.y)) return it.top;
    }
    return null;
  }
  function buildItem(key) {
    const old = items.get(key);
    free(old?.group);
    const s = specOf(key), g = new T.Group();
    g.position.set(s.x, 0, s.y); g.rotation.y = -s.angle + (s.flip ? PI : 0);
    tag(g, s.added ? { type: "added", j: s.j } : { type: "obj", i: s.i });
    const it = { group: g, spec: s, top: 0 };
    items.set(key, it);
    furn.add(g);
    if (s.hidden) {   // убранная мебель: контур, чтобы можно было вернуть
      const b = new T.Mesh(new T.BoxGeometry(s.width, s.height, s.depth), mat("ghost", () => new T.MeshBasicMaterial({ color: 0x3d6fae, transparent: true, opacity: 0.08, depthWrite: false })));
      b.position.y = s.height / 2; g.add(b);
      const e = new T.LineSegments(new T.EdgesGeometry(b.geometry), mat("ghostE", () => new T.LineDashedMaterial({ color: 0x3d6fae, dashSize: 0.06, gapSize: 0.05, transparent: true, opacity: 0.8 })));
      e.position.y = s.height / 2; e.computeLineDistances(); g.add(e);
      e.raycast = () => {};   // нажимают на сам прозрачный короб; у линий зона касания — целый метр
      g.userData.ghost = true;
      need();
      return it;
    }
    const soft = isSoft(s.kind, s.variant), leather = pal.leather && (s.kind === "sofa" || s.variant === "armchair");
    const C = {
      pal, color: s.color,
      main: soft ? fabric(s.color, leather) : ["table", "storage", "chair", "stairs"].includes(s.kind) ? wood(s.color)
        : ["sink", "toilet", "bathtub", "fireplace"].includes(s.kind) ? ceramic(s.color) : appliance(s.color),
      woodM: wood(pal.wood), leg: L.style === "loft" || L.style === "modern" ? metal(pal.metal) : wood(pal.wood),
      metalM: metal(L.style === "classic" ? "#c79e54" : pal.metal === "#b8babf" ? "#9ea1a6" : pal.metal),
      dark: std(hexOf(tone(s.color, -0.55)), 0.7), accent: fabric(pal.accent), accentM: fabric(pal.accent),
      bedding: fabric(pal.bedding), duvet: fabric(hexOf(tone(pal.bedding, -0.04))), pad: fabric(pal.fabric),
      cab: wood(pal.wood), onFurniture: false, underWindow: windowsBehind(s).length > 0,
    };
    if (s.kind === "television") {
      const sup = supportOf(s);
      C.onFurniture = sup !== null;
      g.position.y = sup !== null ? sup + 0.09 : 0.85;
    }
    (BUILD[s.kind] || BUILD.object)(g, s.width, s.depth, s.height, s.variant, C);
    const bb = new T.Box3(), rot = g.rotation.y, pos = g.position.clone();
    g.rotation.y = 0; g.position.set(0, 0, 0); g.updateMatrixWorld(true); bb.setFromObject(g);
    g.rotation.y = rot; g.position.copy(pos); g.updateMatrixWorld(true);
    it.top = bb.max.y; it.box = bb;
    // мягкая тень на полу
    if (g.position.y < 0.05) {
      const sh = new T.Mesh(new T.PlaneGeometry(s.width + 0.3, s.depth + 0.3), mat("cshadow", () => new T.MeshBasicMaterial({ map: TX.shadow(), color: 0x000000, transparent: true, opacity: 0.5, depthWrite: false, toneMapped: false })));
      sh.rotation.x = -PI / 2; sh.position.y = 0.004; sh.renderOrder = 1; g.add(sh);
      sh.castShadow = sh.receiveShadow = false;
    }
    if (grow < 1) g.visible = false;
    need();
    return it;
  }
  function buildItems() {
    for (const [, it] of items) free(it.group);
    items.clear();
    const keys = objs.map((_, i) => "o" + i).concat(L.added.map((_, j) => "a" + j));
    keys.sort((a, b) => (specOf(a).kind === "television") - (specOf(b).kind === "television"));
    keys.forEach(buildItem);
  }
  function placeTVs() {
    for (const [k, it] of items) if (it.spec.kind === "television" && !it.spec.hidden) buildItem(k);
  }
  // окна, под которыми вещь стоит спиной к стене (до 25 см от неё)
  function windowsBehind(s) {
    const out = [];
    for (const W of room.live) {
      const ux = s.x - W.a[0], uy = s.y - W.a[1], along = ux * W.dx + uy * W.dy, off = ux * W.nx + uy * W.ny;
      const turn = Math.abs(Math.sin(s.angle - Math.atan2(W.dy, W.dx)));   // 0 — ширина вдоль стены
      if (turn > 0.3 && turn < 0.95) continue;
      const half = turn < 0.3 ? s.depth / 2 : s.width / 2, side = turn < 0.3 ? s.width / 2 : s.depth / 2;
      if (off < 0 || off - half > 0.25) continue;
      for (const h of W.holes) if (h.kind === "window" && along - side < h.u1 - 0.05 && along + side > h.u0 + 0.05) out.push(h);
    }
    return out;
  }
  function radiators() {   // батарея под окном пропадает за мебелью, поставленной туда
    const behind = new Set();
    for (const [, it] of items) if (!it.spec.hidden) windowsBehind(it.spec).forEach(h => behind.add(h));
    for (const W of room.live) for (const h of W.holes) if (h.rad) h.rad.visible = !behind.has(h);
  }
  // примерки не копим: текстуры и материалы, которых в комнате больше нет, отдаём (холст 1024² — 4 МБ)
  const SHARED = new Set(["weave", "grain", "shadow", "ao", "sky"]);
  const drop = t => { t.dispose(); if (t.image) t.image.width = t.image.height = 0; };
  function sweep() {
    const used = new Set(), maps = new Set();
    scene.traverse(o => { for (const m of [].concat(o.material || [])) if (m) used.add(m); });
    for (const m of used) for (const k of ["map", "bumpMap", "alphaMap"]) if (m[k]) maps.add(m[k]);
    for (const [k, m] of MAT) if (!used.has(m)) { m.dispose(); MAT.delete(k); }
    for (const [k, t] of TEX) if (!SHARED.has(k) && !maps.has(t)) { drop(t); TEX.delete(k); }
  }

  // ---------- выделение ----------
  const selMat = new T.LineBasicMaterial({ color: 0xf5c518, depthTest: false, transparent: true });
  const selFill = new T.MeshBasicMaterial({ color: 0xf5c518, transparent: true, opacity: 0.13, depthWrite: false, depthTest: true, side: T.DoubleSide });
  function drawSel() {
    clearOutlines();
    if (!sel) return need();
    const add = (o, parent = helpers) => { o.renderOrder = 5; o.userData.outline = true; parent.add(o); };
    if (sel.type === "obj" || sel.type === "added") {
      const it = items.get(sel.type === "obj" ? "o" + sel.i : "a" + sel.j);
      if (!it) return need();
      const s = it.spec;
      const b = it.box && !s.hidden ? it.box : new T.Box3(new T.Vector3(-s.width / 2, 0, -s.depth / 2), new T.Vector3(s.width / 2, s.height, s.depth / 2));
      const geo = new T.BoxGeometry(b.max.x - b.min.x + 0.04, b.max.y - b.min.y + 0.03, b.max.z - b.min.z + 0.04);
      const c = new T.Vector3(); b.getCenter(c);
      const e = new T.LineSegments(new T.EdgesGeometry(geo), selMat); e.position.copy(c); add(e, it.group);
      const f = new T.Mesh(geo, selFill); f.position.copy(c); add(f, it.group);
    } else if (sel.type === "wall") {
      const P = wallParts.find(p => p.W.i === sel.i);
      if (!P) return need();
      const hh = P.cut ? CUT : H, geo = new T.PlaneGeometry(P.W.len, hh);
      const f = new T.Mesh(geo, selFill); f.position.set(P.W.len / 2, hh / 2, -0.01); add(f, P.g);
      const e = new T.LineSegments(new T.EdgesGeometry(geo), selMat); e.position.copy(f.position); add(e, P.g);
    } else if (sel.type === "floor" || sel.type === "ceiling") {
      const y = sel.type === "floor" ? 0.012 : H - 0.012;
      const f = new T.Mesh(new T.ShapeGeometry(shape), selFill); f.rotation.x = -PI / 2; f.position.y = y; add(f);
      const pts = room.poly.concat([room.poly[0]]).map(([x, z]) => new T.Vector3(x, y, z));
      add(new T.Line(new T.BufferGeometry().setFromPoints(pts), selMat));
      if (sel.type === "ceiling" && lamps.children[0]) {
        const b = new T.Box3().setFromObject(lamps.children[0]);
        if (!b.isEmpty()) { const c = new T.Vector3(), s = new T.Vector3(); b.getCenter(c); b.getSize(s); const e = new T.LineSegments(new T.EdgesGeometry(new T.BoxGeometry(s.x + 0.06, s.y + 0.06, s.z + 0.06)), selMat); e.position.copy(c); add(e); }
      }
    } else if (sel.type === "window") {
      const P = wallParts.find(p => p.W.i === sel.i);
      if (P) for (const h of P.W.holes.filter(h => h.kind === "window")) {
        const geo = new T.PlaneGeometry(h.u1 - h.u0 + 0.1, h.v1 - h.v0 + 0.1);
        const e = new T.LineSegments(new T.EdgesGeometry(geo), selMat); e.position.set((h.u0 + h.u1) / 2, (h.v0 + h.v1) / 2, -0.02); add(e, P.g);
        const f = new T.Mesh(geo, selFill); f.position.copy(e.position); add(f, P.g);
      }
    }
    need();
  }
  function clearOutlines() {
    const drop = parent => parent.children.filter(o => o.userData.outline).forEach(o => { o.geometry?.dispose(); parent.remove(o); });
    drop(helpers);
    for (const [, it] of items) drop(it.group);
    for (const P of wallParts) drop(P.g);
  }

  // ---------- камера: «сверху» (кукольный дом) и «из комнаты» ----------
  const controls = new T.OrbitControls(camera, canvas);
  controls.enableDamping = !reduced; controls.dampingFactor = 0.09;
  controls.maxPolarAngle = 1.32; controls.minPolarAngle = 0.08;
  controls.minDistance = 1.5; controls.maxDistance = span * 3;
  controls.rotateSpeed = 0.75; controls.zoomSpeed = 0.9;
  controls.target.set(cx, 0.7, cy);
  controls.addEventListener("change", need);
  let touched = false;   // пока человек не крутил — при смене размера экрана снова вписываем комнату
  controls.addEventListener("start", () => { touched = true; });
  // точки съёмки: из двери и из углов, смотрим в центр комнаты
  function viewpoints() {
    const out = [], busy = (x, y) => [...items.values()].some(it => !it.spec.hidden && inPoly(corners(it.spec.x, it.spec.y, it.spec.width + 0.2, it.spec.depth + 0.2, it.spec.angle), x, y));
    for (const W of room.live) for (const h of W.holes) if (h.kind !== "window") {
      const u = (h.u0 + h.u1) / 2;
      for (const k of [0.45, 0.8, 1.1]) { const x = W.a[0] + W.dx * u + W.nx * k, y = W.a[1] + W.dy * u + W.ny * k; if (inPoly(room.poly, x, y) && !busy(x, y)) { out.push([x, y]); break; } }
    }
    const corner = [];
    for (const [px, py] of room.poly) {
      const dx = cx - px, dy = cy - py, l = Math.hypot(dx, dy) || 1;
      for (const k of [0.45, 0.8, 1.2, 1.6]) { const x = px + dx / l * k, y = py + dy / l * k; if (inPoly(room.poly, x, y) && !busy(x, y)) { corner.push([x, y, l]); break; } }
    }
    corner.sort((a, b) => b[2] - a[2]).forEach(([x, y]) => { if (!out.some(p => Math.hypot(p[0] - x, p[1] - y) < 0.8)) out.push([x, y]); });
    if (!out.length) out.push([cx + (bx1 - cx) * 0.6, cy + (by1 - cy) * 0.6]);
    return out;
  }
  let views = [], viewIdx = 0, orbitSaved = null;
  const look3 = { yaw: 0, pitch: 0, fov: 70 };
  function roomPose(i) {
    const [x, y] = views[i % views.length], dx = cx - x, dy = cy - y;
    const yaw = Math.atan2(-dx, -dy);
    return { pos: new T.Vector3(x, EYE, y), yaw, pitch: -0.06 };
  }
  function fovFor(aspect) { return clamp(2 * Math.atan(Math.tan(34 * PI / 180) / aspect) * 180 / PI, 52, 94); }
  function applyLook() {
    camera.quaternion.setFromEuler(new T.Euler(look3.pitch, look3.yaw, 0, "YXZ"));
    camera.fov = look3.fov; camera.updateProjectionMatrix();
    need();
  }
  function tween(toPos, toQuat, toFov, ms, done) {
    const p0 = camera.position.clone(), q0 = camera.quaternion.clone(), f0 = camera.fov, t0 = performance.now();
    if (reduced || ms <= 0) { camera.position.copy(toPos); camera.quaternion.copy(toQuat); camera.fov = toFov; camera.updateProjectionMatrix(); done?.(); need(); return; }
    anim = t => {
      const k = Math.min(1, (t - t0) / ms), e = k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
      camera.position.lerpVectors(p0, toPos, e); camera.quaternion.slerpQuaternions(q0, toQuat, e);
      camera.fov = f0 + (toFov - f0) * e; camera.updateProjectionMatrix();
      if (k >= 1) { anim = null; done?.(); }
      return true;
    };
  }
  function setMode(m) {
    return new Promise(res => {
      if (m === mode) return res();
      if (m === "room") {
        orbitSaved = { pos: camera.position.clone(), target: controls.target.clone(), fov: camera.fov };
        controls.enabled = false;
        views = viewpoints();
        const p = roomPose(viewIdx);
        look3.yaw = p.yaw; look3.pitch = p.pitch; look3.fov = fovFor(camera.aspect);
        mode = "room"; setModeLook();
        tween(p.pos, new T.Quaternion().setFromEuler(new T.Euler(p.pitch, p.yaw, 0, "YXZ")), look3.fov, 750, res);
      } else {
        const s = orbitSaved || { pos: new T.Vector3(cx + span, span, cy + span), target: new T.Vector3(cx, 0.7, cy), fov: 50 };
        const m4 = new T.Matrix4().lookAt(s.pos, s.target, new T.Vector3(0, 1, 0));
        mode = "orbit";
        tween(s.pos, new T.Quaternion().setFromRotationMatrix(m4), s.fov, 650, () => { controls.target.copy(s.target); controls.enabled = true; controls.update(); setModeLook(); res(); });
        setModeLook();
      }
    });
  }
  function setModeLook() {   // из комнаты — потолок и вид за окном; сверху — срезанные стены
    const inside = mode === "room";
    ceiling.visible = inside; ground.visible = !inside;
    scene.environmentIntensity = inside ? 0.5 : 0.75;
    hemi.intensity = inside ? 0.28 : 0.4;
    cutWalls(true);
    shadows();
  }
  function cutWalls(force = false) {
    const p = camera.position;
    let changed = false;
    for (const P of wallParts) {
      const { W } = P;
      const mx = (W.a[0] + W.b[0]) / 2, my = (W.a[1] + W.b[1]) / 2;
      const cut = mode === "orbit" && (p.x - mx) * W.nx + (p.z - my) * W.ny < 0;
      if (cut === P.cut && !force) continue;
      P.cut = cut; changed = true;
      P.m.scale.y = (cut ? CUT / H : 1) * Math.max(grow, 0.001);
      P.decor.visible = P.dress.visible = !cut;
      P.sky.visible = mode === "room" && !cut;
    }
    if (changed) { if (sel?.type === "wall") drawSel(); shadows(); }
  }
  function frameOrbit() {   // смотрим со стороны входа, вся комната в кадре и на узком экране
    const [x, y] = views[0] || viewpoints()[0] || [cx + 1, cy + 1];
    let dx = x - cx, dy = y - cy; const l = Math.hypot(dx, dy) || 1; dx /= l; dy /= l;
    camera.fov = 50; camera.updateProjectionMatrix();
    // подбираем расстояние и центр по углам комнаты на экране: пара проходов сходится
    const el = clamp(0.8 + (0.9 - (camera.aspect || 1)) * 0.5, 0.78, 1);   // на высоком экране смотрим круче — комната крупнее
    const dir = new T.Vector3(dx * Math.cos(el), Math.sin(el), dy * Math.cos(el)), tgt = new T.Vector3(cx, 0.5, cy);
    const pts = room.poly.flatMap(([px, py]) => [new T.Vector3(px, 0, py), new T.Vector3(px, H, py)]);
    const hh = Math.tan(camera.fov * PI / 360), q = new T.Vector3(), rt = new T.Vector3(), up = new T.Vector3();
    const top = 1 - Math.min(0.3, 116 / (canvas.clientHeight || 400)) - 0.04, my = (top - 0.94) / 2, ry = (top + 0.94) / 2;   // сверху кнопки
    let dist = span * 1.3;
    for (let k = 0; k < 5; k++) {
      camera.position.copy(tgt).addScaledVector(dir, dist); camera.lookAt(tgt); camera.updateMatrixWorld();
      let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
      for (const p of pts) { q.copy(p).project(camera); x0 = Math.min(x0, q.x); x1 = Math.max(x1, q.x); y0 = Math.min(y0, q.y); y1 = Math.max(y1, q.y); }
      rt.setFromMatrixColumn(camera.matrixWorld, 0); up.setFromMatrixColumn(camera.matrixWorld, 1);
      tgt.addScaledVector(rt, (x0 + x1) / 2 * dist * hh * camera.aspect).addScaledVector(up, ((y0 + y1) / 2 - my) * dist * hh);
      dist = clamp(dist * Math.max((x1 - x0) / 2 / 0.94, (y1 - y0) / 2 / ry), 3, span * 3);
    }
    camera.position.copy(tgt).addScaledVector(dir, dist);
    controls.target.copy(tgt);
    controls.update();
    need();
  }

  // ---------- размер холста ----------
  function resize() {
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    if (mode === "room") { look3.fov = fovFor(camera.aspect); camera.fov = look3.fov; }
    setInsetView();
    camera.updateProjectionMatrix();
    if (mode === "orbit" && !touched && views.length) frameOrbit();
    need();
  }
  let offNow = 0, offTo = 0;   // сдвиг картинки по высоте, едет плавно
  function setInsetView() {   // открыт нижний лист — сдвигаем картинку, чтобы выбранное было посередине над ним
    const w = canvas.clientWidth, h = canvas.clientHeight;
    offTo = 0;
    if (inset > 0 && w && h) {
      offTo = inset / 2;
      const c = selFocus();
      if (c) {
        camera.clearViewOffset(); camera.updateMatrixWorld();
        const q = c.project(camera);
        if (q.z < 1 && Math.abs(q.x) < 1.5) offTo = clamp((1 - q.y) / 2 * h - (h - inset) / 2, -h / 3, inset);
      }
    }
    if (reduced) offNow = offTo;
    applyOffset();
  }
  function applyOffset() {
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (offNow && w && h) camera.setViewOffset(w, h, 0, offNow, w, h);
    else camera.clearViewOffset();
  }
  function selFocus() {   // середина выбранной вещи, стены или окна
    if (!sel || sel.type === "floor" || sel.type === "ceiling") return null;
    const box = new T.Box3(), take = parent => parent.children.forEach(o => { if (o.userData.outline && o.isMesh) box.expandByObject(o); });
    take(helpers); for (const [, it] of items) take(it.group); for (const P of wallParts) take(P.g);
    return box.isEmpty() ? null : box.getCenter(new T.Vector3());
  }
  const ro = new ResizeObserver(resize);
  ro.observe(canvas);
  // телефон может отобрать 3D у страницы (Telegram ушёл в фон, открыли магазин): вернули — заново отражения, тени и кадр
  let lost = false;
  const onLost = e => { e.preventDefault(); lost = true; };
  const onRestored = () => { lost = false; makeEnv(); shadows(); };
  canvas.addEventListener("webglcontextlost", onLost);
  canvas.addEventListener("webglcontextrestored", onRestored);

  // ---------- касания: выбор, перетаскивание, взгляд из комнаты ----------
  const ray = new T.Raycaster(), ndc = new T.Vector2(), plane = new T.Plane(new T.Vector3(0, 1, 0), 0);
  ray.params.Line.threshold = 0.03;   // линии ловят касание в 3 см, а не в метре (по умолчанию)
  function aim(e) {
    const r = canvas.getBoundingClientRect();
    ndc.set((e.clientX - r.left) / r.width * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
  }
  const shown = o => { for (; o; o = o.parent) if (!o.visible) return false; return true; };
  function pickAt(e) {
    aim(e);
    for (const h of ray.intersectObjects([...pickables], true)) {
      let o = h.object;
      if (o.userData.outline || !shown(o)) continue;
      while (o && !o.userData.sel) o = o.parent;
      if (o) return { sel: o.userData.sel, point: h.point };
    }
    return null;
  }
  const ptrs = new Map();
  let down = null, drag = null, pinch = null;
  function onDown(e) {
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (ptrs.size === 2) {
      drag = null; down = null;
      const [a, b] = [...ptrs.values()];
      pinch = { d: Math.hypot(a.x - b.x, a.y - b.y), fov: look3.fov };
      return;
    }
    down = { x: e.clientX, y: e.clientY, t: performance.now(), yaw: look3.yaw, pitch: look3.pitch };
    if (sel?.type === "added") {   // выбранную новую мебель двигаем пальцем по полу
      const hit = pickAt(e);
      if (hit && hit.sel.type === "added" && hit.sel.j === sel.j) {
        const it = items.get("a" + sel.j), p = new T.Vector3();
        if (ray.ray.intersectPlane(plane, p)) {
          drag = { it, dx: it.spec.x - p.x, dy: it.spec.y - p.z, moved: false };
          controls.enabled = false;
          canvas.setPointerCapture?.(e.pointerId);
        }
      }
    }
  }
  function onMove(e) {
    if (ptrs.has(e.pointerId)) ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pinch && mode === "room" && ptrs.size === 2) {
      const [a, b] = [...ptrs.values()];
      look3.fov = clamp(pinch.fov * pinch.d / Math.max(20, Math.hypot(a.x - b.x, a.y - b.y)), 40, 100);
      applyLook();
      return;
    }
    if (drag) {
      aim(e);
      const p = new T.Vector3();
      if (!ray.ray.intersectPlane(plane, p)) return;
      const s = drag.it.spec, a = L.added[s.j];
      const tryAt = (x, y) => corners(x, y, s.width, s.depth, s.angle).every(q => inPoly(room.poly, q[0], q[1]));
      let x = p.x + drag.dx, y = p.z + drag.dy;
      if (!tryAt(x, y)) { if (tryAt(x, s.y)) y = s.y; else if (tryAt(s.x, y)) x = s.x; else return; }
      s.x = a.x = x; s.y = a.y = y;
      drag.it.group.position.set(x, drag.it.group.position.y, y);
      drag.moved = true;
      need();
      return;
    }
    if (down && mode === "room" && !anim) {
      const k = 0.0042 * (look3.fov / 70);
      look3.yaw = down.yaw + (e.clientX - down.x) * k;
      look3.pitch = clamp(down.pitch + (e.clientY - down.y) * k, -0.75, 0.6);
      applyLook();
    }
  }
  function onUp(e) {
    ptrs.delete(e.pointerId);
    if (ptrs.size < 2) pinch = null;
    if (drag) {
      const moved = drag.moved;
      drag = null; controls.enabled = mode === "orbit" && !anim;
      if (moved) { placeTVs(); radiators(); drawSel(); shadows(); onChange?.(clone(L)); down = null; return; }
    }
    if (!down) return;
    const tap = Math.hypot(e.clientX - down.x, e.clientY - down.y) < 8 && performance.now() - down.t < 450;
    down = null;
    if (!tap) return;
    const hit = pickAt(e);
    const s = hit ? hit.sel : null;
    if (s && s.type === "door") return;
    select(s);
    onPick?.(s);
  }
  canvas.addEventListener("pointerdown", onDown, { capture: true });
  addEventListener("pointermove", onMove);
  addEventListener("pointerup", onUp);
  addEventListener("pointercancel", onUp);

  function select(s) {
    sel = s ? { ...s } : null;
    drawSel();
  }

  // ---------- изменения ремонта: перестраиваем только то, что поменялось ----------
  function apply(next, first = false) {
    const prev = first ? null : L, S = JSON.stringify;
    L = resolveLook(next);
    const styled = !prev || prev.style !== L.style;
    pal = STYLES[L.style].pal;
    if (styled || S(prev.wall) !== S(L.wall) || S(prev.accent) !== S(L.accent) || S(prev.floor) !== S(L.floor) || prev.ceiling.color !== L.ceiling.color) paintShell();
    if (styled) buildOpenings();
    if (styled || prev.curtains !== L.curtains) buildCurtains();
    if (styled) buildItems();
    else {
      let tv = false;
      objs.forEach((_, i) => { if (S(prev.objects[i] || {}) !== S(L.objects[i] || {})) { buildItem("o" + i); tv = true; } });
      const n = Math.max(prev.added.length, L.added.length);
      for (let j = 0; j < n; j++) {
        if (j >= L.added.length) { free(items.get("a" + j)?.group); items.delete("a" + j); tv = true; }
        else if (S(prev.added[j]) !== S(L.added[j])) { buildItem("a" + j); tv = true; }
      }
      if (tv) placeTVs();
    }
    if (styled || prev.ceiling.light !== L.ceiling.light || S(prev.added) !== S(L.added) || S(prev.objects) !== S(L.objects)) buildLights();
    radiators();
    if (sel) drawSel();
    sweep();
    shadows();
  }

  // свободное место для новой мебели: у стены спинкой к ней или посреди комнаты, не на проходе у двери
  function spotFor(kind, variant, w, d, h) {
    const obst = [];
    for (const [, it] of items) if (!it.spec.hidden) obst.push(corners(it.spec.x, it.spec.y, it.spec.width, it.spec.depth, it.spec.angle));
    for (const W of room.live) for (const hl of W.holes) {
      const deep = hl.kind === "door" ? 0.9 : hl.kind === "window" ? (h > hl.v0 ? 0.3 : 0) : 0.6;
      if (!deep) continue;
      const u = (hl.u0 + hl.u1) / 2;
      obst.push(corners(W.a[0] + W.dx * u + W.nx * deep / 2, W.a[1] + W.dy * u + W.ny * deep / 2, hl.u1 - hl.u0, deep, Math.atan2(W.dy, W.dx)));
    }
    const wallish = againstWall(kind, variant), cands = [];
    if (wallish) for (const W of room.live) {
      if (W.len < w + 0.1) continue;
      for (let s = w / 2 + 0.05; s <= W.len - w / 2 - 0.05 + 1e-6; s += 0.1)
        cands.push([W.a[0] + W.dx * s + W.nx * (d / 2 + 0.03), W.a[1] + W.dy * s + W.ny * (d / 2 + 0.03), Math.atan2(-W.nx, W.ny)]);
    } else for (let x = bx0 + w / 2; x <= bx1 - w / 2; x += 0.15) for (let y = by0 + d / 2; y <= by1 - d / 2; y += 0.15) cands.push([x, y, 0]);
    const t = controls.target, grow2 = wallish ? 0 : 0.3;
    let best = null;
    for (const [x, y, a] of cands) {
      if (!corners(x, y, w, d, a).every(p => inPoly(room.poly, p[0], p[1]))) continue;
      const box2 = corners(x, y, w + grow2 * 2, d + grow2 * 2, a);
      if (obst.some(o => overlap(o, box2))) continue;
      const score = Math.hypot(x - t.x, y - t.z) + (wallish ? 0 : Math.hypot(x - cx, y - cy) * 0.5);
      if (!best || score < best.score) best = { x, y, angle: a, score };
    }
    return best ? { x: best.x, y: best.y, angle: best.angle } : { x: cx, y: cy, angle: 0, tight: true };
  }
  function orient(x, y, w, d, a) {   // спинкой к ближней стене
    const vx = -Math.sin(a), vy = Math.cos(a);
    return cast(x, y, vx, vy, room.segs) < cast(x, y, -vx, -vy, room.segs) ? a + PI : a;
  }

  // ---------- кадр для фото «как в жизни» ----------
  function snapshot(long = 1280) {
    const w = canvas.clientWidth, h = canvas.clientHeight, pr = renderer.getPixelRatio();
    const hide = [helpers, ...[...items.values()].filter(it => it.spec.hidden).map(it => it.group)];
    for (const [, it] of items) it.group.children.filter(o => o.userData.outline).forEach(o => hide.push(o));
    for (const P of wallParts) P.g.children.filter(o => o.userData.outline).forEach(o => hide.push(o));
    const was = hide.map(o => o.visible);
    hide.forEach(o => { o.visible = false; });
    camera.clearViewOffset(); camera.updateProjectionMatrix();
    renderer.setPixelRatio(long / Math.max(w, h)); renderer.setSize(w, h, false);
    renderer.setClearColor(0xe6ecf2, 1);
    renderer.shadowMap.needsUpdate = true;
    renderer.render(scene, camera);
    const url = canvas.toDataURL("image/jpeg", 0.9);
    renderer.setClearColor(0x000000, 0);
    renderer.setPixelRatio(pr); renderer.setSize(w, h, false);
    hide.forEach((o, k) => { o.visible = was[k]; });
    setInsetView(); camera.updateProjectionMatrix();
    shadows();
    return url;
  }

  // ---------- цикл отрисовки: рисуем, только когда что-то поменялось ----------
  const t0 = performance.now();
  let lastT = 0;
  function loop(t) {
    raf = requestAnimationFrame(loop);
    const dt = Math.min(100, t - (lastT || t)); lastT = t;
    if (document.hidden) return;
    if (grow < 1) {   // стены «вырастают» из плана, потом появляется мебель
      grow = Math.min(1, (t - t0) / 900);
      const e = 1 - Math.pow(1 - grow, 3);
      for (const P of wallParts) P.m.scale.y = (P.cut ? CUT / H : 1) * Math.max(e, 0.001);
      if (grow >= 1) { for (const [, it] of items) it.group.visible = true; shadows(); }
      dirty = true;
    }
    if (anim && anim(t)) dirty = true;
    if (offNow !== offTo) {
      offNow += (offTo - offNow) * (1 - Math.exp(-dt / 70));   // по времени, а не по кадрам
      if (Math.abs(offTo - offNow) < 0.5) offNow = offTo;
      applyOffset(); dirty = true;
    }
    if (mode === "orbit" && controls.enabled && controls.update()) dirty = true;
    if (!dirty) return;
    dirty = false;
    if (mode === "orbit") cutWalls();
    renderer.render(scene, camera);
  }

  // первая сборка
  buildWalls();
  apply(L, true);
  resize();
  views = viewpoints();
  frameOrbit();
  setModeLook();
  raf = requestAnimationFrame(loop);

  return {
    get look() { return clone(L); },
    get mode() { return mode; },
    get selected() { return sel; },
    get views() { return views.length; },
    get lost() { return lost; },
    update(fn) {
      const n = clone(L), r = fn(n);
      apply(r || n);
      onChange?.(clone(L));
    },
    select, setMode,
    nextView() {
      if (mode !== "room") return;
      views = viewpoints(); viewIdx = (viewIdx + 1) % views.length;
      const p = roomPose(viewIdx);
      look3.yaw = p.yaw; look3.pitch = p.pitch;
      tween(p.pos, new T.Quaternion().setFromEuler(new T.Euler(p.pitch, p.yaw, 0, "YXZ")), look3.fov, 650);
    },
    setInset(px) { inset = px; setInsetView(); camera.updateProjectionMatrix(); need(); },
    info(s) {
      if (!s) return null;
      if (s.type === "obj" || s.type === "added") { const it = items.get(s.type === "obj" ? "o" + s.i : "a" + s.j); return it ? { ...it.spec } : null; }
      return null;
    },
    // новая мебель у стены или в свободном месте; place — готовое место (совет для свободной стены)
    add(kind, variant, place) {
      if (L.added.length >= MAX_ADDED) return null;
      const [w0, d0, h0] = sizeOf(kind, variant);
      const w = place?.width || w0, d = place?.depth || d0;
      let h = place?.height || h0;
      const spot = place ? { x: place.x, y: place.y, angle: orient(place.x, place.y, w, d, place.angle || 0) } : spotFor(kind, variant, w, d, h);
      if (place) {   // совет под окном: на 5 см ниже подоконника, как в подборе мебели
        const sill = Math.min(...windowsBehind({ ...spot, width: w, depth: d }).map(o => o.v0));
        if (isFinite(sill)) h = Math.min(h, Math.max(0.3, Math.round((sill - 0.05) * 100) / 100));
      }
      const item = { kind, variant, color: defaultColor(kind, variant, pal), width: w, depth: d, height: h, x: spot.x, y: spot.y, angle: spot.angle };
      this.update(l => { l.added.push(item); });
      return { j: L.added.length - 1, tight: !!spot.tight };
    },
    rotate(j) {
      this.update(l => { const a = l.added[j]; if (a) a.angle = Math.atan2(Math.sin(a.angle + PI / 2), Math.cos(a.angle + PI / 2)); });
    },
    snapshot,
    resize,
    render() { need(); },
    dispose() {
      cancelAnimationFrame(raf);
      ro.disconnect();
      controls.dispose();
      canvas.removeEventListener("pointerdown", onDown, { capture: true });
      canvas.removeEventListener("webglcontextlost", onLost); canvas.removeEventListener("webglcontextrestored", onRestored);
      removeEventListener("pointermove", onMove); removeEventListener("pointerup", onUp); removeEventListener("pointercancel", onUp);
      scene.traverse(o => { o.geometry?.dispose(); });
      MAT.forEach(m => m.dispose()); MAT.clear();
      TEX.forEach(drop); TEX.clear();
      selMat.dispose(); selFill.dispose();
      envTex.dispose(); pmrem.dispose();
      renderer.dispose(); renderer.forceContextLoss();
    },
  };
}
