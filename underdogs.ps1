# Estrategias propias "No favorito" (sin FirePolymarket), en simulacion. Configuracion en underdogs.json.
# Cada corrida (run-local.ps1, cada 5 min):
#   1. Busca en Polymarket los partidos que empiezan entre minBefore y maxBefore minutos (ganador, spread, total).
#   2. Por partido y tipo se queda con el mercado principal (el de mas volumen).
#   3. Lee el libro de ordenes real: si uno de los dos lados se puede comprar entre lo y hi (20-35c), apuesta $stake
#      a ese lado (una apuesta por partido en cada estrategia), con la comision real del mercado.
#   4. Resuelve las apuestas de partidos terminados y arma data/underdogs.js para la pestana "No favoritos".
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$DataDir = Join-Path $Root 'data'
. (Join-Path $Root 'crypto-common.ps1')   # Get-CJson, Get-JArr, Get-Books, Get-FillPrice, Write-CFileAtomic, Read-CJsonArray
$LogFile = Join-Path $DataDir 'log.txt'
$Cfg = Get-Content (Join-Path $Root 'underdogs.json') -Raw -Encoding UTF8 | ConvertFrom-Json
function Log($m) { Write-CLog $LogFile 'no-favoritos' $m }
$Inv = [Globalization.CultureInfo]::InvariantCulture
$nowUtc = [DateTime]::UtcNow
$now = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Liga a partir del prefijo del identificador del mercado (nfl-..., atp-..., epl-...)
$prefLeague = @{}
foreach ($p in $Cfg.prefixes.PSObject.Properties) { foreach ($x in @($p.Value)) { $prefLeague["$x"] = $p.Name } }
function Get-League($slug) { $pre = ($slug -split '-')[0]; if ($prefLeague.ContainsKey($pre)) { return $prefLeague[$pre] }; return $null }
function Get-EventKey($slug) { if ($slug -match '^(.*?-\d{4}-\d{2}-\d{2})') { return $Matches[1] }; return $slug }
function Get-Start($m) { try { return [DateTimeOffset]::Parse(("$($m.gameStartTime)" -replace '\+00$', '+00:00'), $Inv).UtcDateTime } catch { return $null } }
function Get-Rate($m) { if ($m.feesEnabled -eq $true -and $m.feeSchedule -and $null -ne $m.feeSchedule.rate) { return [double]$m.feeSchedule.rate }; return 0.0 }

$ledgers = @{}
foreach ($s in $Cfg.strategies) { $ledgers[$s.id] = [System.Collections.ArrayList]@(Read-CJsonArray (Join-Path $DataDir "underdog-$($s.id)-bets.json")) }
$newBets = 0; $resolved = 0; $seen = 0

try {
    # 1. Partidos que empiezan pronto, por tipo de mercado (la fecha de cierre de estos mercados es la hora de inicio)
    $from = $nowUtc.AddMinutes([double]$Cfg.minBefore - 10).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $to = $nowUtc.AddMinutes([double]$Cfg.maxBefore + 10).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $types = @($Cfg.strategies | ForEach-Object { $_.types } | ForEach-Object { $_ } | Sort-Object -Unique)
    $markets = New-Object System.Collections.Generic.List[object]
    foreach ($ty in $types) {
        for ($off = 0; $off -lt 2000; $off += 100) {
            $page = @(Get-CJson "https://gamma-api.polymarket.com/markets?sports_market_types=$ty&closed=false&end_date_min=$from&end_date_max=$to&limit=100&offset=$off" | ForEach-Object { $_ })
            foreach ($m in $page) { if ($m.gameStartTime -and $m.acceptingOrders -ne $false) { $markets.Add($m) } }
            if ($page.Count -lt 100) { break }
        }
    }
    # 2. Mercado principal por partido y tipo, dentro de la ventana de tiempo
    $main = @{}
    foreach ($m in $markets) {
        $lg = Get-League $m.slug; if (-not $lg) { continue }
        $st = Get-Start $m; if (-not $st) { continue }
        $minLeft = ($st - $nowUtc).TotalMinutes
        if ($minLeft -lt [double]$Cfg.minBefore -or $minLeft -gt [double]$Cfg.maxBefore) { continue }
        $k = "$(Get-EventKey $m.slug)|$($m.sportsMarketType)"
        if (-not $main.ContainsKey($k) -or [double]$m.volumeNum -gt [double]$main[$k].m.volumeNum) { $main[$k] = @{ m = $m; league = $lg; start = $st; minLeft = $minLeft; ev = (Get-EventKey $m.slug) } }
    }
    $seen = $main.Count
    # 3. Apuestas por estrategia
    foreach ($s in $Cfg.strategies) {
        $led = $ledgers[$s.id]
        $cands = @($main.Values | Where-Object { @($s.types) -contains $_.m.sportsMarketType -and @($s.leagues) -contains $_.league })
        # Prioridad dentro del partido: ganador, luego spread, luego total
        $cands = @($cands | Sort-Object { switch ($_.m.sportsMarketType) { 'moneyline' { 0 } 'spreads' { 1 } default { 2 } } })
        foreach ($c in $cands) {
            if ($led | Where-Object { $_.ev -eq $c.ev }) { continue }   # una apuesta por partido
            $tok = Get-JArr $c.m.clobTokenIds; $outs = Get-JArr $c.m.outcomes
            if ($tok.Count -ne 2) { continue }
            $books = Get-Books @("$($tok[0])", "$($tok[1])")
            foreach ($i in 0, 1) {
                $asks = $books["$($tok[$i])"].asks; if (-not $asks -or -not $asks.Count) { continue }
                $fill = Get-FillPrice $asks ([double]$Cfg.stake); if ($null -eq $fill) { continue }
                if ($fill -lt [double]$Cfg.lo -or $fill -gt [double]$Cfg.hi) { continue }
                $rate = Get-Rate $c.m; $stake = [double]$Cfg.stake
                $bids = $books["$($tok[$i])"].bids
                $bet = [pscustomobject]@{ id = "$($c.m.slug)|$i"; strategy = $s.id; slug = $c.m.slug; ev = $c.ev; league = $c.league; type = $c.m.sportsMarketType
                    line = $c.m.line; question = $c.m.question; side = $i; outcome = "$($outs[$i])"; token = "$($tok[$i])"; stake = $stake
                    price = [Math]::Round($fill, 4); bestBid = $(if ($bids -and $bids.Count) { [double]$bids[0].price } else { $null }); feeRate = $rate
                    fee = [Math]::Round($stake * $rate * (1 - $fill), 4); vol = [int]$c.m.volumeNum; start = $c.start.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    minBefore = [int]$c.minLeft; placedAt = $now; status = 'open'; pnl = $null; version = $Cfg.version }
                [void]$led.Add($bet); $newBets++
                Log "Apuesta [$($s.id)] $($c.league) $($c.m.sportsMarketType): `$$stake a '$($outs[$i])' a $([Math]::Round($fill * 100, 1))c | $($c.m.question) | empieza en $([int]$c.minLeft) min"
                break
            }
        }
    }
    # 4. Resultados (partidos que empezaron hace mas de 2 h)
    foreach ($s in $Cfg.strategies) {
        foreach ($b in @($ledgers[$s.id] | Where-Object { $_.status -eq 'open' -and [DateTimeOffset]::Parse($_.start, $Inv).UtcDateTime -lt $nowUtc.AddHours(-2) })) {
            $m = @(Get-CJson "https://gamma-api.polymarket.com/markets?slug=$($b.slug)&closed=true" | ForEach-Object { $_ }) | Select-Object -First 1
            if (-not $m -or -not $m.closed) { continue }
            $op = Get-JArr $m.outcomePrices; $pw = [double]$op[[int]$b.side]
            $won = $pw -ge 0.99
            if (-not $won -and $pw -gt 0.01) {
                if ($m.umaResolutionStatus -ne 'resolved') { continue }
                $b.status = 'void'; $b.pnl = [Math]::Round($b.stake * ($pw / $b.price - 1) - $b.fee, 4)   # resultado parcial (p. ej. 50/50)
            } else {
                $b.status = if ($won) { 'won' } else { 'lost' }
                $b.pnl = [Math]::Round($(if ($won) { $b.stake / $b.price - $b.stake } else { - $b.stake }) - $b.fee, 4)
            }
            $b | Add-Member -NotePropertyName resolvedAt -NotePropertyValue $now -Force
            $resolved++
            Log "Resuelta [$($s.id)] $($b.slug): '$($b.outcome)' -> $($b.status) ($([Math]::Round($b.pnl, 2)) USD)"
        }
    }
} catch {
    Log "ERROR: $($_.Exception.Message) (linea $($_.InvocationInfo.ScriptLineNumber))"
}

foreach ($s in $Cfg.strategies) { Write-CFileAtomic (Join-Path $DataDir "underdog-$($s.id)-bets.json") (ConvertTo-Json -InputObject @($ledgers[$s.id]) -Depth 5) }
$out = [ordered]@{ generatedAt = $now; cfg = $Cfg; seen = $seen; strategies = @($Cfg.strategies | ForEach-Object { [ordered]@{ id = $_.id; bets = @($ledgers[$_.id]) } }) }
Write-CFileAtomic (Join-Path $DataDir 'underdogs.js') ("window.UNDERDOGS = " + (ConvertTo-Json -InputObject $out -Depth 8 -Compress) + ";")
if ($newBets -or $resolved -or $nowUtc.Minute % 30 -lt 5) { Log "OK: $seen mercados principales en la ventana, $newBets apuestas nuevas, $resolved resueltas" }
