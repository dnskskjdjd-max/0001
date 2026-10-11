# Regla "cruce" de BTC 5 min (11 oct): comprar el lado que pasa trigger (73c), hasta maxN compras por ventana; la siguiente
# solo si antes el lado que iba adelante volvio por debajo de rearm (70c). Sin modelo. Con los 60 dias de research/data.
# Precio: el maximo pagado en ese tramo de 5 s (o el ultimo + 1c) mas 'extra' (el bot en vivo suma 1c al libro real).
param([string]$Market = 'm5', [int]$T = 300)
$ErrorActionPreference = 'Stop'
# Se compila junto con Engine.cs (un ensamblado aparte no ve sus clases)
if (-not ('Fst.Cross' -as [type])) {
    Add-Type -ReferencedAssemblies System.Core -TypeDefinition ((Get-Content (Join-Path $PSScriptRoot 'Engine.cs') -Raw) + "`n" + @'
namespace Fst {
public static class Cross {
    public static List<Bet> Run(List<Market> ms, double trig, double rearm, int maxN, double extra, bool atSeen) {
        var bets = new List<Bet>();
        foreach (var m in ms) {
            if (!m.Ok) continue;
            bool armed = false; int n = 0;
            for (int sec = 5; sec <= m.T - 15; sec += 5) {
                int age; double up = Eng.UpPriceBefore(m, sec, out age); if (double.IsNaN(up) || age > 30) continue;
                bool upLead = up >= 0.5; double lead = upLead ? up : 1 - up;
                if (lead < rearm) armed = true;
                if (armed && lead >= trig && n < maxN) {
                    double f = Math.Min(0.999, (atSeen ? lead : Eng.FillPrice(m, sec, upLead, up)) + extra);   // atSeen: al ultimo precio visto (optimista)
                    if (f > 0.95) continue;
                    n++; armed = false;
                    bets.Add(Eng.MakeBet(m, sec, upLead, f, n));
                }
            }
        }
        return bets;
    }
}
}
'@)
}
$Data = Join-Path $PSScriptRoot 'data'
$btc = New-Object Fst.Btc (Join-Path $Data 'btc1s')
$all = [Fst.Eng]::Load((Join-Path $Data $Market), $T, $btc)
$ok = @($all | Where-Object Ok)
"mercados $Market : $($ok.Count) de $($all.Count), dias de BTC $($btc.Days)"
function Rep($name, $b) { $b = @($b); if (-not $b.Count) { "{0,-34} n=0" -f $name; return }; $p = ($b | Measure-Object Pnl -Sum).Sum
    '{0,-34} n={1,6} gano={2,5:P1} precio={3,5:P1} ROI={4,7:P2} P&L={5,8:N1}' -f $name, $b.Count, (@($b | Where-Object Won).Count / $b.Count), ($b | Measure-Object Price -Average).Average, ($p / $b.Count), $p }
foreach ($extra in 0.0, 0.01) {
    $bets = @([Fst.Cross]::Run($all, 0.73, 0.70, 2, $extra, $false))
    "=== cruce 73c, rearme <70c, hasta 2 por ventana, +$([int]($extra * 100))c ==="
    Rep 'todas' $bets
    Rep '  1a compra' @($bets | Where-Object { $_.Feat -eq 1 })
    Rep '  2a compra (inestabilidad)' @($bets | Where-Object { $_.Feat -eq 2 })
    $med = ($ok | ForEach-Object { $_.W } | Sort-Object)[[int]($ok.Count / 2)]
    Rep '  primeros 30 dias' @($bets | Where-Object { $_.W -lt $med })
    Rep '  ultimos 30 dias' @($bets | Where-Object { $_.W -ge $med })
    Rep '  minuto 0-2 de la ventana' @($bets | Where-Object { $_.Sec -lt 120 })
    Rep '  minuto 2-5 de la ventana' @($bets | Where-Object { $_.Sec -ge 120 })
}
"=== otros umbrales (+1c, hasta 2 por ventana) ==="
foreach ($tr in 0.60, 0.65, 0.70, 0.73, 0.76, 0.80, 0.85) { Rep "  cruce $([int]($tr * 100))c" @([Fst.Cross]::Run($all, $tr, $tr - 0.03, 2, 0.01, $false)) }
"=== optimista: compra al ultimo precio visto al cruzar + extra (el bot en vivo lee el libro cada ~2 s) ==="
foreach ($extra in 0.0, 0.01, 0.02) { $b2 = @([Fst.Cross]::Run($all, 0.73, 0.70, 2, $extra, $true)); Rep "  +$([int]($extra * 100))c" $b2 }