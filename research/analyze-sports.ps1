# Investigacion de estrategias deportivas propias (sin FirePolymarket) con research/data/sports.
# Divide por fecha de inicio: primeros 2/3 = entrenamiento, ultimo 1/3 = prueba. Solo cuenta lo que gana en la prueba.
param([double]$TrainFrac = 0.67, [int]$MinN = 60, [int]$Top = 25)
$ErrorActionPreference = 'Stop'
if (-not ('Fsp.Eng' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'SportsEngine.cs') -ReferencedAssemblies System.Core }
$raw = [Fsp.Eng]::Load((Join-Path $PSScriptRoot 'data\sports'))
# Solo el mercado principal de cada tipo por partido (el de mas volumen): las lineas alternativas del mismo partido
# (spread -3.5, -4.5, -5.5...) se mueven juntas y una sola sorpresa contaria como muchos aciertos
$all = New-Object 'System.Collections.Generic.List[Fsp.Mk]'
foreach ($g in ($raw | Group-Object { "$($_.Ev)|$($_.Type)" })) { $all.Add(($g.Group | Sort-Object Vol -Descending | Select-Object -First 1)) }
$all = [System.Collections.Generic.List[Fsp.Mk]]@($all | Sort-Object Start)
"Mercados: $($raw.Count) descargados -> $($all.Count) principales (uno por tipo y partido) de $(@($all | Select-Object -ExpandProperty Ev -Unique).Count) partidos"
$all | Group-Object League | ForEach-Object { '  {0,-18} {1,5} mercados ({2})' -f $_.Name, $_.Count, (($_.Group | Group-Object Type | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ') }
$cut = $all[[int]($all.Count * $TrainFrac)].Start
$train = New-Object 'System.Collections.Generic.List[Fsp.Mk]'; $test = New-Object 'System.Collections.Generic.List[Fsp.Mk]'
foreach ($m in $all) { if ($m.Start -lt $cut) { $train.Add($m) } else { $test.Add($m) } }
"Entrenamiento: $($train.Count) hasta $([DateTimeOffset]::FromUnixTimeSeconds($cut).UtcDateTime.ToString('yyyy-MM-dd')) | Prueba: $($test.Count)"

"`n=== Calibracion en TODO el periodo, 30 min antes del inicio (todas las ligas): gano vs precio ==="
[Fsp.Eng]::Calib($all, '*', '*', 30)
foreach ($lg in ($all | Group-Object League | Where-Object Count -ge 200 | ForEach-Object Name)) { "-- $lg (30 min antes)"; [Fsp.Eng]::Calib($all, $lg, '*', 30) }

$leagues = @('*') + @($all | Group-Object League | Where-Object Count -ge 150 | ForEach-Object Name)
$types = @('*', 'moneyline', 'spreads', 'totals')
$res = New-Object System.Collections.Generic.List[object]
function Add-R($fam, $name, $a, $b) {
    $a = @($a); $b = @($b)
    $ra = if ($a.Count) { ($a | Measure-Object Pnl -Sum).Sum / $a.Count } else { 0 }; $rb = if ($b.Count) { ($b | Measure-Object Pnl -Sum).Sum / $b.Count } else { 0 }
    $evB = @($b | ForEach-Object { $_.M.Ev } | Select-Object -Unique).Count
    $res.Add([pscustomobject]@{ fam = $fam; name = $name; nTr = $a.Count; roiTr = $ra; nTe = $b.Count; evTe = $evB; roiTe = $rb; winTe = $(if ($b.Count) { @($b | Where-Object Won).Count / $b.Count } else { 0 }); pxTe = $(if ($b.Count) { ($b | Measure-Object Price -Average).Average } else { 0 }) })
}
$bands = @(@(0.05, 0.20), @(0.20, 0.35), @(0.35, 0.50), @(0.50, 0.65), @(0.65, 0.80), @(0.80, 0.90), @(0.90, 0.97))
foreach ($lg in $leagues) { foreach ($ty in $types) {
    foreach ($mb in 1440, 360, 120, 30, 5) { foreach ($bd in $bands) {
        $n = "precio $([int]($bd[0]*100))-$([int]($bd[1]*100))c a $mb min | $lg | $ty"
        Add-R 'precio' $n ([Fsp.Eng]::Band($train, $lg, $ty, $mb, $bd[0], $bd[1])) ([Fsp.Eng]::Band($test, $lg, $ty, $mb, $bd[0], $bd[1]))
    } }
    foreach ($fr in @(@(1440, 60), @(360, 60), @(120, 10), @(60, 5))) { foreach ($d in 0.03, 0.06, 0.10) { foreach ($fol in $true, $false) {
        $n = "$(if ($fol) { 'seguir' } else { 'contra' }) movimiento >=$([int]($d*100))c de $($fr[0]) a $($fr[1]) min | $lg | $ty"
        Add-R 'impulso' $n ([Fsp.Eng]::Momentum($train, $lg, $ty, $fr[0], $fr[1], $d, $fol)) ([Fsp.Eng]::Momentum($test, $lg, $ty, $fr[0], $fr[1], $d, $fol))
    } } }
} }
$res | Export-Csv (Join-Path $PSScriptRoot 'data\resultados-deportes.csv') -NoTypeInformation -Encoding UTF8
"`nConfiguraciones probadas: $($res.Count)"
"`n=== Las $Top mejores en ENTRENAMIENTO (n>=$MinN en ambos) y su PRUEBA ==="
$res | Where-Object { $_.nTr -ge $MinN -and $_.nTe -ge [int]($MinN / 2) } | Sort-Object roiTr -Descending | Select-Object -First $Top | ForEach-Object {
    '{0,-70} entr. {1,7:P1} ({2,4}) | PRUEBA {3,7:P1} ({4,4} merc., {5,3} partidos) gano {6:P0} precio {7:P0}' -f $_.name, $_.roiTr, $_.nTr, $_.roiTe, $_.nTe, $_.evTe, $_.winTe, $_.pxTe }
$pos = @($res | Where-Object { $_.nTr -ge $MinN -and $_.nTe -ge [int]($MinN / 2) -and $_.roiTr -gt 0 })
"`nCon ganancia en entrenamiento: $($pos.Count); de ellas tambien en la prueba: $(@($pos | Where-Object { $_.roiTe -gt 0 }).Count)"
"Con ganancia > +5% en ambos: " ; $res | Where-Object { $_.nTr -ge $MinN -and $_.nTe -ge [int]($MinN / 2) -and $_.roiTr -gt 0.05 -and $_.roiTe -gt 0.05 } | Sort-Object roiTe -Descending | Select-Object -First 30 | ForEach-Object {
    '   {0,-70} entr. {1,7:P1} ({2,4}) | PRUEBA {3,7:P1} ({4,4} merc., {5,3} partidos)' -f $_.name, $_.roiTr, $_.nTr, $_.roiTe, $_.nTe, $_.evTe }
