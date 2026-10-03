# FirePolymarket tracker
# Cada ejecucion: descarga los mercados de firepolymarket.com, registra las senales (Fire Score >= 60),
# consulta Polymarket (Gamma API) para precio actual y resolucion, y genera data/data.js para dashboard.html.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root        = $PSScriptRoot
$DataDir     = Join-Path $Root 'data'
New-Item -ItemType Directory -Force $DataDir | Out-Null
$SignalsFile = Join-Path $DataDir 'signals.json'
$RunsFile    = Join-Path $DataDir 'runs.json'
$SnapFile    = Join-Path $DataDir 'snapshots.csv'
$DataJsFile  = Join-Path $DataDir 'data.js'
$LogFile     = Join-Path $DataDir 'log.txt'

$Thresholds   = @(60, 65, 70, 75, 80)   # se guarda la entrada al cruzar cada umbral
$MinTrack     = 60
$SnapMinScore = 50

$SupabaseUrl = 'https://lrzwloviokblqyczszgl.supabase.co/functions/v1/fetch-polymarket-data'
# Clave publica "anon" que el propio sitio incluye en su frontend
$AnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imxyendsb3Zpb2tibHF5Y3pzemdsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE5OTQxODQsImV4cCI6MjA3NzU3MDE4NH0.Agc8wirvCTd3S1VEzR1UWMB9HDlXJHhjjZWanyWx6EI'
$GammaUrl = 'https://gamma-api.polymarket.com/markets'
$Utf8 = New-Object System.Text.UTF8Encoding $false

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-NowIso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function ConvertTo-Hash($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
        return $h
    }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
        return ,@($o | ForEach-Object { ConvertTo-Hash $_ })
    }
    return $o
}

function Write-FileAtomic($path, $text) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $text, $Utf8)
    Move-Item -Force $tmp $path
}

function Invoke-WithRetry([scriptblock]$block, $what) {
    for ($i = 1; $i -le 3; $i++) {
        try { return & $block } catch {
            Log "$what fallo (intento $i): $($_.Exception.Message)"
            if ($i -eq 3) { throw }
            Start-Sleep -Seconds (10 * $i)
        }
    }
}

# Invoke-RestMethod de PowerShell 5.1 decodifica mal UTF-8 sin charset; se decodifica a mano
function Invoke-Json($uri, $method = 'Get', $headers = @{}, $body = $null) {
    $p = @{ Uri = $uri; Method = $method; Headers = $headers; TimeoutSec = 120; UseBasicParsing = $true }
    if ($body) { $p.Body = $body; $p.ContentType = 'application/json' }
    $r = Invoke-WebRequest @p
    return ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()))
}

# En PowerShell 5.1 ConvertFrom-Json emite un array JSON como un solo objeto; esto lo desenrolla
function ConvertFrom-JsonArray($text) { (ConvertFrom-Json $text) | ForEach-Object { $_ } }

function Find-OutcomeIndex($outcomes, $position) {
    $p = $position.Trim().ToLower()
    for ($i = 0; $i -lt $outcomes.Count; $i++) { if ($outcomes[$i].Trim().ToLower() -eq $p) { return $i } }
    for ($i = 0; $i -lt $outcomes.Count; $i++) {
        $o = $outcomes[$i].Trim().ToLower()
        if ($o.Contains($p) -or $p.Contains($o)) { return $i }
    }
    return -1
}

function Get-GammaPrice($g, $position) {
    if (-not $g -or -not $g.outcomes -or -not $g.outcomePrices) { return $null }
    $outs   = @(ConvertFrom-JsonArray $g.outcomes)
    $prices = @(ConvertFrom-JsonArray $g.outcomePrices)
    $idx = Find-OutcomeIndex $outs $position
    if ($idx -lt 0 -or $idx -ge $prices.Count) { return $null }
    return [double]$prices[$idx]
}

# Precio al que realmente se compraria (mejor oferta de venta), diferencial y liquidez.
# bestBid/bestAsk de Gamma son del primer resultado; para el segundo, ask = 1 - bestBid.
function Get-GammaQuote($g, $position) {
    $q = @{ ask = $null; spread = $null; liq = $null }
    if (-not $g) { return $q }
    $outs = @(ConvertFrom-JsonArray $g.outcomes)
    $idx = Find-OutcomeIndex $outs $position
    if ($idx -eq 0 -and $null -ne $g.bestAsk) { $q.ask = [double]$g.bestAsk }
    elseif ($idx -eq 1 -and $null -ne $g.bestBid) { $q.ask = [Math]::Round(1 - [double]$g.bestBid, 4) }
    if ($null -ne $g.spread) { $q.spread = [double]$g.spread }
    if ($null -ne $g.liquidityNum) { $q.liq = [Math]::Round([double]$g.liquidityNum) }
    return $q
}

# Datos guardados en el momento de cada entrada (sirven para simular despues sin mirar el futuro)
function New-Entry($now, $price, $m, $g, $position, $top) {
    $q = Get-GammaQuote $g $position
    return @{ t = $now; price = [Math]::Round($price, 4); ask = $q.ask; spread = $q.spread; liq = $q.liq
              score = $m.fireScore; top = $top
              hedgeCap = $(if ($null -ne $m.hedgeCapitalRatio) { [Math]::Round([double]$m.hedgeCapitalRatio, 3) } else { $null })
              hedgeWallets = $(if ($null -ne $m.hedgingRatio) { [Math]::Round([double]$m.hedgingRatio, 3) } else { $null }) }
}

function Get-GammaMarkets($slugs) {
    $res = @{}
    $list = @($slugs | Where-Object { $_ } | Select-Object -Unique)
    for ($i = 0; $i -lt $list.Count; $i += 20) {
        $chunk = $list[$i..([Math]::Min($i + 19, $list.Count - 1))]
        $qs = ($chunk | ForEach-Object { 'slug=' + [Uri]::EscapeDataString($_) }) -join '&'
        try {
            $resp = Invoke-WithRetry { Invoke-Json "$GammaUrl`?$qs&limit=100" } 'Gamma'
            foreach ($m in ($resp | ForEach-Object { $_ })) { if ($m.slug) { $res[$m.slug] = $m } }
        } catch { Log "Gamma error: $($_.Exception.Message)" }
    }
    return $res
}

# Precio segun el sitio (fallback si Gamma no reconoce el resultado)
function Get-SitePrice($m, $position) {
    if ($position -eq 'YES' -and $null -ne $m.liveYesPrice) { return [double]$m.liveYesPrice }
    if ($position -eq 'NO'  -and $null -ne $m.liveNoPrice)  { return [double]$m.liveNoPrice }
    $ps  = @($m.positions | Where-Object { $_.outcome -and $_.outcome.ToUpper() -eq $position })
    $tot = ($ps | Measure-Object value -Sum).Sum
    if ($tot -gt 0) { return (($ps | ForEach-Object { $_.curPrice * $_.value } | Measure-Object -Sum).Sum / $tot) }
    return $null
}

# Cripto intradia (5m, 15m, 1h, 4h...): se excluye. Se mantienen los diarios ("on October 3") y los de mas largo plazo.
$CryptoPattern = 'btc|bitcoin|eth|ethereum|sol|solana|xrp|doge|bnb|hype|zec|crypto'
function Test-ShortCrypto($m) {
    $slug = "$($m.slug)"; $title = "$($m.title)"
    if ($slug -match '-updown-\d+[mh]-') { return $true }
    if ($slug -notmatch $CryptoPattern -and $title -notmatch "(?i)$CryptoPattern") { return $false }
    if ($slug -match '-\d{1,2}(am|pm)(-et)?(-|$)') { return $true }
    if ($title -match '\d{1,2}(:\d{2})?\s?(AM|PM)\b') { return $true }
    return $false
}

# Ballenas del mercado ordenadas por su puesto en el ranking global (ganancia total).
# Cada ballena cuenta una vez, del lado donde tiene mas dinero.
# Devuelve las 20 mejores como [puesto, 1 si coincide con la senal, 1 si esta cubierta (apuesta a ambos lados)].
function Get-TopWhales($m, $position, $rank) {
    $holders = foreach ($g in ($m.positions | Where-Object { $_.username } | Group-Object username)) {
        $main = $g.Group | Sort-Object value -Descending | Select-Object -First 1
        $r = $rank[$g.Name]
        $hedged = [int]((@($g.Group | ForEach-Object { "$($_.outcome)".ToUpper() } | Select-Object -Unique).Count -gt 1) -or $main.isHedged -eq $true)
        if ($r) { [pscustomobject]@{ r = $r; a = [int]("$($main.outcome)".ToUpper() -eq $position); h = $hedged } }
    }
    return ,@($holders | Sort-Object r | Select-Object -First 20 | ForEach-Object { ,@($_.r, $_.a, $_.h) })
}

function Get-WhaleStats($m, $position) {
    $ps  = @($m.positions | Where-Object { $_.outcome -and $_.outcome.ToUpper() -eq $position })
    $tot = ($ps | Measure-Object value -Sum).Sum
    $avg = if ($tot -gt 0) { (($ps | ForEach-Object { $_.avgPrice * $_.value } | Measure-Object -Sum).Sum / $tot) } else { $null }
    return @{ wallets = $ps.Count; capital = [Math]::Round([double]$tot); avgEntry = $avg }
}

try {
    $now = Get-NowIso
    Log '--- inicio ---'

    # 1. Estado previo
    $signals = @{}
    if (Test-Path $SignalsFile) {
        foreach ($s in (ConvertTo-Hash (Get-Content $SignalsFile -Raw -Encoding UTF8 | ConvertFrom-Json))) {
            if ($s -and $s.key) { $signals[$s.key] = $s }
        }
    }
    $runs = @()
    if (Test-Path $RunsFile) { $runs = @(ConvertFrom-JsonArray (Get-Content $RunsFile -Raw -Encoding UTF8)) }

    # 2. Datos del sitio
    $headers = @{ apikey = $AnonKey; Authorization = "Bearer $AnonKey" }
    $site = Invoke-WithRetry {
        Invoke-Json $SupabaseUrl 'Post' $headers '{}'
    } 'FirePolymarket'
    $markets = @($site.markets)
    Log "Mercados recibidos: $($markets.Count) (actualizado en el sitio: $($site.lastUpdated))"

    $rank = @{}; $i = 0
    foreach ($w in ($site.whales | Sort-Object { [double]$_.totalPnl } -Descending)) { $i++; if (-not $rank.ContainsKey($w.username)) { $rank[$w.username] = $i } }

    $short = @($markets | Where-Object { $_.fireScore -ge $MinTrack -and (Test-ShortCrypto $_) })
    if ($short.Count) { Log "Excluidos $($short.Count) mercados cripto intradia: $(($short | ForEach-Object { $_.slug }) -join ', ')" }
    $candidates = @($markets | Where-Object { $_.fireScore -ge $MinTrack -and -not (Test-ShortCrypto $_) })
    # Grupo de control: mercados que el sitio sigue pero con Fire Score bajo, apostando del mismo lado que las ballenas
    $controls   = @($markets | Where-Object { $_.fireScore -lt $MinTrack -and -not (Test-ShortCrypto $_) })
    $openSlugs  = @($signals.Values | Where-Object { $_.status -eq 'open' } | ForEach-Object { $_.slug })
    $newCtlSlugs = @($controls | Where-Object { -not $signals.ContainsKey("ctl|$($_.slug)|$("$($_.position)".ToUpper())") } | ForEach-Object { $_.slug })
    $gamma = Get-GammaMarkets (@($candidates | ForEach-Object { $_.slug }) + $newCtlSlugs + $openSlugs)

    # 3. Registrar / actualizar senales
    $newCount = 0
    $current = @()
    foreach ($m in $candidates) {
        $position = if ($m.position) { $m.position.ToString().ToUpper() } else { 'YES' }
        $key = "$($m.slug)|$position"
        $g = $gamma[$m.slug]
        $price = Get-GammaPrice $g $position; $src = 'gamma'
        if ($null -eq $price) { $price = Get-SitePrice $m $position; $src = 'site' }
        if ($null -eq $price -or $price -le 0.005 -or $price -ge 0.995) { continue }
        $ws = Get-WhaleStats $m $position
        $top = Get-TopWhales $m $position $rank

        if (-not $signals.ContainsKey($key)) {
            $signals[$key] = @{
                key = $key; slug = $m.slug; title = $m.title; position = $position
                eventSlug = $m.eventSlug; questionID = $m.questionID; endDate = $m.endDate
                firstSeen = $now; maxScore = 0; entries = @{}; status = 'open'; priceSource = $src
                walletsAtEntry = $ws.wallets; capitalAtEntry = $ws.capital; whaleAvgEntry = $ws.avgEntry
            }
            $newCount++
        }
        $s = $signals[$key]
        if (-not $s.entries) { $s.entries = @{} }
        $s.lastSeen = $now; $s.lastScore = $m.fireScore
        if ($m.fireScore -gt $s.maxScore) { $s.maxScore = $m.fireScore }
        if ($s.status -eq 'open') { $s.curPrice = [Math]::Round($price, 4); $s.curPriceAt = $now }
        foreach ($t in $Thresholds) {
            if ($m.fireScore -ge $t -and -not $s.entries.ContainsKey("$t")) {
                $s.entries["$t"] = New-Entry $now $price $m $g $position $top
            }
            # Senales registradas antes de estos datos: se completan con el dato actual y se marcan
            $e = $s.entries["$t"]
            if ($e -and (-not $e.top -or ($e.top.Count -and $e.top[0].Count -lt 3))) { $e.top = $top; $e.topLate = $true }
            if ($e -and -not $e.ContainsKey('hedgeCap')) {
                $n = New-Entry $now $price $m $g $position $top
                foreach ($f in 'ask', 'spread', 'liq', 'hedgeCap', 'hedgeWallets') { $e[$f] = $n[$f] }
                $e.quoteLate = $true
            }
        }
        $q = Get-GammaQuote $g $position
        $current += @{ key = $key; title = $m.title; slug = $m.slug; eventSlug = $m.eventSlug; questionID = $m.questionID
                       position = $position; score = $m.fireScore; price = [Math]::Round($price, 4); ask = $q.ask; spread = $q.spread; liq = $q.liq
                       hedgeCap = $m.hedgeCapitalRatio; endDate = $m.endDate; wallets = $ws.wallets; capital = $ws.capital
                       whaleAvgEntry = $ws.avgEntry; top = $top }
    }

    # 3b. Grupo de control (se registra una sola vez, al verlo por primera vez)
    $newCtl = 0
    foreach ($m in $controls) {
        $position = if ($m.position) { $m.position.ToString().ToUpper() } else { 'YES' }
        $key = "ctl|$($m.slug)|$position"
        if ($signals.ContainsKey($key)) { continue }
        $g = $gamma[$m.slug]
        $price = Get-GammaPrice $g $position
        if ($null -eq $price -or $price -le 0.005 -or $price -ge 0.995) { continue }
        $signals[$key] = @{
            key = $key; kind = 'control'; slug = $m.slug; title = $m.title; position = $position
            eventSlug = $m.eventSlug; questionID = $m.questionID; endDate = $m.endDate
            firstSeen = $now; maxScore = $m.fireScore; status = 'open'; curPrice = [Math]::Round($price, 4); curPriceAt = $now
            entries = @{ ctl = (New-Entry $now $price $m $g $position (Get-TopWhales $m $position $rank)) }
        }
        $newCtl++
    }

    # 4. Precio actual y resolucion de senales abiertas
    $resolvedCount = 0
    foreach ($s in @($signals.Values | Where-Object { $_.status -eq 'open' })) {
        $g = $gamma[$s.slug]
        if (-not $g) { continue }
        $p = Get-GammaPrice $g $s.position
        if ($null -ne $p) { $s.curPrice = [Math]::Round($p, 4); $s.curPriceAt = $now }
        if ($g.closed -eq $true) {
            $status = $null
            if ($null -eq $p) { $status = 'void' }
            elseif ($p -ge 0.99) { $status = 'won' }
            elseif ($p -le 0.01) { $status = 'lost' }
            elseif ($g.umaResolutionStatus -eq 'resolved') { $status = 'void' }
            if ($status) {
                $s.status = $status; $s.resolvedAt = $now; $s.finalPrice = $p
                $resolvedCount++
                Log "Resuelta: $($s.title) [$($s.position)] -> $status"
            }
        }
    }

    # 5. Snapshot historico (todos los mercados con score >= $SnapMinScore)
    $rows = foreach ($m in $markets) {
        if ($m.fireScore -lt $SnapMinScore) { continue }
        $position = if ($m.position) { $m.position.ToString().ToUpper() } else { 'YES' }
        $ws = Get-WhaleStats $m $position
        [pscustomobject]@{
            ts = $now; slug = $m.slug; position = $position; fireScore = $m.fireScore
            sitePrice = $(if (($sp = Get-SitePrice $m $position) -ne $null) { [Math]::Round($sp, 4) } else { '' })
            whaleAvgEntry = $(if ($ws.avgEntry) { [Math]::Round($ws.avgEntry, 4) } else { '' })
            wallets = $ws.wallets; capital = $ws.capital; endDate = $m.endDate
        }
    }
    if ($rows) { $rows | Export-Csv -Path $SnapFile -Append -NoTypeInformation -Encoding UTF8 }

    # 6. Guardar
    $above70 = @($candidates | Where-Object { $_.fireScore -ge 70 }).Count
    $runs += [pscustomobject]@{ t = $now; markets = $markets.Count; above60 = $candidates.Count; above70 = $above70; newSignals = $newCount; resolved = $resolvedCount }
    if ($runs.Count -gt 3000) { $runs = $runs[-3000..-1] }

    $sigArr = @($signals.Values | Sort-Object { $_.firstSeen })
    $sigJson = ConvertTo-Json -InputObject $sigArr -Depth 8 -Compress
    Write-FileAtomic $SignalsFile $sigJson
    $runsJson = ConvertTo-Json -InputObject @($runs) -Depth 4 -Compress
    Write-FileAtomic $RunsFile $runsJson
    $curJson = ConvertTo-Json -InputObject @($current) -Depth 4 -Compress

    $js = "window.TRACKER_DATA = {`"generatedAt`":`"$now`",`"siteUpdatedAt`":`"$($site.lastUpdated)`",`"thresholds`":[$($Thresholds -join ',')],`"signals`":$sigJson,`"runs`":$runsJson,`"current`":$curJson};"
    Write-FileAtomic $DataJsFile $js

    $ctlTotal = @($signals.Values | Where-Object { $_.kind -eq 'control' }).Count
    Log "OK: $($candidates.Count) mercados >= $MinTrack, $above70 >= 70, $newCount senales nuevas, $newCtl de control nuevas, $resolvedCount resueltas, $($signals.Count - $ctlTotal) senales + $ctlTotal de control"
    exit 0
} catch {
    Log "ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
    exit 1
}
