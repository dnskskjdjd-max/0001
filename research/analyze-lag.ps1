# Analisis a fondo de la familia "retraso" (BTC se movio fuerte y Polymarket todavia no): grilla fina de parametros,
# resultado por semana en el periodo de prueba y sensibilidad al precio de compra.
param([ValidateSet('m15', 'm5')][string]$Market = 'm15', [double]$TrainFrac = 0.67)
$ErrorActionPreference = 'Stop'
$Data = Join-Path $PSScriptRoot 'data'
if (-not ('Fst.Eng' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Engine.cs') -ReferencedAssemblies System.Core }
$T = if ($Market -eq 'm15') { 900 } else { 300 }
$btc = New-Object Fst.Btc (Join-Path $Data 'btc1s')
$ok = @([Fst.Eng]::Load((Join-Path $Data $Market), $T, $btc) | Where-Object { $_.Ok } | Sort-Object W)
$cut = $ok[[int]($ok.Count * $TrainFrac)].W
$train = New-Object 'System.Collections.Generic.List[Fst.Market]'; $test = New-Object 'System.Collections.Generic.List[Fst.Market]'
foreach ($m in $ok) { if ($m.W -lt $cut) { $train.Add($m) } else { $test.Add($m) } }
"Mercados $Market : entrenamiento $($train.Count), prueba $($test.Count)"
function Stat($b) { $b = @($b); if (-not $b.Count) { return @{ n = 0; roi = 0; pnl = 0 } }; $p = ($b | Measure-Object Pnl -Sum).Sum; return @{ n = $b.Count; roi = $p / $b.Count; pnl = $p } }
$wins = if ($T -eq 900) { @(@(480, 660), @(600, 780), @(660, 840), @(720, 840), @(780, 870)) } else { @(@(120, 210), @(150, 240), @(180, 270), @(210, 285)) }
$rows = foreach ($w in $wins) { foreach ($look in 5, 10, 15, 20) { foreach ($z in 1.0, 1.5, 2.0, 2.5, 3.0) {
    $a = Stat ([Fst.Eng]::RunLag($train, $btc, $w[0], $w[1], $look, $z, 0.0)); $b = Stat ([Fst.Eng]::RunLag($test, $btc, $w[0], $w[1], $look, $z, 0.0))
    [pscustomobject]@{ win = "$($w[0])-$($w[1])"; look = $look; z = $z; nTr = $a.n; roiTr = $a.roi; nTe = $b.n; roiTe = $b.roi; pnlTe = $b.pnl }
} } }
$rows = @($rows)
"`n=== Grilla (Polymarket no se movio a favor). Columnas: entrenamiento ROI (n) | PRUEBA ROI (n) ==="
foreach ($w in ($rows | Group-Object win)) {
    "-- segundos $($w.Name) desde el inicio"
    foreach ($r in $w.Group) { '   mira {0,2}s z>={1:N1}: entrenam. {2,7:P1} ({3,4}) | PRUEBA {4,7:P1} ({5,4})' -f $r.look, $r.z, $r.roiTr, $r.nTr, $r.roiTe, $r.nTe }
}
$pos = @($rows | Where-Object { $_.nTr -ge 80 -and $_.roiTr -gt 0 })
"`nConfiguraciones con ganancia en entrenamiento (n>=80): $($pos.Count); de ellas con ganancia en la prueba: $(@($pos | Where-Object { $_.roiTe -gt 0 }).Count)"
"Todas las configuraciones (n>=80 en ambos): ROI medio entrenamiento {0:P1}, prueba {1:P1}" -f (@($rows | Where-Object { $_.nTr -ge 80 }) | Measure-Object roiTr -Average).Average, (@($rows | Where-Object { $_.nTe -ge 30 }) | Measure-Object roiTe -Average).Average
# La mejor por entrenamiento: por semana en la prueba y con precio de compra peor (+1c, +2c)
$best = $pos | Sort-Object roiTr -Descending | Select-Object -First 1
if ($best) {
    $w0, $w1 = $best.win -split '-'
    "`n=== Mejor en entrenamiento: segundos $($best.win), mira $($best.look)s, z>=$($best.z) ==="
    $bt = @([Fst.Eng]::RunLag($test, $btc, [int]$w0, [int]$w1, $best.look, $best.z, 0.0))
    foreach ($g in ($bt | Group-Object { $d = [DateTimeOffset]::FromUnixTimeSeconds($_.W).UtcDateTime; $d.AddDays(-[int]$d.DayOfWeek).ToString('yyyy-MM-dd') })) {
        $p = ($g.Group | Measure-Object Pnl -Sum).Sum; '   semana del {0}: n={1,3} acierto={2:P0} P&L={3,7:N2} ROI={4,7:P1}' -f $g.Name, $g.Count, (@($g.Group | Where-Object { $_.Won }).Count / $g.Count), $p, ($p / $g.Count) }
    foreach ($extra in 0.01, 0.02, 0.03) {
        $pnl = 0; foreach ($x in $bt) { $px = [Math]::Min(0.999, $x.Price + $extra); $sh = 1 / $px; $pnl += $(if ($x.Won) { $sh - 1 } else { -1 }) - $sh * [Fst.Eng]::Fee($px) }
        '   si pagaramos {0}c mas por apuesta: P&L={1,7:N2} ROI={2,7:P1}' -f ($extra * 100), $pnl, ($pnl / [Math]::Max(1, $bt.Count)) }
}
