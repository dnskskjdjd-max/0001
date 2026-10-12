# Sesgo de seleccion: el "mercado principal" se eligio por el volumen FINAL, que incluye lo operado durante el partido.
# Si el partido se pone interesante para un mercado (p. ej. el empate o el no favorito ganando), ese mercado acumula mas
# volumen y queda elegido "porque gano". Prueba: mismas reglas sin elegir por volumen (todos los mercados del partido).
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'SportsEngine.cs') -ReferencedAssemblies System.Core
$raw = [Fsp.Eng]::Load((Join-Path $PSScriptRoot 'data\sports'))
$main = New-Object 'System.Collections.Generic.List[Fsp.Mk]'
foreach ($g in ($raw | Group-Object { "$($_.Ev)|$($_.Type)" })) { $main.Add(($g.Group | Sort-Object Vol -Descending | Select-Object -First 1)) }
$allList = New-Object 'System.Collections.Generic.List[Fsp.Mk]'; foreach ($x in $raw) { $allList.Add($x) }
function Kind($b) { if ($b.M.League -ne 'soccer') { return $b.M.League }; if ($b.M.Slug -match '-draw$') { return 'futbol empate' }; if (($b.Side0 -and $b.M.O0 -eq 'No') -or (-not $b.Side0 -and $b.M.O1 -eq 'No')) { return 'futbol No' }; return 'futbol Si' }
function Rep($name, $b) { $b = @($b); if (-not $b.Count) { "{0,-40} n=0" -f $name; return }; $p = ($b | Measure-Object Pnl -Sum).Sum
    '{0,-40} n={1,5} gano={2,5:P0} precio={3,5:P0} ROI={4,7:P1}' -f $name, $b.Count, (@($b | Where-Object Won).Count / $b.Count), ($b | Measure-Object Price -Average).Average, ($p / $b.Count) }
foreach ($ty in 'moneyline', 'spreads', 'totals') {
    $selMain = @([Fsp.Eng]::Band($main, '*', $ty, 120, 0.20, 0.35))
    $selAll = @([Fsp.Eng]::Band($allList, '*', $ty, 120, 0.20, 0.35))
    "=== $ty ==="
    Rep '  mercado principal (volumen final)' $selMain
    Rep '  todos los mercados (sin elegir)' $selAll
    if ($ty -eq 'moneyline') {
        foreach ($k in 'futbol Si', 'futbol No', 'futbol empate', 'tennis', 'ufc', 'nfl') {
            Rep "    $k - principal" @($selMain | Where-Object { (Kind $_) -eq $k })
            Rep "    $k - todos" @($selAll | Where-Object { (Kind $_) -eq $k })
        }
    } else {
        foreach ($lg in 'soccer', 'mlb', 'nfl', 'cfb') {
            Rep "    $lg - principal" @($selMain | Where-Object { $_.M.League -eq $lg })
            Rep "    $lg - todos" @($selAll | Where-Object { $_.M.League -eq $lg })
        }
    }
}
