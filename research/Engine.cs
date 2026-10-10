// Motor de investigacion para estrategias de Bitcoin Up/Down (15 y 5 min) con el historial de research/data.
// Lo compila research/analyze.ps1 con Add-Type (C# 5, .NET Framework).
//
// Supuestos de ejecucion (conservadores):
//   - Decision en el segundo t de la ventana con informacion hasta t-1 (Binance) y operaciones de Polymarket antes de t.
//   - Compra: el precio MAS ALTO pagado por ese resultado en los 5 s siguientes [t, t+5); si nadie opero ahi, el ultimo
//     precio conocido + 1c. Mas comision de Polymarket: 0.07 x p x (1 - p) por accion.
//   - Una apuesta de $1 por decision; se mantiene hasta la resolucion.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Fst {
public class Market {
    public long W; public int T; public bool UpWon; public int Trades;
    // Por tramo de 5 s (indice = segundo/5 desde el inicio, desde -12): ultimo, minimo, maximo precio y volumen de Up y Down
    public Dictionary<int, double[]> B = new Dictionary<int, double[]>();
    public double Base;      // promedio de BTC en el minuto previo al inicio (base de la regla "TWAP 60 s")
    public bool Ok;
}

public class Btc {
    readonly Dictionary<long, double[]> days = new Dictionary<long, double[]>();
    public Btc(string dir) {
        foreach (var f in Directory.GetFiles(dir, "*.csv")) {
            var d = DateTime.ParseExact(Path.GetFileNameWithoutExtension(f), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
            long d0 = (long)(d - new DateTime(1970, 1, 1)).TotalSeconds;
            var arr = new double[86400];
            foreach (var line in File.ReadLines(f)) {
                int c = line.IndexOf(','); if (c < 0) continue;
                int s; double p;
                if (int.TryParse(line.Substring(0, c), out s) && s >= 0 && s < 86400 && double.TryParse(line.Substring(c + 1), NumberStyles.Float, CultureInfo.InvariantCulture, out p)) arr[s] = p;
            }
            for (int i = 1; i < 86400; i++) if (arr[i] == 0) arr[i] = arr[i - 1];   // segundos sin vela: ultimo precio
            days[d0] = arr;
        }
    }
    public int Days { get { return days.Count; } }
    // Precio de cierre en el segundo unix t (0 si no hay datos)
    public double P(long t) {
        long d0 = t - ((t % 86400) + 86400) % 86400; double[] a;
        if (!days.TryGetValue(d0, out a)) return 0;
        return a[t - d0];
    }
    // Volatilidad anual con retornos de 1 min de los ultimos 'min' minutos antes de t
    public double Vol(long t, int min) {
        double s = 0, s2 = 0; int n = 0;
        for (int i = min; i >= 1; i--) {
            double a = P(t - 60 * i), b = P(t - 60 * (i - 1));
            if (a <= 0 || b <= 0) continue;
            double r = Math.Log(b / a); s += r; s2 += r * r; n++;
        }
        if (n < 5) return 0;
        double m = s / n; double v = (s2 - n * m * m) / (n - 1);
        return Math.Sqrt(Math.Max(v, 1e-12) * 525600);
    }
}

public class Bet { public long W; public int Sec; public bool Up; public double Price; public double Pnl; public bool Won; public double Feat; }

public static class Eng {
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    public static double Fee(double p) { return 0.07 * p * (1 - p); }
    public static double Ncdf(double x) {
        double t = 1 / (1 + 0.2316419 * Math.Abs(x)), d = 0.3989422804014327 * Math.Exp(-x * x / 2);
        double p = d * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))));
        return x >= 0 ? 1 - p : p;
    }

    // Carga los mercados de una carpeta (m15 o m5) y calcula la base de BTC de cada uno
    public static List<Market> Load(string dir, int T, Btc btc) {
        var list = new List<Market>();
        // Solo dias completos (marcados con .done): los demas se estan descargando todavia
        foreach (var f in Directory.GetFiles(dir, "trades-*.jsonl").Where(x => File.Exists(x + ".done")).OrderBy(x => x)) {
            foreach (var line in File.ReadLines(f)) {
                if (line.Length < 10) continue;
                var m = new Market { T = T };
                m.W = long.Parse(Between(line, "\"W\":", ","));
                m.UpWon = Between(line, "\"up\":", ",") == "1";
                m.Trades = int.Parse(Between(line, "\"n\":", ","));
                int bi = line.IndexOf("\"b\":[");
                if (bi >= 0) {
                    string body = line.Substring(bi + 5);
                    int pos = 0;
                    while ((pos = body.IndexOf('[', pos)) >= 0) {
                        int end = body.IndexOf(']', pos); if (end < 0) break;
                        var parts = body.Substring(pos + 1, end - pos - 1).Split(',');
                        if (parts.Length == 9) {
                            var v = new double[8];
                            for (int k = 0; k < 8; k++) v[k] = double.Parse(parts[k + 1], NumberStyles.Float, Inv);
                            m.B[int.Parse(parts[0])] = v;
                        }
                        pos = end + 1;
                    }
                }
                double s = 0; int n = 0;
                for (long t = m.W - 60; t < m.W; t++) { double p = btc.P(t); if (p > 0) { s += p; n++; } }
                m.Base = n > 30 ? s / n : 0;
                m.Ok = m.Base > 0 && btc.P(m.W + T - 1) > 0;
                list.Add(m);
            }
        }
        return list;
    }
    static string Between(string s, string a, string b) { int i = s.IndexOf(a) + a.Length; int j = s.IndexOf(b, i); return s.Substring(i, j - i); }

    // Ultimo precio de Up conocido ANTES del segundo 'sec' (de Up o, si es mas reciente, 1 - Down). NaN si no hay.
    public static double UpPriceBefore(Market m, int sec, out int ageSec) {
        ageSec = 9999; int lastBucket = (sec / 5) - 1;
        for (int i = lastBucket; i >= -12; i--) {
            double[] v; if (!m.B.TryGetValue(i, out v)) continue;
            if (v[0] >= 0 && v[4] >= 0) { ageSec = sec - i * 5; return v[0]; }
            if (v[0] >= 0) { ageSec = sec - i * 5; return v[0]; }
            if (v[4] >= 0) { ageSec = sec - i * 5; return 1 - v[4]; }
        }
        return double.NaN;
    }
    // Precio de compra realista del lado 'up' en [sec, sec+5): el maximo pagado ahi, o ultimo conocido + 1c
    public static double FillPrice(Market m, int sec, bool up, double lastUp) {
        double[] v;
        if (m.B.TryGetValue(sec / 5, out v)) { double mx = up ? v[2] : v[6]; if (mx >= 0) return Math.Min(0.999, mx); }
        double last = up ? lastUp : 1 - lastUp;
        return Math.Min(0.999, last + 0.01);
    }
    public static Bet MakeBet(Market m, int sec, bool up, double price, double feat) {
        bool won = up == m.UpWon; double sh = 1.0 / price;
        return new Bet { W = m.W, Sec = sec, Up = up, Price = price, Won = won, Feat = feat, Pnl = (won ? sh - 1 : -1) - sh * Fee(price) };
    }

    // Probabilidad de Up segun el modelo "TWAP 60 s" (promedio del ultimo minuto vs base), con volatilidad anual 'vol'
    public static double ModelUp(Market m, Btc btc, int sec, double vol) {
        double S = btc.P(m.W + sec - 1); if (S <= 0 || vol <= 0) return double.NaN;
        int r = m.T - sec; double sigS = vol / Math.Sqrt(31536000.0);
        if (r >= 60) return Ncdf(Math.Log(S / m.Base) / (sigS * Math.Sqrt(r - 40)));
        int k = 60 - r; double sk = 0; for (int i = 1; i <= k; i++) sk += btc.P(m.W + sec - i);
        double M60 = (sk + r * S) / 60, sd = S * sigS * Math.Sqrt(r * (r + 1.0) * (2 * r + 1) / 6) / 60;
        return sd > 0 ? Ncdf((M60 - m.Base) / sd) : (M60 >= m.Base ? 1 : 0);
    }

    // ---------- Familias de estrategias (una apuesta como maximo por mercado: el primer momento que cumple) ----------
    // 1) Modelo vs mercado: apuesta el lado con ventaja >= edge, entre secFrom y secTo segundos desde el inicio
    public static List<Bet> RunModel(List<Market> ms, Btc btc, int secFrom, int secTo, double edge, int volMin, double minP, double maxP) {
        var bets = new List<Bet>();
        foreach (var m in ms) {
            if (!m.Ok) continue;
            for (int sec = secFrom; sec <= secTo; sec += 5) {
                int age; double up = UpPriceBefore(m, sec, out age); if (double.IsNaN(up) || age > 30) continue;
                double vol = btc.Vol(m.W + sec, volMin); double p = ModelUp(m, btc, sec, vol); if (double.IsNaN(p)) continue;
                double fu = FillPrice(m, sec, true, up), fd = FillPrice(m, sec, false, up);
                double eu = p - fu - Fee(fu), ed = (1 - p) - fd - Fee(fd);
                if (eu >= edge && eu >= ed && fu >= minP && fu <= maxP) { bets.Add(MakeBet(m, sec, true, fu, eu)); break; }
                if (ed >= edge && ed > eu && fd >= minP && fd <= maxP) { bets.Add(MakeBet(m, sec, false, fd, ed)); break; }
            }
        }
        return bets;
    }
    // 2) Favorito del mercado en el segundo 'sec' si su precio esta entre lo y hi (sesgo favorito / no favorito)
    public static List<Bet> RunFavorite(List<Market> ms, int sec, double lo, double hi, bool underdog) {
        var bets = new List<Bet>();
        foreach (var m in ms) {
            if (!m.Ok) continue;
            int age; double up = UpPriceBefore(m, sec, out age); if (double.IsNaN(up) || age > 30) continue;
            bool favUp = up >= 0.5; bool buyUp = underdog ? !favUp : favUp;
            double ref0 = buyUp ? up : 1 - up; if (ref0 < lo || ref0 > hi) continue;
            double f = FillPrice(m, sec, buyUp, up);
            bets.Add(MakeBet(m, sec, buyUp, f, ref0));
        }
        return bets;
    }
    // 3) Retraso: BTC se movio fuerte en los ultimos 'look' segundos (>= z desviaciones) y Polymarket casi no se movio
    public static List<Bet> RunLag(List<Market> ms, Btc btc, int secFrom, int secTo, int look, double z, double maxPmMove) {
        var bets = new List<Bet>();
        foreach (var m in ms) {
            if (!m.Ok) continue;
            for (int sec = secFrom; sec <= secTo; sec += 5) {
                double S = btc.P(m.W + sec - 1), S0 = btc.P(m.W + sec - 1 - look); if (S <= 0 || S0 <= 0) continue;
                double vol = btc.Vol(m.W + sec, 30); if (vol <= 0) continue;
                double zz = Math.Log(S / S0) / (vol / Math.Sqrt(31536000.0) * Math.Sqrt(look));
                if (Math.Abs(zz) < z) continue;
                int a1, a2; double upNow = UpPriceBefore(m, sec, out a1), upThen = UpPriceBefore(m, sec - look, out a2);
                if (double.IsNaN(upNow) || double.IsNaN(upThen) || a1 > 15) continue;
                double pmMove = upNow - upThen; bool up = zz > 0;
                if ((up ? pmMove : -pmMove) > maxPmMove) continue;   // Polymarket ya se movio: no hay retraso que aprovechar
                double f = FillPrice(m, sec, up, upNow); if (f > 0.95 || f < 0.05) continue;
                bets.Add(MakeBet(m, sec, up, f, zz)); break;
            }
        }
        return bets;
    }

    // 4) Modelo aprendido (regresion logistica) en un segundo fijo 'sec': aprende P(Up) con datos de entrenamiento a partir de
    //    [logit precio Polymarket, distancia de BTC al inicio en desviaciones, impulso 10 s y 60 s, volatilidad 5 min / 60 min,
    //    tiempo restante]; luego apuesta donde P(Up) aprendida - precio - comision >= edge.
    static double[] Features(Market m, Btc btc, int sec, out double upPx) {
        upPx = double.NaN;
        int age; double up = UpPriceBefore(m, sec, out age); if (double.IsNaN(up) || age > 30) return null;
        double S = btc.P(m.W + sec - 1), S10 = btc.P(m.W + sec - 11), S60 = btc.P(m.W + sec - 61);
        double v60 = btc.Vol(m.W + sec, 60), v5 = btc.Vol(m.W + sec, 5);
        if (S <= 0 || S10 <= 0 || S60 <= 0 || v60 <= 0 || v5 <= 0) return null;
        double sig = v60 / Math.Sqrt(31536000.0); int r = Math.Max(m.T - sec, 1);
        double pc = Math.Min(0.98, Math.Max(0.02, up)); upPx = up;
        return new double[] { 1, Math.Log(pc / (1 - pc)), Math.Log(S / m.Base) / (sig * Math.Sqrt(Math.Max(r - 40, 5))),
            Math.Log(S / S10) / (sig * Math.Sqrt(10)), Math.Log(S / S60) / (sig * Math.Sqrt(60)), Math.Log(v5 / v60), r / (double)m.T };
    }
    public static double[] Fit(List<Market> ms, Btc btc, int sec) {
        var X = new List<double[]>(); var Y = new List<double>(); double dummy;
        foreach (var m in ms) { if (!m.Ok) continue; var f = Features(m, btc, sec, out dummy); if (f == null) continue; X.Add(f); Y.Add(m.UpWon ? 1 : 0); }
        int k = 7; var w = new double[k]; if (X.Count < 50) return null;
        // Newton (IRLS) con un poco de regularizacion
        for (int it = 0; it < 25; it++) {
            var g = new double[k]; var H = new double[k, k];
            for (int i = 0; i < X.Count; i++) {
                double z = 0; for (int j = 0; j < k; j++) z += w[j] * X[i][j];
                double p = 1 / (1 + Math.Exp(-z)), d = p * (1 - p);
                for (int j = 0; j < k; j++) { g[j] += (Y[i] - p) * X[i][j]; for (int l = 0; l < k; l++) H[j, l] += d * X[i][j] * X[i][l]; }
            }
            for (int j = 0; j < k; j++) { g[j] -= 0.5 * w[j]; H[j, j] += 0.5; }
            var step = Solve(H, g, k); if (step == null) break;
            double mx = 0; for (int j = 0; j < k; j++) { w[j] += step[j]; mx = Math.Max(mx, Math.Abs(step[j])); }
            if (mx < 1e-6) break;
        }
        return w;
    }
    static double[] Solve(double[,] A0, double[] b0, int n) {
        var A = (double[,])A0.Clone(); var b = (double[])b0.Clone();
        for (int c = 0; c < n; c++) {
            int piv = c; for (int r = c + 1; r < n; r++) if (Math.Abs(A[r, c]) > Math.Abs(A[piv, c])) piv = r;
            if (Math.Abs(A[piv, c]) < 1e-12) return null;
            for (int j = 0; j < n; j++) { var t = A[c, j]; A[c, j] = A[piv, j]; A[piv, j] = t; } { var t = b[c]; b[c] = b[piv]; b[piv] = t; }
            for (int r = c + 1; r < n; r++) { double f = A[r, c] / A[c, c]; for (int j = c; j < n; j++) A[r, j] -= f * A[c, j]; b[r] -= f * b[c]; }
        }
        var x = new double[n]; for (int r = n - 1; r >= 0; r--) { double s = b[r]; for (int j = r + 1; j < n; j++) s -= A[r, j] * x[j]; x[r] = s / A[r, r]; }
        return x;
    }
    public static List<Bet> RunLogit(List<Market> ms, Btc btc, double[] w, int sec, double edge) {
        var bets = new List<Bet>(); if (w == null) return bets;
        foreach (var m in ms) {
            if (!m.Ok) continue; double up; var f = Features(m, btc, sec, out up); if (f == null) continue;
            double z = 0; for (int j = 0; j < w.Length; j++) z += w[j] * f[j]; double p = 1 / (1 + Math.Exp(-z));
            double fu = FillPrice(m, sec, true, up), fd = FillPrice(m, sec, false, up);
            double eu = p - fu - Fee(fu), ed = (1 - p) - fd - Fee(fd);
            if (eu >= edge && eu >= ed && fu >= 0.05 && fu <= 0.95) bets.Add(MakeBet(m, sec, true, fu, eu));
            else if (ed >= edge && fd >= 0.05 && fd <= 0.95) bets.Add(MakeBet(m, sec, false, fd, ed));
        }
        return bets;
    }
    // Calidad de prediccion (Brier) del modelo aprendido vs el precio de Polymarket, en un conjunto de mercados
    public static string Brier(List<Market> ms, Btc btc, double[] w, int sec) {
        double bm = 0, bk = 0; int n = 0;
        foreach (var m in ms) {
            if (!m.Ok || w == null) continue; double up; var f = Features(m, btc, sec, out up); if (f == null) continue;
            double z = 0; for (int j = 0; j < w.Length; j++) z += w[j] * f[j]; double p = 1 / (1 + Math.Exp(-z)), y = m.UpWon ? 1 : 0;
            bm += (p - y) * (p - y); bk += (up - y) * (up - y); n++;
        }
        return n == 0 ? "n=0" : string.Format(Inv, "n={0} Brier modelo={1:F4} mercado={2:F4}", n, bm / n, bk / n);
    }

    // Resumen: n, acierto, precio medio, ganancia, ROI
    public static string Sum(List<Bet> b) {
        if (b.Count == 0) return "n=0";
        double pnl = b.Sum(x => x.Pnl);
        return string.Format(Inv, "n={0,5} acierto={1,5:P0} precio={2,5:P0} P&L={3,8:F2} ROI={4,6:P1}", b.Count, b.Count(x => x.Won) / (double)b.Count, b.Average(x => x.Price), pnl, pnl / b.Count);
    }
}
}
