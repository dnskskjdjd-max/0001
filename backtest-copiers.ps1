# Simulacion hacia atras de los copiadores: que habria pasado copiando a un apostador con las reglas de copier.ps1.
# Uso:  .\backtest-copiers.ps1 [-Days 180] [-Extra 'Nombre|wallet|Categoria', ...]
#   Sin -Extra prueba los copiadores de copiers/*.json; con -Extra prueba ademas otros apostadores/categorias.
# Reglas simuladas (las mismas que el copiador real):
#   - Entra cuando el apostador acumula >= minTraderUsd en un lado del mercado (una copia por mercado, el primer lado).
#   - El copiador corre cada 5 min: precio de entrada = precio historico ~5 min despues + 1c de diferencial.
#   - No copia si el partido ya empezo (gameStartTime).
#   - Si el apostador vende (su posicion baja a < 20% del maximo) antes del final, se vende a su precio - 1c.
#   - Si no, se espera el resultado; las que siguen abiertas se valoran a precio actual.
# Resultado: data/backtest-copiers.json y un resumen en pantalla.
param([int]$Days = 180, [string[]]$Extra = @())
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = $PSScriptRoot
. (Join-Path $Root 'categories.ps1')
$H = @{ 'User-Agent' = 'Mozilla/5.0' }
$Api = 'https://data-api.polymarket.com'; $Gamma = 'https://gamma-api.polymarket.com/markets'; $Clob = 'https://clob.polymarket.com'
$LagSec = 300; $Spread = 0.01

function J($u) {
    for ($i = 1; $i -le 3; $i++) {
        try { $r = Invoke-WebRequest -UseBasicParsing $u -Headers $H -TimeoutSec 60; return (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()))) | ForEach-Object { $_ } }
        catch { if ($i -eq 3) { throw }; Start-Sleep -Seconds (3 * $i) }
    }
}
function ToUtc($s) { if (-not $s) { return $null }; try { [DateTimeOffset]::Parse("$s").ToUnixTimeSeconds() } catch { $null } }

# Operaciones de una billetera en los ultimos $Days dias (se pagina hacia atras con 'end')
$TradeCache = @{}
function Get-Trades($wallet) {
    if ($TradeCache.ContainsKey($wallet)) { return $TradeCache[$wallet] }
    $cut = [DateTimeOffset]::UtcNow.AddDays(-$Days).ToUnixTimeSeconds(); $end = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60
    $all = New-Object System.Collections.ArrayList; $seen = @{}
    while ($true) {
        $pg = @(J "$Api/activity?user=$wallet&type=TRADE&limit=500&end=$end")
        if (-not $pg.Count) { break }
        foreach ($t in $pg) { $k = "$($t.transactionHash)|$($t.asset)|$($t.size)"; if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; [void]$all.Add($t) } }
        $min = ($pg | Measure-Object timestamp -Minimum).Minimum
        if ($min -le $cut -or $pg.Count -lt 500) { break }
        $end = [int64]$min   # el limite repite el segundo frontera; los duplicados se descartan arriba
    }
    $res = @($all | Where-Object { $_.timestamp -ge $cut } | Sort-Object timestamp)
    $TradeCache[$wallet] = $res; return $res
}

function Get-GammaBySlug($slugs) {
    $res = @{}; $list = @($slugs | Select-Object -Unique)
    foreach ($extra in '', '&closed=true') {
        $pending = @($list | Where-Object { -not $res.ContainsKey($_) })
        for ($i = 0; $i -lt $pending.Count; $i += 20) {
            $chunk = $pending[$i..([Math]::Min($i + 19, $pending.Count - 1))]
            $qs = ($chunk | ForEach-Object { 'slug=' + [Uri]::EscapeDataString($_) }) -join '&'
            foreach ($m in @(J "$Gamma`?$qs&limit=100$extra")) { if ($m.slug) { $res[$m.slug] = $m } }
        }
    }
    return $res
}
function Get-OutcomePrice($g, $outcome) {
    if (-not $g -or -not $g.outcomes) { return $null }
    $outs = @((ConvertFrom-Json $g.outcomes) | ForEach-Object { $_ }); $px = @((ConvertFrom-Json $g.outcomePrices) | ForEach-Object { $_ })
    for ($i = 0; $i -lt $outs.Count; $i++) { if ("$($outs[$i])".ToLower() -eq "$outcome".ToLower()) { return [double]$px[$i] } }
    return $null
}
# Precio historico del token cerca de un instante (primer punto >= ts); $null si no hay datos
function Get-HistPrice($asset, $ts) {
    try {
        $hst = J "$Clob/prices-history?market=$asset&startTs=$($ts - 60)&endTs=$($ts + 1800)&fidelity=1"
        $pt = @($hst.history | Where-Object { $_.t -ge $ts } | Sort-Object t | Select-Object -First 1)
        if ($pt.Count) { return [double]$pt[0].p }
    } catch {}
    return $null
}

function Invoke-Backtest($name, $wallet, $category, $stake = 5, $minUsd = 1000) {
    $trades = @(Get-Trades $wallet | Where-Object { (Get-Category "$($_.slug) $($_.eventSlug) $($_.title)") -eq $category })
    $byMarket = $trades | Group-Object conditionId
    $copies = New-Object System.Collections.ArrayList
    foreach ($g in $byMarket) {
        $tr = @($g.Group | Sort-Object timestamp)
        $net = @{}; $entry = $null
        foreach ($t in $tr) {   # primer lado que acumula >= minUsd (costo neto de compras menos ventas)
            $o = "$($t.outcome)"; if (-not $net.ContainsKey($o)) { $net[$o] = 0.0 }
            $net[$o] += $(if ($t.side -eq 'BUY') { [double]$t.usdcSize } else { -[double]$t.usdcSize })
            if ($net[$o] -ge $minUsd) { $entry = $t; break }
        }
        if (-not $entry) { continue }
        [void]$copies.Add([pscustomobject]@{ trades = $tr; entry = $entry; outcome = "$($entry.outcome)"; slug = $entry.slug; title = $entry.title })
    }
    $gm = Get-GammaBySlug @($copies | ForEach-Object { $_.slug })
    $rows = foreach ($c in $copies) {
        $g = $gm[$c.slug]; $t0 = [int64]$c.entry.timestamp; $tc = $t0 + $LagSec
        $gs = ToUtc $g.gameStartTime
        if ($gs -and $tc -ge $gs) { continue }   # el copiador no entra con el partido empezado
        $hp = Get-HistPrice $c.entry.asset $tc
        $px = [Math]::Min(0.99, $(if ($null -ne $hp) { $hp } else { [double]$c.entry.price + 0.02 }) + $Spread)
        $pxHis = [double]$c.entry.price
        # Salida espejo: su posicion en ese lado (en acciones) cae por debajo del 20% del maximo alcanzado
        $size = 0.0; $peak = 0.0; $exit = $null
        foreach ($t in $c.trades) {
            if ("$($t.outcome)" -ne $c.outcome) { continue }
            $size += $(if ($t.side -eq 'BUY') { [double]$t.size } else { -[double]$t.size })
            if ($size -gt $peak) { $peak = $size }
            if ([int64]$t.timestamp -gt $tc -and $t.side -eq 'SELL' -and $size -lt 0.2 * $peak) { $exit = $t; break }
        }
        $final = Get-OutcomePrice $g $c.outcome
        $status = 'open'; $pnl = $null
        if ($exit) { $ex = [Math]::Max(0.0, [double]$exit.price - $Spread); $status = 'sold'; $pnl = $stake * ($ex / $px - 1) }
        elseif ($g.closed -eq $true -and $null -ne $final -and $final -ge 0.99) { $status = 'won'; $pnl = $stake * (1 / $px - 1) }
        elseif ($g.closed -eq $true -and $null -ne $final -and $final -le 0.01) { $status = 'lost'; $pnl = -$stake }
        elseif ($null -ne $final) { $pnl = $stake * ($final / $px - 1) }
        [pscustomobject]@{ trader = $name; category = $category; title = $c.title; outcome = $c.outcome
            entryAt = [DateTimeOffset]::FromUnixTimeSeconds($t0).ToString('yyyy-MM-dd HH:mm'); hisPrice = [Math]::Round($pxHis, 4)
            price = [Math]::Round($px, 4); status = $status; pnl = $(if ($null -ne $pnl) { [Math]::Round($pnl, 4) } else { $null })
            pnlNoLag = $(if ($status -eq 'won') { $stake * (1 / [Math]::Max(0.01, $pxHis) - 1) } elseif ($status -eq 'lost') { -$stake } else { $null }) }
    }
    return @($rows)
}

$targets = @()
foreach ($f in @(Get-ChildItem (Join-Path $Root 'copiers\*.json'))) {
    $c = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $targets += , @($c.traderName, $c.traderWallet, $c.category, $c.stake, $c.minTraderUsd)
}
foreach ($x in $Extra) { $p = $x.Split('|'); $targets += , @($p[0], $p[1], $p[2], 5, 1000) }

$all = @(); $summary = @()
foreach ($t in $targets) {
    Write-Host "Simulando $($t[0]) en $($t[2])..."
    $r = @(Invoke-Backtest $t[0] $t[1] $t[2] $t[3] $t[4]); $all += $r
    $done = @($r | Where-Object { $_.status -in 'won', 'lost', 'sold' }); $settled = @($done | Where-Object { $_.status -ne 'sold' })
    $staked = $done.Count * $t[3]; $pnl = ($done | Measure-Object pnl -Sum).Sum
    $summary += [pscustomobject]@{ copiador = "$($t[0]) · $($t[2])"; copias = $r.Count; cerradas = $done.Count
        ganadas = @($settled | Where-Object status -eq 'won').Count; perdidas = @($settled | Where-Object status -eq 'lost').Count; vendidas = @($done | Where-Object status -eq 'sold').Count
        acierto = $(if ($settled.Count) { [Math]::Round(@($settled | Where-Object status -eq 'won').Count / $settled.Count, 3) } else { $null })
        precioMedio = $(if ($settled.Count) { [Math]::Round(($settled | Measure-Object price -Average).Average, 3) } else { $null })
        ganancia = [Math]::Round([double]$pnl, 2); roi = $(if ($staked) { [Math]::Round($pnl / $staked, 3) } else { $null })
        costoRetraso = $(if ($r.Count) { [Math]::Round((($r | ForEach-Object { $_.price - $_.hisPrice }) | Measure-Object -Average).Average * 100, 1) } else { $null })
        abiertas = @($r | Where-Object status -eq 'open').Count }
}
$out = @{ generatedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); days = $Days; summary = $summary; copies = $all }
[IO.File]::WriteAllText((Join-Path $Root 'data\backtest-copiers.json'), (ConvertTo-Json -InputObject $out -Depth 5 -Compress), (New-Object Text.UTF8Encoding $false))
$summary | Format-Table -AutoSize | Out-String -Width 250
