# Conclusiones de "No favorito liquido (ganador)": apuestas en vivo vs lo que decia la investigacion (60 dias).
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
function Kind($slug, $outcome, $league) {
    if ($league -ne 'soccer') { return "$league" }
    if ($slug -match '-draw$') { return 'futbol: empate' }
    if ($outcome -eq 'No') { return 'futbol: contra el favorito (No)' }
    return 'futbol: gana el no favorito (Si)'
}
# Probabilidad de ganar k o menos apuestas si cada una gana con su precio (Poisson-binomial)
function Get-PLow($ps, $k) {
    $dp = New-Object double[] ($ps.Count + 1); $dp[0] = 1.0
    foreach ($p in $ps) { for ($j = $ps.Count; $j -ge 1; $j--) { $dp[$j] = $dp[$j] * (1 - $p) + $dp[$j - 1] * $p }; $dp[0] *= (1 - $p) }
    $s = 0.0; for ($j = 0; $j -le $k; $j++) { $s += $dp[$j] }; return $s
}
function Rep($name, $b) { $b = @($b); if (-not $b.Count) { return }; $p = ($b | Measure-Object pnl -Sum).Sum; $w = @($b | Where-Object { $_.status -eq 'won' }).Count
    '{0,-36} n={1,3} ganadas={2,3} esperadas={3,5:N1} precio={4,5:P0} P&L={5,7:N2} ROI={6,7:P1}' -f $name, $b.Count, $w, ($b | Measure-Object price -Sum).Sum, ($b | Measure-Object price -Average).Average, $p, ($p / ($b | Measure-Object stake -Sum).Sum) }

$live = @(Get-Content (Join-Path $Root 'data\underdog-ml-bets.json') -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
$res = @($live | Where-Object { $_.status -in 'won', 'lost' })
"=== EN VIVO (desde el 11 oct): $($live.Count) apuestas, $($res.Count) resueltas ($(@($res | Where-Object provisional).Count) por confirmar) ==="
Rep 'Todas' $res
foreach ($g in ($res | Group-Object { Kind $_.slug $_.outcome $_.league } | Sort-Object Count -Descending)) { Rep "  $($g.Name)" $g.Group }
foreach ($b0 in 0.20, 0.25, 0.30) { Rep "  precio $([int]($b0*100))-$([int]($b0*100)+5)c" @($res | Where-Object { $_.price -ge $b0 -and $_.price -lt $b0 + 0.05 }) }
$w = @($res | Where-Object { $_.status -eq 'won' }).Count
"Probabilidad de ganar $w o menos de $($res.Count) si los precios fueran justos: {0:P1}" -f (Get-PLow @($res | ForEach-Object { [double]$_.price }) $w)
$sp = @($live | Where-Object { $null -ne $_.bestBid } | ForEach-Object { [double]$_.price - [double]$_.bestBid })
"Diferencial pagado (precio de compra - mejor oferta de venta): promedio {0:N1}c" -f (100 * ($sp | Measure-Object -Average).Average)
"Comisiones: {0:N2} USD" -f ($live | Measure-Object fee -Sum).Sum

"`n=== INVESTIGACION (60 dias, mismas reglas: ganador, tenis/futbol/UFC/NFL, 20-35c, 120 min antes) ==="
Add-Type -Path (Join-Path $PSScriptRoot 'SportsEngine.cs') -ReferencedAssemblies System.Core
$raw = [Fsp.Eng]::Load((Join-Path $PSScriptRoot 'data\sports'))
$main = New-Object 'System.Collections.Generic.List[Fsp.Mk]'
foreach ($g in ($raw | Group-Object { "$($_.Ev)|$($_.Type)" })) { $main.Add(($g.Group | Sort-Object Vol -Descending | Select-Object -First 1)) }
$bt = @([Fsp.Eng]::Band($main, '*', 'moneyline', 120, 0.20, 0.35) | Where-Object { $_.M.League -in 'tennis', 'soccer', 'ufc', 'nfl' })
$rows = @($bt | ForEach-Object { [pscustomobject]@{ slug = $_.M.Slug; league = $_.M.League; outcome = $(if ($_.Side0) { $_.M.O0 } else { $_.M.O1 }); price = $_.Price; pnl = $_.Pnl; stake = 1.0; status = $(if ($_.Won) { 'won' } else { 'lost' }) } })
Rep 'Todas' $rows
foreach ($g in ($rows | Group-Object { Kind $_.slug $_.outcome $_.league } | Sort-Object Count -Descending)) { Rep "  $($g.Name)" $g.Group }
# Rachas: con que frecuencia 46 apuestas seguidas daban -29% o peor
$ord = @($bt | Sort-Object { $_.M.Start } | ForEach-Object { $_.Pnl }); $bad = 0; $tot = 0
for ($i = 0; $i + 46 -le $ord.Count; $i += 5) { $s = 0.0; for ($j = $i; $j -lt $i + 46; $j++) { $s += $ord[$j] }; $tot++; if ($s / 46 -le -0.29) { $bad++ } }
"Tramos de 46 apuestas seguidas con ROI de -29% o peor en la investigacion: $bad de $tot ({0:P1})" -f ($bad / [Math]::Max(1, $tot))
