// Motor de investigacion de estrategias deportivas propias con research/data/sports/*.jsonl (lo compila analyze-sports.ps1).
// Compra simulada: precio del momento + 1c (medio diferencial) y la comision real del mercado (usd x tasa x (1 - p)).
// Una apuesta de $1 por mercado, mantenida hasta el resultado.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Fsp {
public class Mk {
    public string Slug, Ev, League, Type, O0, O1; public double Line, Fee; public long Start; public int Vol, Win;
    public int[] T; public double[] P;   // minutos respecto del inicio (negativos = antes) y precio del primer resultado
    // Precio del primer resultado en 'minBefore' minutos antes del inicio (ultimo punto no mas viejo que 'maxAge' min)
    public double PriceAt(int minBefore, int maxAge) {
        int target = -minBefore; double p = double.NaN;
        for (int i = 0; i < T.Length; i++) { if (T[i] > target) break; if (T[i] >= target - maxAge) p = P[i]; }
        return p;
    }
}
public class Bet { public Mk M; public bool Side0; public double Price; public double Pnl; public bool Won; }

public static class Eng {
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    public static List<Mk> Load(string dir) {
        var list = new List<Mk>(); var seen = new HashSet<string>();
        foreach (var f in Directory.GetFiles(dir, "*.jsonl")) {
            foreach (var line in ReadShared(f)) {
                if (line.Length < 20 || !line.EndsWith("]}")) continue;
                var m = new Mk();
                m.Slug = Str(line, "\"slug\":\""); if (!seen.Add(m.Slug)) continue;
                m.Ev = Str(line, "\"ev\":\""); m.League = Str(line, "\"league\":\""); m.Type = Str(line, "\"type\":\"");
                string ln = Num(line, "\"line\":"); m.Line = ln == "null" ? double.NaN : double.Parse(ln, Inv);
                m.Start = long.Parse(Num(line, "\"start\":")); m.Fee = double.Parse(Num(line, "\"fee\":"), Inv);
                m.Vol = int.Parse(Num(line, "\"vol\":")); m.Win = int.Parse(Num(line, "\"win\":"));
                int oi = line.IndexOf("\"o\":[\"") + 6; int oj = line.IndexOf("\",\"", oi); int ok = line.IndexOf("\"]", oj);
                m.O0 = line.Substring(oi, oj - oi); m.O1 = line.Substring(oj + 3, ok - oj - 3);
                int hi = line.IndexOf("\"h\":[") + 5; string body = line.Substring(hi, line.Length - hi - 2);
                var ts = new List<int>(); var ps = new List<double>(); int pos = 0;
                while ((pos = body.IndexOf('[', pos)) >= 0) {
                    int end = body.IndexOf(']', pos); var parts = body.Substring(pos + 1, end - pos - 1).Split(',');
                    ts.Add(int.Parse(parts[0])); ps.Add(double.Parse(parts[1], Inv)); pos = end + 1;
                }
                m.T = ts.ToArray(); m.P = ps.ToArray();
                list.Add(m);
            }
        }
        return list.OrderBy(x => x.Start).ToList();
    }
    static IEnumerable<string> ReadShared(string f) {
        using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) using (var sr = new StreamReader(fs)) { string l; while ((l = sr.ReadLine()) != null) yield return l; }
    }
    static string Str(string s, string key) { int i = s.IndexOf(key) + key.Length; return s.Substring(i, s.IndexOf('"', i) - i); }
    static string Num(string s, string key) { int i = s.IndexOf(key) + key.Length; int j = i; while (j < s.Length && s[j] != ',' && s[j] != '}') j++; return s.Substring(i, j - i); }

    public static Bet Buy(Mk m, bool side0, double px) {
        double f = Math.Min(0.99, px + 0.01); bool won = side0 == (m.Win == 0);
        double fee = m.Fee * (1 - f);   // por $1 apostado
        return new Bet { M = m, Side0 = side0, Price = f, Won = won, Pnl = (won ? 1 / f - 1 : -1) - fee };
    }
    static bool Keep(Mk m, string league, string type) { return (league == "*" || m.League == league) && (type == "*" || m.Type == type); }

    // 1) Precio en un tramo: compra el resultado cuyo precio, 'minBefore' min antes del inicio, esta entre lo y hi
    public static List<Bet> Band(List<Mk> ms, string league, string type, int minBefore, double lo, double hi) {
        var r = new List<Bet>();
        foreach (var m in ms) {
            if (!Keep(m, league, type)) continue;
            double p0 = m.PriceAt(minBefore, 60); if (double.IsNaN(p0) || p0 <= 0.01 || p0 >= 0.99) continue;
            if (p0 >= lo && p0 < hi) r.Add(Buy(m, true, p0)); else if (1 - p0 >= lo && 1 - p0 < hi) r.Add(Buy(m, false, 1 - p0));
        }
        return r;
    }
    // 2) Impulso: si el precio del primer resultado cambio >= d entre 'fromMin' y 'toMin' min antes, compra (en toMin)
    //    el que subio (follow=true) o el que bajo (follow=false). Solo precios entre 10c y 90c al decidir.
    public static List<Bet> Momentum(List<Mk> ms, string league, string type, int fromMin, int toMin, double d, bool follow) {
        var r = new List<Bet>();
        foreach (var m in ms) {
            if (!Keep(m, league, type)) continue;
            double a = m.PriceAt(fromMin, 120), b = m.PriceAt(toMin, 30); if (double.IsNaN(a) || double.IsNaN(b)) continue;
            double delta = b - a; if (Math.Abs(delta) < d) continue;
            bool side0 = (delta > 0) == follow; double px = side0 ? b : 1 - b;
            if (px < 0.10 || px > 0.90) continue;
            r.Add(Buy(m, side0, px));
        }
        return r;
    }
    // Calibracion: por tramo de precio (del lado comprado) en 'minBefore', cuantas veces gano vs su precio medio
    public static string Calib(List<Mk> ms, string league, string type, int minBefore) {
        var lines = new List<string>(); double[] edges = { 0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95 };
        for (int i = 0; i + 1 < edges.Length; i++) {
            var b = Band(ms, league, type, minBefore, edges[i], edges[i + 1]); if (b.Count < 20) continue;
            double win = b.Count(x => x.Won) / (double)b.Count, px = b.Average(x => x.Price - 0.01);
            lines.Add(string.Format(Inv, "   {0,2:F0}-{1,2:F0}c: n={2,5} gano={3,6:P1} precio={4,6:P1} diferencia={5,6:+0.0;-0.0}pp ROI={6,7:P1}", edges[i] * 100, edges[i + 1] * 100, b.Count, win, px, (win - px) * 100, b.Average(x => x.Pnl)));
        }
        return string.Join("\n", lines);
    }
}
}
