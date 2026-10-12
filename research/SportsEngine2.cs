// Motor de la investigacion deportiva SIN sesgo de seleccion (11 oct), con research/data/sports2/*.jsonl.
// Regla de oro: para decidir una apuesta solo se usa lo que se sabia en el momento de apostar (precio e historial de
// precios hasta ese minuto). Nunca el volumen de Gamma, que es el final e incluye lo operado durante el partido.
// Compra simulada: precio del momento + 'extra' (1c por defecto) y la comision real del mercado (usd x tasa x (1 - p)).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace Fsp2 {
public class Mk {
    public string Slug, Ev, Game, League, Type, Sub, O0, O1; public double Line, Fee; public long Start; public int Vol, Win;
    public int[] T; public double[] P;   // minutos respecto del inicio (negativos = antes) y precio del primer resultado
    // Precio del primer resultado 'minBefore' minutos antes del inicio (ultimo punto no mas viejo que 'maxAge' min)
    public double PriceAt(int minBefore, int maxAge) {
        int target = -minBefore; double p = double.NaN;
        for (int i = 0; i < T.Length; i++) { if (T[i] > target) break; if (T[i] >= target - maxAge) p = P[i]; }
        return p;
    }
    // Actividad previa: cuantas veces cambio el precio en los 'windowMin' minutos anteriores al momento de apostar
    public int Activity(int minBefore, int windowMin) {
        int target = -minBefore, from = target - windowMin, n = 0; double last = double.NaN;
        for (int i = 0; i < T.Length; i++) {
            if (T[i] > target) break;
            if (T[i] < from) { last = P[i]; continue; }
            if (!double.IsNaN(last) && Math.Abs(P[i] - last) > 1e-9) n++;
            last = P[i];
        }
        return n;
    }
}
public class Bet { public Mk M; public bool Side0; public double Px, Price, Pnl; public bool Won; public int Act; }

public static class Eng {
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    static readonly Regex GameRx = new Regex(@"^(.*?-\d{4}-\d{2}-\d{2})");
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
                var gm = GameRx.Match(m.Slug); m.Game = gm.Success ? gm.Groups[1].Value : m.Ev;
                m.Sub = m.Type;
                if (m.Type == "moneyline" && m.League == "soccer") {
                    var sp = m.Slug.Split('-'); string last = sp[sp.Length - 1];
                    m.Sub = last == "draw" ? "empate" : (sp.Length > 2 && last == sp[1]) ? "local" : (sp.Length > 2 && last == sp[2]) ? "visitante" : "equipo";
                }
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

    public static Bet Buy(Mk m, bool side0, double px, double extra, int act) {
        double f = Math.Min(0.99, px + extra); bool won = side0 == (m.Win == 0);
        double fee = m.Fee * (1 - f);   // por $1 apostado
        return new Bet { M = m, Side0 = side0, Px = px, Price = f, Won = won, Act = act, Pnl = (won ? 1 / f - 1 : -1) - fee };
    }
    // Compra el lado cuyo precio, 'minBefore' min antes del inicio, esta en [lo, hi). Precio no mas viejo que maxAge min
    // y al menos minAct cambios de precio en las 24 h previas (todo conocido al apostar).
    public static List<Bet> Band(List<Mk> ms, int minBefore, double lo, double hi, double extra, int maxAge, int minAct) {
        var r = new List<Bet>();
        foreach (var m in ms) {
            double p0 = m.PriceAt(minBefore, maxAge); if (double.IsNaN(p0) || p0 <= 0.01 || p0 >= 0.99) continue;
            int act = m.Activity(minBefore, 1440); if (act < minAct) continue;
            if (p0 >= lo && p0 < hi) r.Add(Buy(m, true, p0, extra, act)); else if (1 - p0 >= lo && 1 - p0 < hi) r.Add(Buy(m, false, 1 - p0, extra, act));
        }
        return r;
    }
    // Una apuesta por partido: prioridad ganador > spread > total; dentro del tipo, el mercado con mas actividad previa
    // (lo mas parecido al "mas volumen al apostar" del bot en vivo, sin mirar el futuro)
    public static List<Bet> OnePerGame(List<Bet> bets) {
        Func<string, int> pr = t => t == "moneyline" ? 0 : t == "spreads" ? 1 : 2;
        return bets.GroupBy(b => b.M.Game).Select(g => g.OrderBy(b => pr(b.M.Type)).ThenByDescending(b => b.Act).ThenBy(b => b.M.Slug).First()).ToList();
    }
    // Intervalo de confianza 95% del ROI remuestreando PARTIDOS (las apuestas del mismo partido no son independientes)
    public static double[] Ci(List<Bet> bets, int nSim, int seed) {
        var g = bets.GroupBy(b => b.M.Game).Select(x => new double[] { x.Sum(b => b.Pnl), x.Count() }).ToArray();
        if (g.Length < 5) return new double[] { double.NaN, double.NaN };
        var rnd = new Random(seed); var roi = new double[nSim];
        for (int s = 0; s < nSim; s++) { double p = 0, n = 0; for (int i = 0; i < g.Length; i++) { var x = g[rnd.Next(g.Length)]; p += x[0]; n += x[1]; } roi[s] = p / n; }
        Array.Sort(roi); return new double[] { roi[(int)(nSim * 0.025)], roi[(int)(nSim * 0.975)] };
    }
    public static string Line(string name, List<Bet> b) {
        if (b.Count == 0) return string.Format(Inv, "{0,-40} n=    0", name);
        var ci = Ci(b, 2000, 7); double roi = b.Average(x => x.Pnl);
        return string.Format(Inv, "{0,-40} n={1,5} partidos={2,5} gano={3,5:P1} precio={4,5:P1} ROI={5,6:P1}  IC95 [{6,6:P1} ; {7,6:P1}]",
            name, b.Count, b.Select(x => x.M.Game).Distinct().Count(), b.Count(x => x.Won) / (double)b.Count, b.Average(x => x.Px), roi, ci[0], ci[1]);
    }
}
}
