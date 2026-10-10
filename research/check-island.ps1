# Comprueba configuraciones concretas de "retraso" en TODO el periodo: por semana y con precio de compra peor
param([ValidateSet('m15', 'm5')][string]$Market = 'm15', [string[]]$Configs = @('600,840,10,2.0', '600,780,15,2.0', '660,840,10,2.5'))
$ErrorActionPreference = 'Stop'
$Data = Join-Path $PSScriptRoot 'data'
if (-not ('Fst.Eng' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Engine.cs') -ReferencedAssemblies System.Core }
$T = if ($Market -eq 'm15') { 900 } else { 300 }
$btc = New-Object Fst.Btc (Join-Path $Data 'btc1s')
$ms = New-Object 'System.Collections.Generic.List[Fst.Market]'
foreach ($m in ([Fst.Eng]::Load((Join-Path $Data $Market), $T, $btc) | Where-Object { $_.Ok } | Sort-Object W)) { $ms.Add($m) }
"Mercados $Market : $($ms.Count)"
foreach ($cfg in $Configs) {
    $a, $b, $look, $z = $cfg -split ','
    $bt = @([Fst.Eng]::RunLag($ms, $btc, [int]$a, [int]$b, [int]$look, [double]$z, 0.0))
    $p = ($bt | Measure-Object Pnl -Sum).Sum
    "`n=== segundos $a-$b, mira ${look}s, z>=$z : n=$($bt.Count) acierto={0:P0} precio={1:P0} P&L={2:N2} ROI={3:P1} ===" -f (@($bt | Where-Object { $_.Won }).Count / $bt.Count), ($bt | Measure-Object Price -Average).Average, $p, ($p / $bt.Count)
    $weeks = foreach ($g in ($bt | Group-Object { $d = [DateTimeOffset]::FromUnixTimeSeconds($_.W).UtcDateTime; $d.AddDays(-[int]$d.DayOfWeek).ToString('MM-dd') } | Sort-Object Name)) {
        $q = ($g.Group | Measure-Object Pnl -Sum).Sum; '{0}: {1,3} ap. {2,6:P0}' -f $g.Name, $g.Count, ($q / $g.Count) }
    "   por semana: " + ($weeks -join ' | ')
    "   semanas con ganancia: $(@($weeks | Where-Object { $_ -notmatch '-\d' }).Count) de $(@($weeks).Count)"
    foreach ($extra in 0.01, 0.02, 0.03) {
        $q = 0; foreach ($x in $bt) { $px = [Math]::Min(0.999, $x.Price + $extra); $sh = 1 / $px; $q += $(if ($x.Won) { $sh - 1 } else { -1 }) - $sh * [Fst.Eng]::Fee($px) }
        '   pagando {0}c mas: ROI={1:P1}' -f ($extra * 100), ($q / $bt.Count) }
    # Distribucion por hora del dia (UTC) en 4 bloques
    $hrs = foreach ($g in ($bt | Group-Object { [int][Math]::Floor([DateTimeOffset]::FromUnixTimeSeconds($_.W).UtcDateTime.Hour / 6) } | Sort-Object Name)) { $q = ($g.Group | Measure-Object Pnl -Sum).Sum; '{0:00}-{1:00}h UTC: {2} ap. {3:P0}' -f ([int]$g.Name * 6), ([int]$g.Name * 6 + 6), $g.Count, ($q / $g.Count) }
    "   por horario: " + ($hrs -join ' | ')
}
