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
$BetsFile    = Join-Path $DataDir 'bets.json'      # historial de apuestas: una vez registrada, la apuesta no cambia (solo su resultado)
$StrategyFile = Join-Path $Root 'strategy.json'    # reglas con que se apuesta cada hora; cambiarlas solo afecta a apuestas futuras
$AlertsNewFile = Join-Path $DataDir 'alerts-new.json'  # alertas de venta nuevas de esta ejecucion (el workflow las envia como issues)
$AlertsCloseFile = Join-Path $DataDir 'alerts-close.json'  # alertas cuyo mercado ya se resolvio (el workflow comenta y cierra el issue)
$PagesUrl = 'https://dnskskjdjd-max.github.io/0001/'
$Repo = 'dnskskjdjd-max/0001'
$RepoOwner = 'dnskskjdjd-max'   # solo se aceptan decisiones (issues) creadas por esta cuenta: el repositorio es publico
$DecisionsFile    = Join-Path $DataDir 'decisions.json'      # historial de decisiones aplicadas (vender / mantener)
$DecisionsNewFile = Join-Path $DataDir 'decisions-new.json'  # decisiones aplicadas en esta ejecucion (el workflow cierra los issues)

# Enlaces que crean el issue de decision ya rellenado: el usuario solo pulsa "Create" en GitHub
function Get-DecisionUrl($b, $action) {
    $verb = if ($action -eq 'VENDER') { 'VENDER' } else { 'MANTENER' }
    $title = "Decision: $verb - $($b.title) [$($b.position)]"
    $body = "Decision sobre la alerta de venta de esta apuesta. Pulsa **Create** para confirmarla; el tracker la aplica en su proxima ejecucion (5 minutos como maximo).`n`nkey: ``$($b.key)``"
    return "https://github.com/$Repo/issues/new?title=$([Uri]::EscapeDataString($title))&body=$([Uri]::EscapeDataString($body))"
}

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
    $q = @{ ask = $null; bid = $null; spread = $null; liq = $null }
    if (-not $g) { return $q }
    $outs = @(ConvertFrom-JsonArray $g.outcomes)
    $idx = Find-OutcomeIndex $outs $position
    if ($idx -eq 0) {
        if ($null -ne $g.bestAsk) { $q.ask = [double]$g.bestAsk }
        if ($null -ne $g.bestBid) { $q.bid = [double]$g.bestBid }
    } elseif ($idx -eq 1) {
        if ($null -ne $g.bestBid) { $q.ask = [Math]::Round(1 - [double]$g.bestBid, 4) }
        if ($null -ne $g.bestAsk) { $q.bid = [Math]::Round(1 - [double]$g.bestAsk, 4) }
    }
    if ($null -ne $g.spread) { $q.spread = [double]$g.spread }
    if ($null -ne $g.liquidityNum) { $q.liq = [Math]::Round([double]$g.liquidityNum) }
    return $q
}

# Datos guardados en el momento de cada entrada (sirven para simular despues sin mirar el futuro)
function New-Entry($now, $price, $m, $g, $position, $top) {
    $q = Get-GammaQuote $g $position
    $vg = Get-VegasProb $m $g $position
    return @{ t = $now; price = [Math]::Round($price, 4); ask = $q.ask; spread = $q.spread; liq = $q.liq
              score = $m.fireScore; top = $top; vegas = $(if ($vg) { $vg.p } else { $null })
              hedgeCap = $(if ($null -ne $m.hedgeCapitalRatio) { [Math]::Round([double]$m.hedgeCapitalRatio, 3) } else { $null })
              hedgeWallets = $(if ($null -ne $m.hedgingRatio) { [Math]::Round([double]$m.hedgingRatio, 3) } else { $null }) }
}

# $true si el mercado tiene hora de inicio de partido (gameStartTime) y ya paso
function Test-Started($g) {
    if (-not $g -or -not $g.gameStartTime) { return $false }
    try { return [DateTimeOffset]::Parse("$($g.gameStartTime)").UtcDateTime -le (Get-Date).ToUniversalTime() } catch { return $false }
}

function Get-GammaMarkets($slugs) {
    $res = @{}
    $list = @($slugs | Where-Object { $_ } | Select-Object -Unique)
    # Gamma solo devuelve mercados abiertos por defecto; los que falten se buscan con closed=true (asi se detectan los resultados)
    foreach ($extra in '', '&closed=true') {
        $pending = @($list | Where-Object { -not $res.ContainsKey($_) })
        for ($i = 0; $i -lt $pending.Count; $i += 20) {
            $chunk = $pending[$i..([Math]::Min($i + 19, $pending.Count - 1))]
            $qs = ($chunk | ForEach-Object { 'slug=' + [Uri]::EscapeDataString($_) }) -join '&'
            try {
                $resp = Invoke-WithRetry { Invoke-Json "$GammaUrl`?$qs&limit=100$extra" } 'Gamma'
                foreach ($m in ($resp | ForEach-Object { $_ })) { if ($m.slug) { $res[$m.slug] = $m } }
            } catch { Log "Gamma error: $($_.Exception.Message)" }
        }
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

. (Join-Path $PSScriptRoot 'categories.ps1')   # reglas de categorias (identicas a CATEGORY_RULES en dashboard.html)
. (Join-Path $PSScriptRoot 'odds.ps1')         # cuotas de Vegas (The Odds API); sin clave local, no hace nada

# Resumen semanal (markdown): resultados de la semana y que rangos de precio/consenso/score/categoria funcionan.
# Se basa en las senales resueltas (entrada al primer umbral, precio de compra real) y en los historiales fijos.
function Get-WeeklyReport($signals, $bets, $strategy) {
    $since = (Get-Date).ToUniversalTime().AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $money = { param($v) if ($null -eq $v) { '-' } else { '{0}${1:N2}' -f $(if ($v -lt 0) { '-' } else { '+' }), [Math]::Abs($v) } }
    $out = @("**Resumen semanal del tracker** (estrategia v$($strategy.version): $($strategy.nota))", '')

    # 1. Mis apuestas
    # Measure-Object/Where-Object de PowerShell 5.1 no leen claves de hashtables: se convierten a objetos
    $all = @($bets.Values | ForEach-Object { [pscustomobject]$_ }); $closed = @($all | Where-Object { $_.status -in 'won', 'lost', 'sold' })
    $week = @($closed | Where-Object { $_.resolvedAt -ge $since }); $open = @($all | Where-Object { $_.status -eq 'open' })
    $mtm = ($open | ForEach-Object { if ($null -ne $_.curPrice) { $_.stake * ($_.curPrice / $_.price - 1) } } | Measure-Object -Sum).Sum
    $out += '### Mis apuestas'
    $out += "- **Esta semana:** $($week.Count) resueltas ($(@($week | ? status -eq 'won').Count) ganadas, $(@($week | ? status -eq 'lost').Count) perdidas$(if (@($week | ? status -eq 'sold').Count) { ", $(@($week | ? status -eq 'sold').Count) vendidas" })): **$(& $money ($week | Measure-Object pnl -Sum).Sum)**"
    $out += "- **Desde el inicio:** $($closed.Count) resueltas, $(& $money ($closed | Measure-Object pnl -Sum).Sum) realizados sobre `$$(($closed | Measure-Object stake -Sum).Sum) apostados"
    $out += "- **Abiertas:** $($open.Count) (`$$(($open | Measure-Object stake -Sum).Sum) apostados), a precio actual $(& $money $mtm)"
    foreach ($tier in 'normal', 'conservadora') {
        $g = @($closed | Where-Object { ($(if ($_.tier) { $_.tier } else { 'normal' })) -eq $tier })
        if ($g.Count) { $out += "- Tipo **$tier**: $($g.Count) resueltas, $(@($g | ? status -eq 'won').Count) ganadas, $(& $money ($g | Measure-Object pnl -Sum).Sum)" }
    }

    # 2. Copiadores
    $out += '', '### Copiadores'
    foreach ($f in @(Get-ChildItem (Join-Path $DataDir 'copy-*-bets.json') -ErrorAction SilentlyContinue)) {
        $c = @((Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ } | Where-Object { $_ })
        $cc = @($c | Where-Object { $_.status -ne 'open' }); $cw = @($cc | Where-Object { $_.resolvedAt -ge $since })
        $id = $f.Name -replace '^copy-|-bets\.json$', ''
        $open = @($c | Where-Object { $_.status -eq 'open' })
        $omtm = ($open | ForEach-Object { if ($null -ne $_.curPrice) { $_.stake * ($_.curPrice / $_.price - 1) } } | Measure-Object -Sum).Sum
        $res = if ($cc.Count) { "$(& $money ($cc | Measure-Object pnl -Sum).Sum) realizados ($(& $money $(if ($cw.Count) { ($cw | Measure-Object pnl -Sum).Sum } else { 0 })) esta semana)" } else { 'ninguna cerrada todavía' }
        $out += "- **$id**: $($c.Count) copias; $res$(if ($open.Count) { "; $($open.Count) abiertas a precio actual $(& $money $omtm)" })"
    }

    # 3. Que funciona (senales resueltas)
    $rows = foreach ($s in $signals.Values) {
        if ($s.status -notin 'won', 'lost') { continue }
        $e = if ($s.kind -eq 'control') { $s.entries.ctl } else { $s.entries[($s.entries.Keys | Sort-Object { [int]$_ } | Select-Object -First 1)] }
        if (-not $e) { continue }
        $px = if ($e.ask) { [double]$e.ask } else { [double]$e.price }
        $agree = if ($e.top) { @(@($e.top) | Select-Object -First 10 | Where-Object { $_[1] }).Count } else { $null }
        [pscustomobject]@{ ctl = ($s.kind -eq 'control'); won = [int]($s.status -eq 'won'); px = $px; score = [int]$e.score; agree = $agree
            cat = (Get-Category "$($s.slug) $($s.eventSlug) $($s.title)"); roi = $(if ($s.status -eq 'won') { 1 / $px - 1 } else { -1 })
            vg = $(if ($null -ne $e.vegas) { [double]$e.vegas - $px } else { $null }) }
    }
    $row = { param($name, $g)
        $n = @($g).Count; if (-not $n) { return "| $name | 0 | - | - | - | - |" }
        $w = ($g | Measure-Object won -Sum).Sum / $n; $imp = ($g | Measure-Object px -Average).Average
        '| {0} | {1} | {2:P0} | {3:P0} | {4:+0;-0} pp | {5:P0} |' -f $name, $n, $w, $imp, (($w - $imp) * 100), ($g | Measure-Object roi -Average).Average }
    $sig = @($rows | Where-Object { -not $_.ctl })
    $out += '', "### Qué funciona ($($sig.Count) recomendaciones resueltas; con menos de ~30 por grupo, son tendencias)", ''
    $out += '| Grupo | Resueltas | Acierto | Prob. implícita | Ventaja | Rentabilidad |', '|---|---|---|---|---|---|'
    $out += & $row 'Señales (score >= 60)' $sig
    $out += & $row 'Control (score < 60)' @($rows | Where-Object { $_.ctl })
    foreach ($b in @(@(0, 0.45), @(0.45, 0.7), @(0.7, 0.85), @(0.85, 1.01))) { $out += & $row "Precio $([int]($b[0]*100))-$([int]($b[1]*100))c" @($sig | ? { $_.px -ge $b[0] -and $_.px -lt $b[1] }) }
    foreach ($b in @(@(0, 4), @(5, 6), @(7, 8), @(9, 10))) { $out += & $row "Consenso $($b[0])-$($b[1])/10" @($sig | ? { $null -ne $_.agree -and $_.agree -ge $b[0] -and $_.agree -le $b[1] }) }
    foreach ($b in @(@(60, 64), @(65, 69), @(70, 79), @(80, 100))) { $out += & $row "Score $($b[0])-$($b[1])" @($sig | ? { $_.score -ge $b[0] -and $_.score -le $b[1] }) }
    foreach ($g in @($sig | Group-Object cat | Sort-Object Count -Descending | Select-Object -First 8)) { $out += & $row $g.Name $g.Group }
    # Comparacion con Vegas (desde el 4 oct): ventaja = probabilidad justa de las casas - precio pagado en Polymarket
    $withVg = @($sig | Where-Object { $null -ne $_.vg })
    if ($withVg.Count) {
        $out += & $row 'Vegas: Polymarket más barato (≥ +3 pp)' @($withVg | ? { $_.vg -ge 0.03 })
        $out += & $row 'Vegas: precio parecido (±3 pp)' @($withVg | ? { $_.vg -gt -0.03 -and $_.vg -lt 0.03 })
        $out += & $row 'Vegas: Polymarket más caro (≤ -3 pp)' @($withVg | ? { $_.vg -le -0.03 })
    }
    $out += '', "[Panel]($PagesUrl) | _Resumen automatico del tracker. No es asesoria financiera._"
    return ($out -join "`n")
}

# Mismo calculo que el panel: de las N mejor rankeadas (filtradas), cuantas apuestan igual que la senal
function Get-Consensus($top, $st) {
    $pool = @($top | Where-Object { (-not $st.maxRank -or $_[0] -le $st.maxRank) -and -not ($st.exclHedged -and $_[2]) } | Select-Object -First $st.topN)
    $agree = @($pool | Where-Object { $_[1] }).Count
    return @{ agree = $agree; n = $pool.Count; ok = ($agree -ge $st.minAgree) }
}

# Actualiza precio actual y, si el mercado cerro, el resultado. Devuelve el nuevo estado o $null.
function Update-FromGamma($s, $g, $now) {
    $p = Get-GammaPrice $g $s.position
    if ($null -ne $p) { $s.curPrice = [Math]::Round($p, 4); $s.curPriceAt = $now }
    if ($g.closed -ne $true) { return $null }
    $status = $null
    if ($null -eq $p) { $status = 'void' }
    elseif ($p -ge 0.99) { $status = 'won' }
    elseif ($p -le 0.01) { $status = 'lost' }
    elseif ($g.umaResolutionStatus -eq 'resolved') { $status = 'void' }
    if ($status) { $s.status = $status; $s.resolvedAt = $now; $s.finalPrice = $p }
    return $status
}

$DefaultStrategy = [ordered]@{
    version = 1; nota = 'Estrategia inicial'
    th = 70; rule = 'consensus'; baseStake = 1; consensusStake = 5; minAgree = 6; topN = 10; maxRank = 0; exclHedged = 0
    priceMode = 'ask'; slip = 0; minLiq = 0; maxHedge = 1; maxDays = $null; cat = 'all'
    # Apuesta conservadora: score por debajo de th pero >= lowScoreMin, si >= lowScoreAgree de las topN ballenas coinciden
    lowScoreMin = 0; lowScoreAgree = 0; lowScoreStake = 0   # 0 = desactivada
    lowScoreMaxPrice = 0   # precio maximo de compra para la conservadora (0 = sin limite)
    minAgreeAll = 0        # consenso minimo (de topN) para cualquier apuesta (0 = sin minimo)
    minPrice = 0; maxPrice = 0   # rango de precio de compra para cualquier apuesta (0 = sin limite)
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
    $bets = [ordered]@{}
    if (Test-Path $BetsFile) {
        foreach ($b in (ConvertTo-Hash (Get-Content $BetsFile -Raw -Encoding UTF8 | ConvertFrom-Json))) { if ($b -and $b.key) { $bets[$b.key] = $b } }
    }
    # Estrategia: si falta se crea la inicial; si es invalida no se apuesta esta hora (el resto sigue funcionando)
    if (-not (Test-Path $StrategyFile)) { Write-FileAtomic $StrategyFile (ConvertTo-Json -InputObject $DefaultStrategy -Depth 3) }
    $strategy = $null
    try {
        $strategy = ConvertTo-Hash (Get-Content $StrategyFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        foreach ($k in $DefaultStrategy.Keys) { if (-not $strategy.ContainsKey($k)) { $strategy[$k] = $DefaultStrategy[$k] } }
        if ($strategy.th -lt $MinTrack) { throw "th debe ser >= $MinTrack" }
    } catch { Log "strategy.json invalido, no se apuesta esta hora: $($_.Exception.Message)"; $strategy = $null }

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
    # Los mercados de control se actualizan una vez por hora (o siempre si cierran en menos de 2 dias): son ~200
    # y casi todos de largo plazo; las senales y apuestas se actualizan en cada ejecucion
    $refreshCtl = (Get-Date).Minute -lt 5
    $soonCut = (Get-Date).ToUniversalTime().AddDays(2)
    $openSlugs  = @($signals.Values | Where-Object { $_.status -eq 'open' -and ($_.kind -ne 'control' -or $refreshCtl -or
        ($_.endDate -and $(try { [DateTimeOffset]::Parse("$($_.endDate)").UtcDateTime -lt $soonCut } catch { $true }))) } | ForEach-Object { $_.slug })
    $newCtlSlugs = @($controls | Where-Object { -not $signals.ContainsKey("ctl|$($_.slug)|$("$($_.position)".ToUpper())") } | ForEach-Object { $_.slug })
    $openBetSlugs = @($bets.Values | Where-Object { $_.status -eq 'open' } | ForEach-Object { $_.slug })
    $gamma = Get-GammaMarkets (@($candidates | ForEach-Object { $_.slug }) + $newCtlSlugs + $openSlugs + $openBetSlugs)

    # Cuotas de Vegas para los mercados de ganador que se juegan pronto (informativo; si falla, se sigue sin cuotas)
    try { Update-OddsCache (Get-OddsNeededSports $candidates $gamma) } catch { Log "Cuotas: $($_.Exception.Message -replace 'apiKey=[^&\s]+', 'apiKey=***')" }

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
        $vg = Get-VegasProb $m $g $position
        $current += @{ key = $key; title = $m.title; slug = $m.slug; eventSlug = $m.eventSlug; questionID = $m.questionID
                       position = $position; score = $m.fireScore; price = [Math]::Round($price, 4); ask = $q.ask; spread = $q.spread; liq = $q.liq
                       hedgeCap = $m.hedgeCapitalRatio; endDate = $m.endDate; wallets = $ws.wallets; capital = $ws.capital
                       whaleAvgEntry = $ws.avgEntry; top = $top; vegas = $(if ($vg) { $vg.p } else { $null }); vegasBooks = $(if ($vg) { $vg.books } else { $null }) }
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

    # 3c. Apuestas: una sola por mercado (si el sitio cambia de bando, se ignora), con una copia de la estrategia vigente
    $newBets = 0
    if ($strategy) {
        $nowUtc = (Get-Date).ToUniversalTime()
        $betSlugs = @{}; foreach ($b in $bets.Values) { $betSlugs[$b.slug] = $true }
        foreach ($c in $current) {
            if ($betSlugs.ContainsKey($c.slug)) { continue }
            # No se apuesta en partidos ya empezados: en vivo los precios y las recomendaciones se distorsionan
            if (Test-Started $gamma[$c.slug]) { continue }
            # Score bajo el umbral: solo entra como apuesta conservadora si las ballenas estan muy de acuerdo
            $lowTier = $c.score -lt $strategy.th
            if ($lowTier -and -not ($strategy.lowScoreStake -gt 0 -and $c.score -ge $strategy.lowScoreMin)) { continue }
            $days = $null
            if ($c.endDate) { try { $days = ([DateTimeOffset]::Parse("$($c.endDate)").UtcDateTime - $nowUtc).TotalDays } catch {} }
            if ($strategy.maxDays -and ($null -eq $days -or $days -gt $strategy.maxDays)) { continue }
            if (-not (Test-CategoryAllowed (Get-Category "$($c.slug) $($c.eventSlug) $($c.title)") $strategy.cat)) { continue }
            if ($strategy.minLiq -and -not ($c.liq -ge $strategy.minLiq)) { continue }
            if ($strategy.maxHedge -lt 1 -and $null -ne $c.hedgeCap -and $c.hedgeCap -gt $strategy.maxHedge) { continue }
            $base = if ($strategy.priceMode -eq 'ask' -and $c.ask) { $c.ask } else { $c.price }
            $price = [Math]::Round([Math]::Min(0.99, $base + $strategy.slip / 100), 4)
            $cons = Get-Consensus $c.top $strategy
            if ($lowTier -and $cons.agree -lt $strategy.lowScoreAgree) { continue }
            if ($strategy.minAgreeAll -gt 0 -and $cons.agree -lt $strategy.minAgreeAll) { continue }
            if ($strategy.minPrice -gt 0 -and $price -lt $strategy.minPrice) { continue }
            if ($strategy.maxPrice -gt 0 -and $price -gt $strategy.maxPrice) { continue }
            if ($lowTier -and $strategy.lowScoreMaxPrice -gt 0 -and $price -gt $strategy.lowScoreMaxPrice) { continue }
            $stake = if ($lowTier) { $strategy.lowScoreStake }
                     elseif ($strategy.rule -eq 'consensus' -and $cons.ok) { $strategy.consensusStake } else { $strategy.baseStake }
            $bets[$c.key] = @{
                key = $c.key; placedAt = $now; slug = $c.slug; title = $c.title; position = $c.position
                eventSlug = $c.eventSlug; questionID = $c.questionID; endDate = $c.endDate
                score = $c.score; price = $price; stake = $stake; consensus = "$($cons.agree)/$($cons.n)"; tier = $(if ($lowTier) { 'conservadora' } else { 'normal' })
                hedgeCap = $c.hedgeCap; liq = $c.liq; vegasProb = $c.vegas; strategy = $strategy.Clone()
                status = 'open'; curPrice = $c.price; curPriceAt = $now
            }
            $betSlugs[$c.slug] = $true
            $newBets++
            Log "Apuesta$(if ($lowTier) { ' conservadora' }): `$$stake a $($c.position) en $($c.title) @ $([Math]::Round($price * 100, 1))c (score $($c.score), consenso $($cons.agree)/$($cons.n))"
        }
    }

    # 4. Precio actual y resolucion de senales y apuestas abiertas
    $resolvedCount = 0
    foreach ($s in @($signals.Values | Where-Object { $_.status -eq 'open' })) {
        $g = $gamma[$s.slug]
        if (-not $g) { continue }
        if ($status = Update-FromGamma $s $g $now) {
            $resolvedCount++
            Log "Resuelta: $($s.title) [$($s.position)] -> $status"
        }
    }
    foreach ($b in @($bets.Values | Where-Object { $_.status -eq 'open' })) {
        $g = $gamma[$b.slug]
        if (-not $g) { continue }
        if ($status = Update-FromGamma $b $g $now) {
            $b.pnl = switch ($status) { 'won' { [Math]::Round($b.stake * (1 / $b.price - 1), 4) } 'lost' { -$b.stake } default { 0 } }
            Log "Apuesta resuelta: $($b.title) [$($b.position)] -> $status ($($b.pnl))"
        }
    }

    # 4a. Decisiones del usuario sobre las alertas: issues abiertos "Decision: VENDER|MANTENER - ..." creados por
    # el dueno del repositorio (los de otras cuentas se ignoran). VENDER cierra la apuesta al precio de venta actual.
    $decisions = @()
    if (Test-Path $DecisionsFile) { $decisions = @(ConvertTo-Hash (Get-Content $DecisionsFile -Raw -Encoding UTF8 | ConvertFrom-Json)) | Where-Object { $_ } }
    $processed = @{}; foreach ($d in $decisions) { $processed["$($d.issue)"] = $true }
    $decisionsNew = @()
    $issues = @()
    try { $issues = @(Invoke-Json "https://api.github.com/repos/$Repo/issues?state=open&per_page=100" 'Get' @{ 'User-Agent' = 'fire-score-tracker' }) | ForEach-Object { $_ } }
    catch { Log "No se pudieron leer las decisiones en GitHub: $($_.Exception.Message)" }
    foreach ($iss in $issues) {
        if ($iss.pull_request -or $processed.ContainsKey("$($iss.number)")) { continue }
        if ($iss.title -notmatch '^Decision: (VENDER|MANTENER)') { continue }
        $action = $Matches[1]
        if ($iss.user.login -ne $RepoOwner) { Log "Decision #$($iss.number) ignorada: creada por $($iss.user.login)"; continue }
        if ("$($iss.body)" -notmatch 'key: `([^`]+)`') { continue }
        $key = $Matches[1]
        $b = if ($bets.Contains($key)) { $bets[$key] } else { $null }
        if (-not $b) { $result = 'No se encontro la apuesta; no se hizo nada.' }
        elseif ($b.status -ne 'open') { $result = "La apuesta ya estaba cerrada ($($b.status)); no se hizo nada." }
        elseif ($action -eq 'VENDER') {
            $q = Get-GammaQuote $gamma[$b.slug] $b.position
            $exit = if ($q.bid) { $q.bid } else { $b.curPrice }
            if ($null -eq $exit) { $result = 'No hay precio de venta disponible ahora; vuelve a intentarlo mas tarde.' }
            else {
                $b.status = 'sold'; $b.soldByAlert = $true; $b.resolvedAt = $now; $b.finalPrice = [Math]::Round($exit, 4)
                $b.pnl = [Math]::Round($b.stake * ($exit / $b.price - 1), 4)
                if ($b.alert) { $b.alert.decision = 'sell'; $b.alert.decidedAt = $now; $b.alert.closedNotified = $now }
                $result = "Vendida a $([Math]::Round($exit * 100, 1))c. Resultado: $([Math]::Round($b.pnl, 2)) USD."
            }
        } else {
            if ($b.alert) { $b.alert.decision = 'keep'; $b.alert.decidedAt = $now }
            $result = 'Se mantiene abierta hasta el resultado final.'
        }
        $entry = @{ issue = $iss.number; key = $key; action = $action; t = $now; result = $result
                    alertTitle = $(if ($b) { "Alerta de venta: $($b.title) [$($b.position)]" } else { $null })
                    sellsAlert = ($action -eq 'VENDER' -and $b -and $b.status -eq 'sold') }
        $decisions += $entry; $decisionsNew += $entry
        Log "Decision #$($iss.number) $action ($key): $result"
    }
    Write-FileAtomic $DecisionsFile (ConvertTo-Json -InputObject @($decisions) -Depth 4 -Compress)
    Write-FileAtomic $DecisionsNewFile (ConvertTo-Json -InputObject @($decisionsNew) -Depth 4)

    # 4a-bis. Alertas que el usuario decidio MANTENER: no se vuelve a preguntar salvo (una vez cada caso)
    #   'start': falta 1 hora o menos para que empiece el partido (gameStartTime); sin partido, para el cierre del mercado
    #   'half' : la apuesta vale la mitad o menos de lo pagado (precio actual <= 50% del de entrada)
    # Al dispararse, la alerta vuelve a quedar sin decision (activa en el panel) y se comenta en su issue con los botones.
    $alertsNew = @()
    $nowUtc = (Get-Date).ToUniversalTime()
    foreach ($b in @($bets.Values | Where-Object { $_.status -eq 'open' -and $_.alert -and $_.alert.decision -eq 'keep' })) {
        $g = $gamma[$b.slug]
        $fired = @($b.alert.reminders | Where-Object { $_ })
        $start = $null; $isClose = $false
        $startRaw = if ($g -and $g.gameStartTime) { "$($g.gameStartTime)" } elseif ($g -and $g.eventStartTime) { "$($g.eventStartTime)" } else { $null }
        if ($startRaw) { try { $start = [DateTimeOffset]::Parse($startRaw).UtcDateTime } catch {} }
        if (-not $start -and $b.endDate) { try { $start = [DateTimeOffset]::Parse("$($b.endDate)").UtcDateTime; $isClose = $true } catch {} }
        $kind = $null; $why = $null
        if ($fired -notcontains 'start' -and $start -and ($start - $nowUtc).TotalMinutes -le 60) {
            $kind = 'start'
            $why = if ($isClose) { "falta 1 hora o menos para el cierre del mercado ($($start.ToString('yyyy-MM-dd HH:mm')) UTC)" } else { "falta 1 hora o menos para que empiece ($($start.ToString('yyyy-MM-dd HH:mm')) UTC)" }
        } elseif ($fired -notcontains 'half' -and $null -ne $b.curPrice -and $b.curPrice -le $b.price / 2) {
            $kind = 'half'
            $why = "la apuesta vale la mitad o menos: entro a $([Math]::Round($b.price * 100, 1))c y ahora esta a $([Math]::Round($b.curPrice * 100, 1))c"
        }
        if (-not $kind) { continue }
        $b.alert.reminders = @($fired + $kind)
        $b.alert.decision = $null; $b.alert.reaskedAt = $now; $b.alert.reaskReason = $why
        $pnlNow = if ($null -ne $b.curPrice) { [Math]::Round($b.stake * ($b.curPrice / $b.price - 1), 2) } else { $null }
        $alertsNew += @{
            mode  = 'comment'
            title = "Alerta de venta: $($b.title) [$($b.position)]"
            body  = "**Recordatorio: decidiste mantener esta apuesta, pero $why.**`n`n" +
                    "- Apuesta: `$$($b.stake) a **$($b.position)** a $([Math]::Round($b.price * 100, 1))c`n" +
                    "- Precio actual: $(if ($null -ne $b.curPrice) { "$([Math]::Round($b.curPrice * 100, 1))c" } else { 'desconocido' })`n" +
                    "- Si se vende ahora: $(if ($null -ne $pnlNow) { "$pnlNow USD" } else { '-' })`n`n" +
                    "### Decide de nuevo: [⭕ Vender ahora]($(Get-DecisionUrl $b 'VENDER'))  |  [❌ Mantener]($(Get-DecisionUrl $b 'MANTENER'))`n`n" +
                    "[Panel]($PagesUrl)`n`n_Recordatorio automatico del tracker. No es asesoria financiera._"
        }
        Log "RECORDATORIO de alerta mantenida: $($b.title) [$($b.position)] - $why"
    }

    # 4b. Alertas de venta: en apuestas abiertas, si el sitio cambia de bando o las ballenas abandonan nuestro lado.
    # La apuesta no se modifica; se registra la alerta y lo que se habria obtenido vendiendo en ese momento.
    $marketBySlug = @{}; foreach ($m in $markets) { $marketBySlug[$m.slug] = $m }
    foreach ($b in @($bets.Values | Where-Object { $_.status -eq 'open' -and -not $_.alert })) {
        $m = $marketBySlug[$b.slug]
        if (-not $m) { continue }
        $sitePos = if ($m.position) { $m.position.ToString().ToUpper() } else { 'YES' }
        $topAll = Get-TopWhales $m $b.position $rank   # se asigna primero: la funcion devuelve el arreglo envuelto
        $top10 = @($topAll | Select-Object -First 10)
        $agree = @($top10 | Where-Object { $_[1] }).Count
        $reasons = @()
        if ($sitePos -ne $b.position) { $reasons += "FirePolymarket ahora recomienda $sitePos (score $($m.fireScore))" }
        # Solo si el consenso EMPEORO desde la apuesta (una apuesta hecha con 3/10 no alerta por seguir en 3/10)
        $entryAgree = if ("$($b.consensus)" -match '^(\d+)/') { [int]$Matches[1] } else { $null }
        if ($top10.Count -ge 5 -and $agree -le 3 -and ($null -eq $entryAgree -or $agree -lt $entryAgree)) { $reasons += "solo $agree de las $($top10.Count) ballenas mejor rankeadas siguen en $($b.position) (al apostar eran $(if ($null -ne $entryAgree) { $entryAgree } else { '?' }))" }
        if (-not $reasons) { continue }
        $px = $b.curPrice
        $pnlIfSold = if ($null -ne $px) { [Math]::Round($b.stake * ($px / $b.price - 1), 4) } else { $null }
        $b.alert = @{ t = $now; reasons = $reasons; newPosition = $sitePos; newScore = $m.fireScore; agree = "$agree/$($top10.Count)"; price = $px; pnlIfSold = $pnlIfSold }
        $link = if ($b.eventSlug -and $b.questionID) { "https://polymarket.com/event/$($b.eventSlug)?tid=$($b.questionID)" } else { "https://polymarket.com/event/$($b.slug)" }
        $alertsNew += @{
            title = "Alerta de venta: $($b.title) [$($b.position)]"
            body  = "**Las ballenas cambiaron de opinion en un mercado donde hay una apuesta abierta.**`n`n" +
                    "- Apuesta: `$$($b.stake) a **$($b.position)** a $([Math]::Round($b.price * 100, 1))c (registrada $($b.placedAt))`n" +
                    "- Precio actual: $(if ($null -ne $px) { "$([Math]::Round($px * 100, 1))c" } else { 'desconocido' })`n" +
                    "- Si se vende ahora: $(if ($null -ne $pnlIfSold) { "$([Math]::Round($pnlIfSold, 2)) USD" } else { '-' })`n" +
                    "- Motivo: $($reasons -join '; ')`n" +
                    "- Cierra: $($b.endDate)`n`n" +
                    "### Decide: [⭕ Vender ahora]($(Get-DecisionUrl $b 'VENDER'))  |  [❌ Mantener]($(Get-DecisionUrl $b 'MANTENER'))`n`n" +
                    "[Ver mercado en Polymarket]($link) | [Panel]($PagesUrl)`n`n_Alerta automatica del tracker. No es asesoria financiera._"
        }
        Log "ALERTA DE VENTA: $($b.title) [$($b.position)] - $($reasons -join '; ')"
    }
    # 4d. Resumen semanal: cada lunes desde las 8:00 (hora local), una vez por semana; se envia como issue con las alertas
    $WeeklyStateFile = Join-Path $DataDir 'weekly-state.json'
    $localNow = Get-Date
    $weekId = '{0}-W{1:00}' -f $localNow.Year, [Globalization.CultureInfo]::InvariantCulture.Calendar.GetWeekOfYear($localNow, 'FirstFourDayWeek', 'Monday')
    $lastWeek = if (Test-Path $WeeklyStateFile) { (Get-Content $WeeklyStateFile -Raw | ConvertFrom-Json).lastWeek } else { $null }
    if (-not $lastWeek) {
        Write-FileAtomic $WeeklyStateFile (ConvertTo-Json @{ lastWeek = $weekId })   # primera vez: el primer resumen sale el proximo lunes
    } elseif ($env:FST_FORCE_WEEKLY -or ($lastWeek -ne $weekId -and -not ($localNow.DayOfWeek -eq 'Monday' -and $localNow.Hour -lt 8))) {
        $alertsNew += @{ title = "Resumen semanal: $($localNow.AddDays(-7).ToString('dd/MM')) al $($localNow.ToString('dd/MM/yyyy'))"; body = (Get-WeeklyReport $signals $bets $strategy) }
        if (-not $env:FST_FORCE_WEEKLY) { Write-FileAtomic $WeeklyStateFile (ConvertTo-Json @{ lastWeek = $weekId }) }
        Log "Resumen semanal generado ($weekId)"
    }

    Write-FileAtomic $AlertsNewFile (ConvertTo-Json -InputObject @($alertsNew) -Depth 4)

    # 4c. Alertas resueltas: el workflow busca el issue por titulo, deja el resultado como comentario y lo cierra (una sola vez)
    $alertsClose = @()
    foreach ($b in @($bets.Values | Where-Object { $_.alert -and $_.status -ne 'open' -and -not $_.alert.closedNotified })) {
        $label = switch ($b.status) { 'won' { 'GANO' } 'lost' { 'PERDIO' } default { 'ANULADA' } }
        $sold = $b.alert.pnlIfSold
        $verdict = if ($null -eq $sold) { '' } elseif ($sold -gt $b.pnl) { 'Hacerle caso a la alerta habria sido MEJOR.' } elseif ($sold -lt $b.pnl) { 'Hacerle caso a la alerta habria sido PEOR.' } else { 'Habria dado lo mismo.' }
        $alertsClose += @{
            title = "Alerta de venta: $($b.title) [$($b.position)]"
            body  = "**Mercado resuelto: la apuesta $label.**`n`n" +
                    "- Apuesta: `$$($b.stake) a **$($b.position)** a $([Math]::Round($b.price * 100, 1))c`n" +
                    "- Resultado manteniendo hasta el final: $([Math]::Round($b.pnl, 2)) USD`n" +
                    "- Si se hubiera vendido en la alerta: $(if ($null -ne $sold) { "$([Math]::Round($sold, 2)) USD" } else { '-' })`n`n$verdict`n`n_Issue cerrado automaticamente por el tracker._"
        }
        $b.alert.closedNotified = $now
    }
    Write-FileAtomic $AlertsCloseFile (ConvertTo-Json -InputObject @($alertsClose) -Depth 4)

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
    # El tracker corre cada 5 minutos, pero el historico de mercados se guarda una vez por hora para no inflar el archivo
    $lastSnap = $null
    if (Test-Path $SnapFile) {
        $last = Get-Content $SnapFile -Tail 1 -Encoding UTF8
        if ($last -match '^"([^"]+)"') { try { $lastSnap = [DateTimeOffset]::Parse($Matches[1]).UtcDateTime } catch {} }
    }
    $snapDue = -not $lastSnap -or ((Get-Date).ToUniversalTime() - $lastSnap).TotalMinutes -ge 55
    if ($rows -and $snapDue) { $rows | Export-Csv -Path $SnapFile -Append -NoTypeInformation -Encoding UTF8 }

    # 6. Guardar
    $above70 = @($candidates | Where-Object { $_.fireScore -ge 70 }).Count
    $runs += [pscustomobject]@{ t = $now; markets = $markets.Count; above60 = $candidates.Count; above70 = $above70; newSignals = $newCount; resolved = $resolvedCount }
    if ($runs.Count -gt 10000) { $runs = $runs[-10000..-1] }

    $sigArr = @($signals.Values | Sort-Object { $_.firstSeen })
    $sigJson = ConvertTo-Json -InputObject $sigArr -Depth 8 -Compress
    Write-FileAtomic $SignalsFile $sigJson
    Write-FileAtomic $RunsFile (ConvertTo-Json -InputObject @($runs) -Depth 4 -Compress)
    # Al panel solo van las ultimas ejecuciones (el archivo completo queda en runs.json)
    $runsJson = ConvertTo-Json -InputObject @($runs | Select-Object -Last 300) -Depth 4 -Compress
    $curJson = ConvertTo-Json -InputObject @($current) -Depth 4 -Compress
    $betsJson = ConvertTo-Json -InputObject @($bets.Values) -Depth 6 -Compress
    Write-FileAtomic $BetsFile $betsJson
    $stratJson = if ($strategy) { ConvertTo-Json -InputObject $strategy -Depth 3 -Compress } else { 'null' }

    $js = "window.TRACKER_DATA = {`"generatedAt`":`"$now`",`"siteUpdatedAt`":`"$($site.lastUpdated)`",`"thresholds`":[$($Thresholds -join ',')],`"signals`":$sigJson,`"runs`":$runsJson,`"current`":$curJson,`"bets`":$betsJson,`"strategy`":$stratJson};"
    Write-FileAtomic $DataJsFile $js

    $ctlTotal = @($signals.Values | Where-Object { $_.kind -eq 'control' }).Count
    Log "OK: $($candidates.Count) mercados >= $MinTrack, $above70 >= 70, $newCount senales nuevas, $newCtl de control nuevas, $newBets apuestas nuevas ($($bets.Count) en el historial), $($alertsNew.Count) alertas de venta, $resolvedCount resueltas, $($signals.Count - $ctlTotal) senales + $ctlTotal de control"
    exit 0
} catch {
    Log "ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
    exit 1
}
