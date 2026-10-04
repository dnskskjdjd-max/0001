# Cuotas de casas de apuestas (The Odds API): probabilidad "justa" segun Vegas para comparar con el precio de Polymarket.
# Se carga desde tracker.ps1 (. .\odds.ps1). La clave vive solo en esta PC: secrets\odds-api.key (excluida de git).
# Plan gratuito: 500 consultas al mes; cada consulta (un deporte, mercado ganador, casas de EE.UU.) gasta 1.
# (Este archivo se guarda con BOM UTF-8 para que PowerShell 5.1 lea bien las tildes.)
$OddsKeyFile      = Join-Path $Root 'secrets\odds-api.key'
$OddsCacheFile    = Join-Path $DataDir 'odds-cache.json'
$OddsUsageFile    = Join-Path $DataDir 'odds-usage.json'
$OddsMaxAgeMin    = 180   # un deporte se vuelve a consultar como mucho cada 3 horas
$OddsDailyCap     = 14    # consultas maximas por dia
$OddsMinRemaining = 40    # reserva: no se consulta si quedan menos creditos en el mes
$OddsSportByCat = @{
    'NFL' = 'americanfootball_nfl'; 'Fútbol americano universitario' = 'americanfootball_ncaaf'
    'Béisbol (MLB)' = 'baseball_mlb'; 'Básquet' = 'basketball_nba'; 'Hockey (NHL)' = 'icehockey_nhl'
}
$OddsSoccerByPrefix = @{
    epl = 'soccer_epl'; lal = 'soccer_spain_la_liga'; bun = 'soccer_germany_bundesliga'; ser = 'soccer_italy_serie_a'
    fl1 = 'soccer_france_ligue_one'; ucl = 'soccer_uefa_champs_league'; uel = 'soccer_uefa_europa_league'
    uecl = 'soccer_uefa_europa_conference_league'; conl = 'soccer_uefa_europa_conference_league'
    unl = 'soccer_uefa_nations_league'; mls = 'soccer_usa_mls'
}
$script:OddsCache = $null

function Get-OddsCache {
    if ($null -eq $script:OddsCache) {
        $script:OddsCache = @{}
        if (Test-Path $OddsCacheFile) { $script:OddsCache = ConvertTo-Hash (Get-Content $OddsCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
        if (-not $script:OddsCache) { $script:OddsCache = @{} }
    }
    return $script:OddsCache
}

function Get-OddsSport($slug, $eventSlug, $title) {
    $cat = Get-Category "$slug $eventSlug $title"
    if ($OddsSportByCat.ContainsKey($cat)) { return $OddsSportByCat[$cat] }
    if ($cat -eq 'Fútbol' -and "$slug" -match '^([a-z0-9]+)-') { return $OddsSoccerByPrefix[$Matches[1]] }
    return $null
}

# Que se compara: 'h2h' (mercado "A vs. B" con los dos equipos como resultados) o 'win' ("Will X win on fecha?")
function Get-OddsTarget($title, $outs) {
    if ("$title" -match '^Will (.+?) win on (\d{4}-\d{2}-\d{2})\?') { return @{ kind = 'win'; team = $Matches[1] } }
    if ($outs.Count -eq 2 -and "$($outs[0])" -notmatch '^(Yes|No|Over|Under)$' -and "$title" -notmatch 'Spread|O/U|:') {
        return @{ kind = 'h2h'; a = "$($outs[0])"; b = "$($outs[1])" }
    }
    return $null
}

function Test-TeamMatch($full, $short) {
    $f = "$full".ToLower(); $s = "$short".ToLower()
    return ($s.Length -ge 3 -and ($f.Contains($s) -or $s.Contains($f)))
}

# Consulta los deportes pedidos respetando el presupuesto; nunca lanza errores (las cuotas son informativas)
function Update-OddsCache($sports) {
    if (-not (Test-Path $OddsKeyFile)) { return }
    $key = (Get-Content $OddsKeyFile -Raw).Trim()
    $cache = Get-OddsCache
    $usage = if (Test-Path $OddsUsageFile) { ConvertTo-Hash (Get-Content $OddsUsageFile -Raw | ConvertFrom-Json) } else { @{} }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($usage.day -ne $today) { $usage.day = $today; $usage.dayCount = 0 }
    $nowUtc = (Get-Date).ToUniversalTime(); $changed = $false
    foreach ($sp in @($sports | Select-Object -Unique)) {
        $c = $cache[$sp]
        if ($c -and $c.fetchedAt -and ($nowUtc - [DateTimeOffset]::Parse($c.fetchedAt).UtcDateTime).TotalMinutes -lt $OddsMaxAgeMin) { continue }
        if ([int]$usage.dayCount -ge $OddsDailyCap) { Log "Cuotas: tope diario alcanzado ($OddsDailyCap consultas)"; break }
        if ($null -ne $usage.remaining -and [int]$usage.remaining -lt $OddsMinRemaining) { Log "Cuotas: quedan $($usage.remaining) creditos este mes; se pausa"; break }
        try {
            $r = Invoke-WebRequest -UseBasicParsing "https://api.the-odds-api.com/v4/sports/$sp/odds?apiKey=$key&regions=us&markets=h2h&oddsFormat=decimal" -TimeoutSec 30
            $evs = @((ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()))) | ForEach-Object { $_ })
            $list = foreach ($e in $evs) {
                $fair = @{}; $n = 0
                foreach ($bk in $e.bookmakers) {
                    $mk = $bk.markets | Where-Object { $_.key -eq 'h2h' } | Select-Object -First 1
                    if (-not $mk) { continue }
                    $inv = @{}; foreach ($o in $mk.outcomes) { if ([double]$o.price -gt 1) { $inv[$o.name] = 1 / [double]$o.price } }
                    $tot = ($inv.Values | Measure-Object -Sum).Sum; if (-not $tot) { continue }
                    foreach ($k in $inv.Keys) { $fair[$k] = [double]$fair[$k] + $inv[$k] / $tot }   # sin el margen de la casa
                    $n++
                }
                if (-not $n) { continue }
                $avg = @{}; foreach ($k in $fair.Keys) { $avg[$k] = [Math]::Round($fair[$k] / $n, 4) }
                @{ home = $e.home_team; away = $e.away_team; commence = $e.commence_time; fair = $avg; books = $n }
            }
            $cache[$sp] = @{ fetchedAt = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); events = @($list) }
            $usage.used = $r.Headers['x-requests-used']; $usage.remaining = $r.Headers['x-requests-remaining']
            $usage.dayCount = [int]$usage.dayCount + 1; $changed = $true
            Log "Cuotas: $sp actualizado ($(@($list).Count) partidos; creditos restantes $($usage.remaining))"
        } catch { Log "Cuotas: error consultando $sp - $($_.Exception.Message -replace 'apiKey=[^&\s]+', 'apiKey=***')" }
    }
    if ($changed) {
        Write-FileAtomic $OddsCacheFile (ConvertTo-Json -InputObject $cache -Depth 8 -Compress)
    }
    Write-FileAtomic $OddsUsageFile (ConvertTo-Json -InputObject $usage -Compress)
}

# Probabilidad segun Vegas del lado $position en el mercado ($m del sitio, $g de Gamma); $null si no hay datos
function Get-VegasProb($m, $g, $position) {
    if (-not $g -or -not $g.outcomes) { return $null }
    $sp = Get-OddsSport $m.slug $m.eventSlug $m.title
    if (-not $sp) { return $null }
    $c = (Get-OddsCache)[$sp]
    if (-not $c -or -not $c.events) { return $null }
    $outs = @((ConvertFrom-Json $g.outcomes) | ForEach-Object { $_ })
    $tg = Get-OddsTarget $m.title $outs
    if (-not $tg) { return $null }
    $start = $null
    foreach ($s in @($g.gameStartTime, $g.endDate)) { if ($s -and -not $start) { try { $start = [DateTimeOffset]::Parse("$s").UtcDateTime } catch {} } }
    foreach ($ev in $c.events) {
        if ($start) { try { if ([Math]::Abs(([DateTimeOffset]::Parse("$($ev.commence)").UtcDateTime - $start).TotalHours) -gt 30) { continue } } catch {} }
        if ($tg.kind -eq 'h2h') {
            $ok = ((Test-TeamMatch $ev.home $tg.a) -and (Test-TeamMatch $ev.away $tg.b)) -or ((Test-TeamMatch $ev.home $tg.b) -and (Test-TeamMatch $ev.away $tg.a))
            if (-not $ok) { continue }
            $team = @($outs | Where-Object { "$_".ToUpper() -eq $position }) | Select-Object -First 1
            if (-not $team) { return $null }
            $k = @($ev.fair.Keys | Where-Object { Test-TeamMatch $_ $team }) | Select-Object -First 1
            if ($k) { return @{ p = [double]$ev.fair[$k]; books = $ev.books } }
        } else {
            if (-not ((Test-TeamMatch $ev.home $tg.team) -or (Test-TeamMatch $ev.away $tg.team))) { continue }
            $k = @($ev.fair.Keys | Where-Object { Test-TeamMatch $_ $tg.team }) | Select-Object -First 1
            if (-not $k) { continue }
            $p = [double]$ev.fair[$k]
            return @{ p = $(if ($position -eq 'NO') { [Math]::Round(1 - $p, 4) } else { $p }); books = $ev.books }
        }
    }
    return $null
}

# Deportes que conviene consultar ahora: mercados de ganador que empiezan en < 36 h y aun no empezaron
function Get-OddsNeededSports($markets, $gamma) {
    $nowUtc = (Get-Date).ToUniversalTime()
    $need = foreach ($m in $markets) {
        $g = $gamma[$m.slug]; if (-not $g -or -not $g.outcomes -or $g.closed -eq $true) { continue }
        $sp = Get-OddsSport $m.slug $m.eventSlug $m.title; if (-not $sp) { continue }
        if (-not (Get-OddsTarget $m.title @((ConvertFrom-Json $g.outcomes) | ForEach-Object { $_ }))) { continue }
        $start = $null; foreach ($s in @($g.gameStartTime, $g.endDate)) { if ($s -and -not $start) { try { $start = [DateTimeOffset]::Parse("$s").UtcDateTime } catch {} } }
        if (-not $start -or $start -le $nowUtc -or ($start - $nowUtc).TotalHours -gt 36) { continue }
        $sp
    }
    return @($need | Group-Object | Sort-Object Count -Descending | ForEach-Object { $_.Name })
}
