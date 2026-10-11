# Robustez de "comprar el no favorito de 20-35c": por liga, por tipo, una por partido, por semana y con peor precio
param([int]$MinBefore = 120, [double]$Lo = 0.20, [double]$Hi = 0.35)
$ErrorActionPreference = 'Stop'
if (-not ('Fsp.Eng' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'SportsEngine.cs') -ReferencedAssemblies System.Core }
$raw = [Fsp.Eng]::Load((Join-Path $PSScriptRoot 'data\sports'))
$main = New-Object 'System.Collections.Generic.List[Fsp.Mk]'
foreach ($g in ($raw | Group-Object { "$($_.Ev)|$($_.Type)" })) { $main.Add(($g.Group | Sort-Object Vol -Descending | Select-Object -First 1)) }
$bets = @([Fsp.Eng]::Band($main, '*', '*', $MinBefore, $Lo, $Hi))
function Sum($name, $b) { $b = @($b); if (-not $b.Count) { "{0,-34} n=0" -f $name; return }; $p = ($b | Measure-Object Pnl -Sum).Sum
    '{0,-34} n={1,4} partidos={2,4} gano={3,5:P0} precio={4,5:P0} ROI={5,7:P1} P&L={6,7:N2}' -f $name, $b.Count, @($b | ForEach-Object { $_.M.Ev } | Select-Object -Unique).Count, (@($b | Where-Object Won).Count / $b.Count), ($b | Measure-Object Price -Average).Average, ($p / $b.Count), $p }
"=== No favorito $([int]($Lo*100))-$([int]($Hi*100))c, $MinBefore min antes del inicio (mercados principales) ==="
Sum 'Todas' $bets
"-- por liga"; foreach ($g in ($bets | Group-Object { $_.M.League } | Sort-Object Count -Descending)) { Sum "  $($g.Name)" $g.Group }
"-- por tipo"; foreach ($g in ($bets | Group-Object { $_.M.Type })) { Sum "  $($g.Name)" $g.Group }
"-- con comision vs sin comision"; Sum '  sin comision' @($bets | Where-Object { $_.M.Fee -eq 0 }); Sum '  con comision' @($bets | Where-Object { $_.M.Fee -gt 0 })
"-- una sola apuesta por partido (prioridad: ganador > spread > total)"
$one = foreach ($g in ($bets | Group-Object { $_.M.Ev })) { $g.Group | Sort-Object { switch ($_.M.Type) { 'moneyline' { 0 } 'spreads' { 1 } default { 2 } } } | Select-Object -First 1 }
Sum '  una por partido' $one
"-- por semana (una por partido)"
foreach ($g in (@($one) | Group-Object { $d = [DateTimeOffset]::FromUnixTimeSeconds($_.M.Start).UtcDateTime; $d.AddDays(-[int]$d.DayOfWeek).ToString('MM-dd') } | Sort-Object Name)) { Sum "  semana del $($g.Name)" $g.Group }
"-- si pagaramos mas caro (una por partido)"
foreach ($extra in 0.01, 0.02, 0.03) {
    $p = 0; foreach ($x in @($one)) { $px = [Math]::Min(0.99, $x.Price + $extra); $p += $(if ($x.Won) { 1 / $px - 1 } else { -1 }) - $x.M.Fee * (1 - $px) }
    '  +{0}c: ROI={1:P1}' -f ($extra * 100), ($p / @($one).Count) }
# Remuestreo (bootstrap) por partido: probabilidad de que la ganancia real sea positiva
$arr = @($one | ForEach-Object { $_.Pnl }); $rnd = New-Object Random 11; $pos = 0; $nSim = 5000
for ($k = 0; $k -lt $nSim; $k++) { $s = 0; for ($i = 0; $i -lt $arr.Count; $i++) { $s += $arr[$rnd.Next($arr.Count)] }; if ($s -gt 0) { $pos++ } }
"-- remuestreo: en {0:P0} de {1} simulaciones la ganancia sale positiva" -f ($pos / $nSim), $nSim
