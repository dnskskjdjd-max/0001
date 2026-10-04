# Ligas: sigue los partidos de LaLiga y la Champions League directamente en Polymarket (FirePolymarket no los cubre).
# Por partido: precio de compra de local / empate / visitante, probabilidad de Vegas (odds.ps1) y consenso de ballenas
# (poseedores de Polymarket que estan en el top 1000 del ranking de deportes).
# Historial simulado aparte (data/league-bets.json): una apuesta por partido si se cumplen las reglas de $Rules.
# Corre despues del copiador (run-local.ps1); hace la consulta completa como mucho cada 15 minutos.
# (Este archivo se guarda con BOM UTF-8 para que PowerShell 5.1 lea bien las tildes.)
param([switch]$Force)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = $PSScriptRoot
$DataDir = Join-Path $Root 'data'
$LogFile = Join-Path $DataDir 'log.txt'
$BetsFile = Join-Path $DataDir 'league-bets.json'
$JsFile = Join-Path $DataDir 'leagues.js'
$StateFile = Join-Path $DataDir 'leagues-state.json'
$RankFile = Join-Path $DataDir 'sports-rank.json'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$H = @{ 'User-Agent' = 'Mozilla/5.0' }

$Leagues = @(
    @{ id = 'laliga'; name = 'LaLiga'; tag = 'la-liga'; prefix = 'lal'; odds = 'soccer_spain_la_liga' }
    @{ id = 'ucl'; name = 'Champions League'; tag = 'ucl'; prefix = 'ucl'; odds = 'soccer_uefa_champs_league' }
)
$Rules = [ordered]@{
    stake = 3; minEdge = 0.04; minAgree = 6; topN = 10; minRanked = 5; minBooks = 3
    minPrice = 0.10; maxPrice = 0.90; betWindowHours = 48; lookaheadDays = 10; minWhaleUsd = 50
}

function Log($msg) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [ligas] $msg"; Add-Content -Path $LogFile -Value $line -Encoding UTF8; Write-Host $line }
function ConvertTo-Hash($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) { $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }; return $h }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return , @($o | ForEach-Object { ConvertTo-Hash $_ }) }
    return $o
}
function Write-FileAtomic($path, $text) { $tmp = "$path.tmp"; [IO.File]::WriteAllText($tmp, $text, $Utf8); Move-Item -Force $tmp $path }
function J($u) {
    for ($i = 1; $i -le 3; $i++) {
        try { $r = Invoke-WebRequest -UseBasicParsing $u -Headers $H -TimeoutSec 60; return (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()))) | ForEach-Object { $_ } }
        catch { if ($i -eq 3) { throw }; Start-Sleep -Seconds (3 * $i) }
    }
}
. (Join-Path $Root 'categories.ps1')
. (Join-Path $Root 'odds.ps1')

# Nombres de equipos comparables: sin tildes, minusculas, sin palabras genericas ("CF", "Club", "de"...)
$StopWords = @('fc', 'cf', 'cd', 'rcd', 'ud', 'sd', 'sc', 'ac', 'as', 'afc', 'sad', 'club', 'de', 'del', 'la', 'el', 'the', 'balompie', 'futbol')
function Get-Tokens($s) {
    $t = "$s".Normalize([Text.NormalizationForm]::FormD)
    $t = -join ($t.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
    return @(($t.ToLower() -replace '[^a-z0-9 ]', ' ').Split(' ') | Where-Object { $_.Length -ge 3 -and $StopWords -notcontains $_ } |
        ForEach-Object { if ($Aliases.ContainsKey($_)) { $Aliases[$_] } else { $_ } })
}
# Mismo club con nombres distintos en Polymarket y en las casas de apuestas
$Aliases = @{ internazionale = 'inter'; milano = 'milan'; munchen = 'munich'; koln = 'cologne'; praha = 'prague'; lisboa = 'lisbon' }
function Get-Overlap($a, $b) { $ta = Get-Tokens $a; $tb = Get-Tokens $b; return @($ta | Where-Object { $tb -contains $_ }).Count }

# Ranking de deportes (top 1000 por ganancia historica), cacheado 24 h: billetera -> puesto
function Get-SportsRank {
    if (Test-Path $RankFile) {
        $c = ConvertTo-Hash (Get-Content $RankFile -Raw | ConvertFrom-Json)
        if ($c.at -and ((Get-Date).ToUniversalTime() - [DateTimeOffset]::Parse($c.at).UtcDateTime).TotalHours -lt 24) { return $c.rank }
    }
    $rank = @{}
    for ($o = 0; $o -lt 1000; $o += 50) {
        foreach ($x in @(J "https://data-api.polymarket.com/v1/leaderboard?timePeriod=ALL&orderBy=PNL&category=SPORTS&limit=50&offset=$o")) { $rank["$($x.proxyWallet)".ToLower()] = [int]$x.rank }
    }
    Write-FileAtomic $RankFile (ConvertTo-Json -InputObject @{ at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); rank = $rank } -Compress)
    return $rank
}

try {
    $now = (Get-Date).ToUniversalTime(); $nowIso = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $state = if (Test-Path $StateFile) { ConvertTo-Hash (Get-Content $StateFile -Raw | ConvertFrom-Json) } else { @{} }
    if (-not $Force -and $state.lastRun -and ($now - [DateTimeOffset]::Parse($state.lastRun).UtcDateTime).TotalMinutes -lt 14) { exit 0 }

    $bets = [ordered]@{}
    if (Test-Path $BetsFile) { foreach ($b in (ConvertTo-Hash (Get-Content $BetsFile -Raw -Encoding UTF8 | ConvertFrom-Json))) { if ($b -and $b.key) { $bets[$b.key] = $b } } }
    $rank = Get-SportsRank

    # 1. Partidos de los proximos dias (evento base "liga-local-visita-fecha" con 3 mercados: local, empate, visitante)
    $minD = $now.AddHours(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'); $maxD = $now.AddDays($Rules.lookaheadDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $games = @()
    foreach ($lg in $Leagues) {
        $evs = @(J "https://gamma-api.polymarket.com/events?tag_slug=$($lg.tag)&closed=false&end_date_min=$minD&end_date_max=$maxD&limit=300")
        foreach ($ev in @($evs | Where-Object { $_.slug -match "^$($lg.prefix)-[a-z0-9]+-[a-z0-9]+-\d{4}-\d{2}-\d{2}$" })) {
            $mk = @($ev.markets | Where-Object { $_.conditionId })
            if ($mk.Count -ne 3) { continue }
            $start = $null; try { $start = [DateTimeOffset]::Parse("$(@($mk)[0].gameStartTime)").UtcDateTime } catch {}
            $outs = foreach ($m in $mk) {
                $isDraw = "$($m.groupItemTitle)" -match '^Draw'
                $px = @((ConvertFrom-Json $m.outcomePrices) | ForEach-Object { [double]$_ })
                @{ name = $(if ($isDraw) { 'Empate' } else { "$($m.groupItemTitle)" }); draw = $isDraw; slug = $m.slug; conditionId = $m.conditionId
                   mid = $px[0]; ask = $(if ($null -ne $m.bestAsk) { [double]$m.bestAsk } else { $px[0] }); vegas = $null; agree = 0 }
            }
            $games += @{ league = $lg; slug = $ev.slug; title = $ev.title; start = $start; outs = @($outs) }
        }
    }

    # 2. Vegas: se consulta cada liga con partidos en las proximas 48 h (mismo presupuesto que odds.ps1)
    $need = @($games | Where-Object { $_.start -and $_.start -gt $now -and ($_.start - $now).TotalHours -le $Rules.betWindowHours } | ForEach-Object { $_.league.odds } | Select-Object -Unique)
    if ($need.Count) { try { Update-OddsCache $need } catch { Log "Cuotas: $($_.Exception.Message -replace 'apiKey=[^&\s]+', 'apiKey=***')" } }
    $cache = Get-OddsCache
    foreach ($m in $games) {
        $c = $cache[$m.league.odds]; if (-not $c -or -not $c.events) { continue }
        $teams = @($m.outs | Where-Object { -not $_.draw })
        foreach ($ev in $c.events) {
            if ($m.start) { try { if ([Math]::Abs(([DateTimeOffset]::Parse("$($ev.commence)").UtcDateTime - $m.start).TotalHours) -gt 30) { continue } } catch {} }
            $direct = (Get-Overlap $ev.home $teams[0].name) * (Get-Overlap $ev.away $teams[1].name)
            $swap = (Get-Overlap $ev.home $teams[1].name) * (Get-Overlap $ev.away $teams[0].name)
            if ($direct -eq 0 -and $swap -eq 0) { continue }
            foreach ($o in $m.outs) {
                $k = if ($o.draw) { @($ev.fair.Keys | Where-Object { $_ -eq 'Draw' }) | Select-Object -First 1 }
                     else { @($ev.fair.Keys | Where-Object { $_ -ne 'Draw' } | Sort-Object { -(Get-Overlap $_ $o.name) }) | Select-Object -First 1 }
                if ($k) { $o.vegas = [double]$ev.fair[$k] }
            }
            $m.books = $ev.books; break
        }
    }

    # 3. Ballenas (solo partidos dentro de la ventana de apuesta): por billetera rankeada, el resultado donde tiene mas valor en "Si"
    foreach ($m in @($games | Where-Object { $_.start -and $_.start -gt $now -and ($_.start - $now).TotalHours -le $Rules.betWindowHours })) {
        $best = @{}
        foreach ($o in $m.outs) {
            $blocks = @(J "https://data-api.polymarket.com/holders?market=$($o.conditionId)&limit=50")
            foreach ($blk in $blocks) {
                foreach ($hd in @($blk.holders)) {
                    if ([int]$hd.outcomeIndex -ne 0) { continue }   # solo poseedores del "Si"
                    $w = "$($hd.proxyWallet)".ToLower(); if (-not $rank.ContainsKey($w)) { continue }
                    $usd = [double]$hd.amount * $o.mid; if ($usd -lt $Rules.minWhaleUsd) { continue }
                    if (-not $best.ContainsKey($w) -or $best[$w].usd -lt $usd) { $best[$w] = @{ r = [int]$rank[$w]; out = $o.name; usd = $usd } }
                }
            }
        }
        $top = @($best.Values | Sort-Object { $_.r } | Select-Object -First $Rules.topN)
        $m.ranked = $top.Count
        foreach ($o in $m.outs) { $o.agree = @($top | Where-Object { $_.out -eq $o.name }).Count }
    }

    # 4. Apuestas simuladas: una por partido, el resultado con mas ventaja sobre Vegas que cumpla todo
    foreach ($m in $games) {
        if (-not $m.start -or $m.start -le $now -or ($m.start - $now).TotalHours -gt $Rules.betWindowHours) { continue }
        if ($bets.Contains($m.slug)) { continue }
        if ([int]$m.books -lt $Rules.minBooks -or [int]$m.ranked -lt $Rules.minRanked) { continue }
        $cand = @($m.outs | Where-Object { $null -ne $_.vegas -and $_.ask -ge $Rules.minPrice -and $_.ask -le $Rules.maxPrice -and
                    ($_.vegas - $_.ask) -ge $Rules.minEdge -and $_.agree -ge $Rules.minAgree } | Sort-Object { -($_.vegas - $_.ask) })
        if (-not $cand.Count) { continue }
        $o = $cand[0]
        $bets[$m.slug] = @{ key = $m.slug; league = $m.league.name; title = $m.title; outcome = $o.name; marketSlug = $o.slug
            start = $m.start.ToString('yyyy-MM-ddTHH:mm:ssZ'); placedAt = $nowIso; price = [Math]::Round($o.ask, 4); stake = $Rules.stake
            vegas = [Math]::Round($o.vegas, 4); edge = [Math]::Round($o.vegas - $o.ask, 4); consensus = "$($o.agree)/$($m.ranked)"
            status = 'open'; curPrice = $o.mid; rules = $Rules }
        Log "Apuesta: `$$($Rules.stake) a $($o.name) en $($m.title) @ $([Math]::Round($o.ask * 100, 1))c (Vegas $([Math]::Round($o.vegas * 100, 1))%, ballenas $($o.agree)/$($m.ranked))"
    }

    # 5. Precio actual y resultado de las apuestas abiertas (mercado "Si" del resultado elegido)
    $open = @($bets.Values | Where-Object { $_.status -eq 'open' })
    foreach ($b in $open) {
        foreach ($extra in '', '&closed=true') {
            $g = @(J "https://gamma-api.polymarket.com/markets?slug=$([Uri]::EscapeDataString($b.marketSlug))$extra") | Select-Object -First 1
            if ($g) { break }
        }
        if (-not $g) { continue }
        $p = [double](@((ConvertFrom-Json $g.outcomePrices) | ForEach-Object { $_ })[0])
        $b.curPrice = $p; $b.curPriceAt = $nowIso
        if ($g.closed -eq $true -and ($p -ge 0.99 -or $p -le 0.01)) {
            $b.status = $(if ($p -ge 0.99) { 'won' } else { 'lost' }); $b.resolvedAt = $nowIso; $b.finalPrice = $p
            $b.pnl = $(if ($b.status -eq 'won') { [Math]::Round($b.stake * (1 / $b.price - 1), 4) } else { -$b.stake })
            Log "Resuelta: $($b.title) [$($b.outcome)] -> $($b.status) ($($b.pnl))"
        }
    }

    # 6. Guardar
    $betsJson = ConvertTo-Json -InputObject @($bets.Values) -Depth 6 -Compress
    Write-FileAtomic $BetsFile $betsJson
    $view = @($games | Sort-Object { $_.start } | ForEach-Object {
        @{ league = $_.league.name; slug = $_.slug; title = $_.title; start = $(if ($_.start) { $_.start.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null })
           books = $_.books; ranked = $_.ranked; outs = @($_.outs | ForEach-Object { @{ name = $_.name; draw = $_.draw; ask = $_.ask; mid = $_.mid; vegas = $_.vegas; agree = $_.agree } }) } })
    Write-FileAtomic $JsFile "window.LEAGUES_DATA = {`"generatedAt`":`"$nowIso`",`"rules`":$(ConvertTo-Json -InputObject $Rules -Compress),`"leagues`":$(ConvertTo-Json -InputObject @($Leagues | ForEach-Object { @{ id = $_.id; name = $_.name } }) -Compress),`"matches`":$(ConvertTo-Json -InputObject $view -Depth 6 -Compress),`"bets`":$betsJson};"
    $state.lastRun = $nowIso; Write-FileAtomic $StateFile (ConvertTo-Json -InputObject $state -Compress)
    Log "OK: $($games.Count) partidos en $($Rules.lookaheadDays) dias, $(@($games | Where-Object { $null -ne $_.outs[0].vegas }).Count) con Vegas, $($bets.Count) apuestas en el historial"
    exit 0
} catch {
    Log "ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
    exit 1
}
