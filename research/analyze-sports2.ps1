# Investigacion deportiva rehecha SIN sesgo de seleccion (11 oct). Plan fijado ANTES de ver los resultados:
#  - Datos: data/sports2 = todos los mercados de ganador / spread / total de 60 dias, sin filtro de volumen.
#  - Momento de apuesta: 120 min antes del inicio (sensibilidad: 60 y 240). Precio con <= 30 min de antiguedad.
#    Compra al precio + 1c (sensibilidad: +2c) con la comision real del mercado.
#  - Solo informacion previa a la apuesta: precio e historial de precios (actividad de las 24 h previas). Nunca volumen.
#  - Division por fecha: primeros 2/3 de los partidos = descubrimiento; ultimo 1/3 = validacion.
#  - Una idea es CANDIDATA solo si: ROI >= +3% en descubrimiento con IC95 (remuestreando partidos) por encima de 0,
#    ROI >= +3% en validacion, y el total sigue positivo pagando +2c. Lo demas se considera ruido.
param([int]$MinBefore = 120)
$ErrorActionPreference = 'Stop'
if (-not ('Fsp2.Eng' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'SportsEngine2.cs') -ReferencedAssemblies System.Core }
$all = [Fsp2.Eng]::Load((Join-Path $PSScriptRoot 'data\sports2'))
$games = @($all | ForEach-Object { $_.Game } | Select-Object -Unique)
$starts = @($all | Group-Object Game | ForEach-Object { ($_.Group | Measure-Object Start -Minimum).Minimum } | Sort-Object)
$cut = $starts[[int]($starts.Count * 2 / 3)]
$fmtD = { param($u) [DateTimeOffset]::FromUnixTimeSeconds($u).UtcDateTime.ToString('yyyy-MM-dd') }
"Mercados: $($all.Count) | partidos: $($games.Count) | desde $(& $fmtD $starts[0]) hasta $(& $fmtD $starts[-1]) | validacion desde $(& $fmtD $cut)"
"Por liga y tipo: " + (($all | Group-Object { "$($_.League)/$($_.Type)" } | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')

function L($name, $b) { [Fsp2.Eng]::Line($name, [System.Collections.Generic.List[Fsp2.Bet]]@($b)) }
function Band($ms, $lo, $hi, $extra = 0.01, $minAct = 0, $mb = $MinBefore) {
    $l = New-Object 'System.Collections.Generic.List[Fsp2.Mk]'; foreach ($m in @($ms)) { $l.Add($m) }
    return @([Fsp2.Eng]::Band($l, $mb, $lo, $hi, $extra, 30, $minAct))
}
# Descubrimiento / validacion / +2c para un conjunto de mercados
function Test3($name, $ms, $lo, $hi, $one = $false) {
    $b1 = Band $ms $lo $hi; $b2 = Band $ms $lo $hi 0.02
    if ($one) { $b1 = @([Fsp2.Eng]::OnePerGame([System.Collections.Generic.List[Fsp2.Bet]]@($b1))); $b2 = @([Fsp2.Eng]::OnePerGame([System.Collections.Generic.List[Fsp2.Bet]]@($b2))) }
    L "$name | descubrimiento" @($b1 | Where-Object { $_.M.Start -lt $cut })
    L "$name | validacion" @($b1 | Where-Object { $_.M.Start -ge $cut })
    L "$name | total pagando +2c" $b2
}

"`n=== A. Calibracion: cuanto gana cada tramo de precio vs lo que dice el precio (120 min antes, todos los mercados) ==="
foreach ($ty in 'moneyline', 'spreads', 'totals') {
    "-- $ty"
    $ms = @($all | Where-Object { $_.Type -eq $ty })
    foreach ($lo in 0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85) { L ("   {0:N0}-{1:N0}c" -f ($lo * 100), ($lo * 100 + 10)) (Band $ms $lo ($lo + 0.10)) }
}

"`n=== B. No favorito 20-35c por liga y tipo (todos los mercados) ==="
foreach ($g in ($all | Group-Object { "$($_.League) $($_.Type)" } | Where-Object Count -ge 300 | Sort-Object Name)) { Test3 $g.Name $g.Group 0.20 0.35 }

"`n=== C. Futbol, mercado de ganador por subtipo ==="
foreach ($sub in 'empate', 'local', 'visitante') {
    $ms = @($all | Where-Object { $_.League -eq 'soccer' -and $_.Sub -eq $sub })
    Test3 "$sub no favorito 20-35c" $ms 0.20 0.35
    Test3 "$sub favorito 65-80c" $ms 0.65 0.80
}

"`n=== D. No favorito 20-35c segun actividad previa (cambios de precio en las 24 h antes) ==="
$ub = Band $all 0.20 0.35
$acts = @($ub | ForEach-Object { $_.Act } | Sort-Object); $t1 = $acts[[int]($acts.Count / 3)]; $t2 = $acts[[int]($acts.Count * 2 / 3)]
L "  poca actividad (<= $t1)" @($ub | Where-Object { $_.Act -le $t1 })
L "  media" @($ub | Where-Object { $_.Act -gt $t1 -and $_.Act -le $t2 })
L "  mucha actividad (> $t2)" @($ub | Where-Object { $_.Act -gt $t2 })

"`n=== E. Las 3 estrategias en vivo, rehechas sin sesgo (una por partido, la de mas actividad previa) ==="
Test3 'Ganador tenis/futbol/UFC/NFL' @($all | Where-Object { $_.Type -eq 'moneyline' -and $_.League -in 'tennis', 'soccer', 'ufc', 'nfl' }) 0.20 0.35 $true
Test3 'Ganador sin tenis' @($all | Where-Object { $_.Type -eq 'moneyline' -and $_.League -in 'soccer', 'ufc', 'nfl' }) 0.20 0.35 $true
Test3 'Spreads y totales' @($all | Where-Object { $_.Type -ne 'moneyline' -and $_.League -in 'nfl', 'cfb', 'mlb', 'nba', 'nhl', 'wnba', 'soccer', 'ufc' }) 0.20 0.35 $true

"`n=== F. Sensibilidad al momento de apuesta (no favorito 20-35c, todos los mercados) ==="
foreach ($mb in 60, 240) { L "  $mb min antes" (Band $all 0.20 0.35 0.01 0 $mb) }
