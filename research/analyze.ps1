# Investigacion de estrategias de Bitcoin Up/Down con el historial descargado (research/data).
# Divide los dias: los primeros 2/3 para elegir parametros (entrenamiento) y el ultimo 1/3 para validar (prueba).
# Solo cuenta lo que funciona en la prueba, que la estrategia nunca "vio".
param([ValidateSet('m15', 'm5')][string]$Market = 'm15', [double]$TrainFrac = 0.67, [int]$Top = 12)
$ErrorActionPreference = 'Stop'
$Data = Join-Path $PSScriptRoot 'data'
if (-not ('Fst.Eng' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Engine.cs') -ReferencedAssemblies System.Core }
$T = if ($Market -eq 'm15') { 900 } else { 300 }
$sw = [Diagnostics.Stopwatch]::StartNew()
$btc = New-Object Fst.Btc (Join-Path $Data 'btc1s')
$all = [Fst.Eng]::Load((Join-Path $Data $Market), $T, $btc)
$ok = @($all | Where-Object { $_.Ok } | Sort-Object W)
"Mercados $Market : $($all.Count) cargados, $($ok.Count) con precio de BTC | dias de BTC: $($btc.Days) | $([int]$sw.Elapsed.TotalSeconds) s"
if ($ok.Count -lt 50) { 'Muy pocos mercados todavia'; return }
$cut = $ok[[int]($ok.Count * $TrainFrac)].W
$train = New-Object 'System.Collections.Generic.List[Fst.Market]'; $test = New-Object 'System.Collections.Generic.List[Fst.Market]'
foreach ($m in $ok) { if ($m.W -lt $cut) { $train.Add($m) } else { $test.Add($m) } }
"Entrenamiento: $($train.Count) mercados hasta $([DateTimeOffset]::FromUnixTimeSeconds($cut).UtcDateTime.ToString('yyyy-MM-dd HH:mm')) UTC | Prueba: $($test.Count)"
"Referencia: Up gano en {0:P1} de los mercados" -f (@($ok | Where-Object { $_.UpWon }).Count / $ok.Count)

$results = New-Object System.Collections.Generic.List[object]
function Add-Result($family, $name, $trainBets, $testBets) {
    $tr = @($trainBets); $te = @($testBets)
    $trP = ($tr | Measure-Object Pnl -Sum).Sum; $teP = ($te | Measure-Object Pnl -Sum).Sum
    $results.Add([pscustomobject]@{ fam = $family; name = $name; nTr = $tr.Count; roiTr = $(if ($tr.Count) { $trP / $tr.Count } else { 0 }); nTe = $te.Count; roiTe = $(if ($te.Count) { $teP / $te.Count } else { 0 })
        winTe = $(if ($te.Count) { @($te | Where-Object { $_.Won }).Count / $te.Count } else { 0 }); pxTe = $(if ($te.Count) { ($te | Measure-Object Price -Average).Average } else { 0 }); pnlTe = $teP })
}
$secs = if ($T -eq 900) { @(@(300, 600), @(600, 780), @(720, 840), @(780, 870), @(840, 885)) } else { @(@(60, 180), @(120, 240), @(180, 270), @(240, 290)) }
# 1) Modelo vs mercado
foreach ($w in $secs) { foreach ($e in 0.03, 0.06, 0.10) { foreach ($vm in 30, 120) {
    $n = "modelo s$($w[0])-$($w[1]) ventaja>=$e vol$($vm)m"
    Add-Result 'modelo' $n ([Fst.Eng]::RunModel($train, $btc, $w[0], $w[1], $e, $vm, 0.05, 0.95)) ([Fst.Eng]::RunModel($test, $btc, $w[0], $w[1], $e, $vm, 0.05, 0.95))
} } }
"modelo listo ($([int]$sw.Elapsed.TotalSeconds) s)"
# 2) Favorito / no favorito del mercado en un momento fijo, por tramo de precio
$favSecs = if ($T -eq 900) { @(300, 600, 720, 810, 870) } else { @(60, 150, 210, 260, 285) }
foreach ($s in $favSecs) { foreach ($b in @(@(0.50, 0.60), @(0.60, 0.70), @(0.70, 0.80), @(0.80, 0.90), @(0.90, 0.97))) { foreach ($ud in $false, $true) {
    $n = "$(if ($ud) { 'no favorito' } else { 'favorito' }) en s$s, favorito a $([int]($b[0]*100))-$([int]($b[1]*100))c"
    Add-Result 'favorito' $n ([Fst.Eng]::RunFavorite($train, $s, $b[0], $b[1], $ud)) ([Fst.Eng]::RunFavorite($test, $s, $b[0], $b[1], $ud))
} } }
"favorito listo ($([int]$sw.Elapsed.TotalSeconds) s)"
# 3) Retraso de Polymarket frente a Binance
foreach ($w in $secs) { foreach ($look in 10, 30) { foreach ($z in 1.5, 2.5) { foreach ($mv in 0.0, 0.03) {
    $n = "retraso s$($w[0])-$($w[1]) mira $($look)s z>=$z PM se movio<=$mv"
    Add-Result 'retraso' $n ([Fst.Eng]::RunLag($train, $btc, $w[0], $w[1], $look, $z, $mv)) ([Fst.Eng]::RunLag($test, $btc, $w[0], $w[1], $look, $z, $mv))
} } } }
"retraso listo ($([int]$sw.Elapsed.TotalSeconds) s)"
# 4) Modelo aprendido (regresion logistica), entrenado solo con los dias de entrenamiento
$learnSecs = if ($T -eq 900) { @(300, 600, 720, 810, 870) } else { @(60, 150, 210, 260, 285) }
"`n=== Modelo aprendido: calidad de prediccion en la PRUEBA (Brier: mas bajo = mejor) ==="
foreach ($s in $learnSecs) {
    $wts = [Fst.Eng]::Fit($train, $btc, $s)
    "  segundo $s : $([Fst.Eng]::Brier($test, $btc, $wts, $s))"
    foreach ($e in 0.02, 0.05, 0.10) { Add-Result 'aprendido' "aprendido en s$s ventaja>=$e" ([Fst.Eng]::RunLogit($train, $btc, $wts, $s, $e)) ([Fst.Eng]::RunLogit($test, $btc, $wts, $s, $e)) }
}
"aprendido listo ($([int]$sw.Elapsed.TotalSeconds) s)"

$results | Export-Csv (Join-Path $Data "resultados-$Market.csv") -NoTypeInformation -Encoding UTF8
"`n=== Las $Top mejores en ENTRENAMIENTO (con al menos 100 apuestas) y como les fue en la PRUEBA ==="
$results | Where-Object { $_.nTr -ge 100 } | Sort-Object roiTr -Descending | Select-Object -First $Top | ForEach-Object {
    '{0,-62} entrenam. n={1,5} ROI={2,7:P1} | PRUEBA n={3,5} ROI={4,7:P1} acierto={5,4:P0} precio={6,4:P0} P&L={7,8:N2}' -f $_.name, $_.nTr, $_.roiTr, $_.nTe, $_.roiTe, $_.winTe, $_.pxTe, $_.pnlTe }
"`n=== Por familia: mejor en entrenamiento y su prueba ==="
foreach ($g in ($results | Where-Object { $_.nTr -ge 100 } | Group-Object fam)) { $b = $g.Group | Sort-Object roiTr -Descending | Select-Object -First 1
    '{0,-10} {1,-62} entrenam. ROI={2,7:P1} | PRUEBA n={3,5} ROI={4,7:P1}' -f $g.Name, $b.name, $b.roiTr, $b.nTe, $b.roiTe }
"`n=== Cuantas configuraciones dan ganancia en la prueba (de las que la dieron en entrenamiento) ==="
$pos = @($results | Where-Object { $_.nTr -ge 100 -and $_.roiTr -gt 0 }); "$(@($pos | Where-Object { $_.roiTe -gt 0 }).Count) de $($pos.Count)"
"Tiempo total: $([int]$sw.Elapsed.TotalSeconds) s"
