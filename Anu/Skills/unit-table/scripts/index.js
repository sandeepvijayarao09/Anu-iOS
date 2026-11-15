// Conversion tables for length, weight and temperature.
const LINEAR = {
  length: { mm: 0.001, cm: 0.01, m: 1, km: 1000, in: 0.0254, ft: 0.3048, yd: 0.9144, mi: 1609.344 },
  weight: { g: 0.001, kg: 1, oz: 0.028349523125, lb: 0.45359237 },
};
const TEMPERATURE = {
  C: { toK: (v) => v + 273.15, fromK: (k) => k - 273.15 },
  F: { toK: (v) => (v - 32) * 5 / 9 + 273.15, fromK: (k) => (k - 273.15) * 9 / 5 + 32 },
  K: { toK: (v) => v, fromK: (k) => k },
};

function converter(from, to) {
  for (const kind of Object.keys(LINEAR)) {
    const units = LINEAR[kind];
    if (from in units && to in units) return (v) => v * units[from] / units[to];
  }
  const f = TEMPERATURE[from.toUpperCase()];
  const t = TEMPERATURE[to.toUpperCase()];
  if (f && t) return (v) => t.fromK(f.toK(v));
  return null;
}

function round(v) {
  return Number(Math.abs(v) >= 100 ? v.toFixed(1) : v.toPrecision(4)).toString();
}

function ai_edge_gallery_get_result(data) {
  let p;
  try { p = JSON.parse(data); } catch (e) { return JSON.stringify({ error: "data must be a JSON object" }); }
  if (!p || typeof p !== "object") return JSON.stringify({ error: "data must be a JSON object" });
  const from = String(p.from || "");
  const to = String(p.to || "");
  const convert = converter(from, to);
  if (!convert) return JSON.stringify({ error: "can't convert " + from + " to " + to });
  const start = Number(p.start === undefined ? 1 : p.start);
  const end = Number(p.end === undefined ? 10 : p.end);
  const step = Number(p.step === undefined ? 1 : p.step);
  if (!isFinite(start) || !isFinite(end) || !isFinite(step) || step <= 0 || end < start) {
    return JSON.stringify({ error: "start, end and step must be numbers, with end at least start and step above 0" });
  }
  const count = Math.floor((end - start) / step + 1e-9) + 1;
  if (count > 50) return JSON.stringify({ error: "a table has at most 50 rows" });
  const rows = ["| " + from + " | " + to + " |", "|---|---|"];
  for (let i = 0; i < count; i++) {
    const v = start + i * step;
    rows.push("| " + round(v) + " | " + round(convert(v)) + " |");
  }
  return JSON.stringify({ result: rows.join("\n") });
}
