# Copiadores: replican automaticamente las apuestas de apostadores de Polymarket en una categoria.
# Cada archivo de copiers/*.json es un copiador (por ejemplo, NFL de Elaran1993 o Fed de MysticFind).
# Cada ejecucion, por copiador: lee las posiciones abiertas del apostador en esa categoria, copia las nuevas
# al precio de compra del momento, imita sus salidas y resuelve con la API de Polymarket.
# Las copias quedan fijas en data/copy-<id>-bets.json (solo cambia su resultado).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root       = $PSScriptRoot
$DataDir    = Join-Path $Root 'data'
New-Item -ItemType Directory -Force $DataDir | Out-Null
$ConfigDir  = Join-Path $Root 'copiers'
$IndexFile  = Join-Path $DataDir 'copiers.js'
$LogFile    = Join-Path $DataDir 'log.txt'
$GammaUrl   = 'https://gamma-api.polymarket.com/markets'
$DataApi    = 'https://data-api.polymarket.com'
$Utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $Root 'categories.ps1')   # Get-Category: mismas categorias que el tracker y el panel

$DefaultConfig = [ordered]@{
    version = 1; nota = ''; title = ''
    traderName = ''; traderWallet = ''
    category = ''             # solo mercados de esta categoria (ver categories.ps1)
    eventPrefix = ''          # alternativa: solo eventos cuyo slug empieza asi
    stake = 5                 # USD por cada posicion copiada
    minTraderUsd = 1000       # ignora posiciones del apostador menores a esto
    mirrorExits = $true       # si el vende antes del final, nosotros tambien
}
$script:CopierId = ''

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [copia:$script:CopierId] $msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}
function Get-NowIso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function ConvertTo-Hash($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }; return $h
    }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return ,@($o | ForEach-Object { ConvertTo-Hash $_ }) }
    return $o
}
function Write-FileAtomic($path, $text) { $tmp = "$path.tmp"; [IO.File]::WriteAllText($tmp, $text, $Utf8); Move-Item -Force $tmp $path }
# PowerShell 5.1 decodifica mal UTF-8 sin charset; se decodifica a mano
function Invoke-Json($uri) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
            return (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()))) | ForEach-Object { $_ }
        } catch { if ($i -eq 3) { throw }; Start-Sleep -Seconds (5 * $i) }
    }
}
function ConvertFrom-JsonArray($text) { (ConvertFrom-Json $text) | ForEach-Object { $_ } }
function Find-OutcomeIndex($outcomes, $outcome) {
    $p = "$outcome".Trim().ToLower()
    for ($i = 0; $i -lt $outcomes.Count; $i++) { if ($outcomes[$i].Trim().ToLower() -eq $p) { return $i } }
    return -1
}
# Precio medio, de compra (ask) y de venta (bid) del resultado; bestBid/bestAsk de Gamma son del primer resultado
function Get-Quote($g, $outcome) {
    $q = @{ mid = $null; ask = $null; bid = $null }
    if (-not $g -or -not $g.outcomes) { return $q }
    $outs = @(ConvertFrom-JsonArray $g.outcomes); $prices = @(ConvertFrom-JsonArray $g.outcomePrices)
    $idx = Find-OutcomeIndex $outs $outcome
    if ($idx -lt 0) { return $q }
    $q.mid = [double]$prices[$idx]
    if ($idx -eq 0) { if ($null -ne $g.bestAsk) { $q.ask = [double]$g.bestAsk }; if ($null -ne $g.bestBid) { $q.bid = [double]$g.bestBid } }
    elseif ($idx -eq 1) { if ($null -ne $g.bestBid) { $q.ask = [Math]::Round(1 - [double]$g.bestBid, 4) }; if ($null -ne $g.bestAsk) { $q.bid = [Math]::Round(1 - [double]$g.bestAsk, 4) } }
    return $q
}
function Get-GammaMarkets($slugs) {
    $res = @{}; $list = @($slugs | Where-Object { $_ } | Select-Object -Unique)
    # Gamma solo devuelve mercados abiertos por defecto; los que falten se buscan con closed=true (asi se detectan los resultados)
    foreach ($extra in '', '&closed=true') {
        $pending = @($list | Where-Object { -not $res.ContainsKey($_) })
        for ($i = 0; $i -lt $pending.Count; $i += 20) {
            $chunk = $pending[$i..([Math]::Min($i + 19, $pending.Count - 1))]
            $qs = ($chunk | ForEach-Object { 'slug=' + [Uri]::EscapeDataString($_) }) -join '&'
            try { foreach ($m in (Invoke-Json "$GammaUrl`?$qs&limit=100$extra")) { if ($m.slug) { $res[$m.slug] = $m } } } catch { Log "Gamma error: $($_.Exception.Message)" }
        }
    }
    return $res
}

# Posiciones por billetera (dos copiadores del mismo apostador comparten la consulta)
$PositionsCache = @{}
function Get-TraderPositions($wallet) {
    if (-not $PositionsCache.ContainsKey($wallet)) { $PositionsCache[$wallet] = @(Invoke-Json "$DataApi/positions?user=$wallet&limit=500&sizeThreshold=1") }
    return $PositionsCache[$wallet]
}

function Invoke-Copier($ConfigFile) {
    $now = Get-NowIso
    $cfg = ConvertTo-Hash (Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    foreach ($k in $DefaultConfig.Keys) { if (-not $cfg.ContainsKey($k)) { $cfg[$k] = $DefaultConfig[$k] } }
    if (-not $cfg.id) { $cfg.id = [IO.Path]::GetFileNameWithoutExtension($ConfigFile) }
    $script:CopierId = $cfg.id
    if (-not $cfg.traderWallet -or (-not $cfg.category -and -not $cfg.eventPrefix)) { throw 'falta traderWallet o category en la configuracion' }
    $BetsFile = Join-Path $DataDir "copy-$($cfg.id)-bets.json"
    $JsFile   = Join-Path $DataDir "copy-$($cfg.id).js"

    $firstRun = -not (Test-Path $BetsFile)
    $bets = [ordered]@{}
    if (-not $firstRun) {
        foreach ($b in (ConvertTo-Hash (Get-Content $BetsFile -Raw -Encoding UTF8 | ConvertFrom-Json))) { if ($b -and $b.key) { $bets[$b.key] = $b } }
    }

    # Posiciones del apostador en la categoria elegida; por mercado se toma su lado principal
    $all = Get-TraderPositions $cfg.traderWallet
    $mine = @($all | Where-Object {
        if ($cfg.eventPrefix) { "$($_.eventSlug)".StartsWith($cfg.eventPrefix) }
        else { (Get-Category "$($_.slug) $($_.eventSlug) $($_.title)") -eq $cfg.category } })
    $main = @($mine | Group-Object conditionId | ForEach-Object { $_.Group | Sort-Object currentValue -Descending | Select-Object -First 1 })
    $live = @($main | Where-Object { -not $_.redeemable -and $_.currentValue -ge $cfg.minTraderUsd -and $_.curPrice -gt 0.01 -and $_.curPrice -lt 0.99 })
    $traderByKey = @{}; foreach ($p in $mine) { $traderByKey["$($p.slug)|$("$($p.outcome)".ToUpper())"] = $p }

    $openSlugs = @($bets.Values | Where-Object { $_.status -eq 'open' } | ForEach-Object { $_.slug })
    $gamma = Get-GammaMarkets (@($live | ForEach-Object { $_.slug }) + $openSlugs)

    # 1. Copiar posiciones nuevas
    # Una sola copia por mercado: si el apostador cambia de lado despues, no se copia el otro lado
    $newCount = 0
    $copiedSlugs = @{}; foreach ($b in $bets.Values) { $copiedSlugs[$b.slug] = $true }
    foreach ($p in $live) {
        $key = "$($p.slug)|$("$($p.outcome)".ToUpper())"
        if ($copiedSlugs.ContainsKey($p.slug)) { continue }
        $g = $gamma[$p.slug]
        if ($g -and $g.closed -eq $true) { continue }
        $q = Get-Quote $g $p.outcome
        $price = if ($q.ask) { $q.ask } elseif ($q.mid) { $q.mid } else { [double]$p.curPrice }
        $price = [Math]::Round([Math]::Min(0.99, $price), 4)
        $bets[$key] = @{
            key = $key; copiedAt = $now; slug = $p.slug; title = $p.title; outcome = $p.outcome
            eventSlug = $p.eventSlug; endDate = $p.endDate; price = $price; stake = $cfg.stake
            traderAvgPrice = [Math]::Round([double]$p.avgPrice, 4); traderValue = [Math]::Round([double]$p.currentValue)
            traderSize = [double]$p.size; preexisting = $firstRun; strategy = $cfg.Clone()
            status = 'open'; curPrice = $(if ($q.mid) { $q.mid } else { [double]$p.curPrice }); curPriceAt = $now
        }
        $copiedSlugs[$p.slug] = $true
        $newCount++
        Log "Copia: `$$($cfg.stake) a $($p.outcome) en $($p.title) @ $([Math]::Round($price * 100, 1))c (el entro a $([Math]::Round($p.avgPrice * 100, 1))c con `$$([Math]::Round($p.currentValue)))"
    }

    # 2. Actualizar abiertas: resultado del mercado o salida del apostador
    $closedCount = 0
    foreach ($b in @($bets.Values | Where-Object { $_.status -eq 'open' })) {
        $g = $gamma[$b.slug]
        $q = Get-Quote $g $b.outcome
        if ($null -ne $q.mid) { $b.curPrice = [Math]::Round($q.mid, 4); $b.curPriceAt = $now }
        if ($g -and $g.closed -eq $true) {
            $p = $q.mid; $status = $null
            if ($null -eq $p) { $status = 'void' } elseif ($p -ge 0.99) { $status = 'won' } elseif ($p -le 0.01) { $status = 'lost' } elseif ($g.umaResolutionStatus -eq 'resolved') { $status = 'void' }
            if ($status) {
                $b.status = $status; $b.resolvedAt = $now; $b.finalPrice = $p
                $b.pnl = switch ($status) { 'won' { [Math]::Round($b.stake * (1 / $b.price - 1), 4) } 'lost' { -$b.stake } default { 0 } }
                $closedCount++; Log "Resuelta: $($b.title) [$($b.outcome)] -> $status ($($b.pnl))"
            }
            continue
        }
        if ($cfg.mirrorExits) {
            $hp = $traderByKey[$b.key]
            if (-not $hp -or [double]$hp.size -lt 0.2 * [double]$b.traderSize) {
                $exit = if ($q.bid) { $q.bid } elseif ($q.mid) { $q.mid } else { $null }
                if ($null -ne $exit) {
                    $b.status = 'sold'; $b.resolvedAt = $now; $b.finalPrice = [Math]::Round($exit, 4)
                    $b.pnl = [Math]::Round($b.stake * ($exit / $b.price - 1), 4)
                    $closedCount++; Log "Vendida (el salio): $($b.title) [$($b.outcome)] @ $([Math]::Round($exit * 100, 1))c ($($b.pnl))"
                }
            }
        }
    }

    # 3. Guardar
    $betsJson = ConvertTo-Json -InputObject @($bets.Values) -Depth 6 -Compress
    Write-FileAtomic $BetsFile $betsJson
    $traderNow = @($main | Where-Object { -not $_.redeemable -and $_.currentValue -gt 1 } | ForEach-Object {
        @{ title = $_.title; outcome = $_.outcome; slug = $_.slug; eventSlug = $_.eventSlug; avgPrice = $_.avgPrice; curPrice = $_.curPrice
           value = [Math]::Round([double]$_.currentValue); pnl = [Math]::Round([double]$_.cashPnl); endDate = $_.endDate } })
    $cfgJson = ConvertTo-Json -InputObject $cfg -Depth 3 -Compress
    $traderJson = ConvertTo-Json -InputObject $traderNow -Depth 3 -Compress
    Write-FileAtomic $JsFile "window.COPY_DATA = {`"generatedAt`":`"$now`",`"strategy`":$cfgJson,`"bets`":$betsJson,`"traderPositions`":$traderJson};"

    Log "OK: $($live.Count) posiciones de $($cfg.traderName) a copiar, $newCount copias nuevas, $closedCount cerradas, $($bets.Count) en el historial"
    return @{ id = $cfg.id; title = $cfg.title; traderName = $cfg.traderName; category = $cfg.category }
}

# Cada copiador corre por separado: si uno falla, los demas siguen
$failed = 0; $index = @()
foreach ($f in @(Get-ChildItem (Join-Path $ConfigDir '*.json') -ErrorAction SilentlyContinue | Sort-Object Name)) {
    try { $index += Invoke-Copier $f.FullName }
    catch { $failed++; Log "ERROR ($($f.Name)): $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }
}
# Lista de copiadores para las pestanas del panel
Write-FileAtomic $IndexFile "window.COPIERS = $(ConvertTo-Json -InputObject @($index) -Depth 3 -Compress);"
exit $(if ($failed) { 1 } else { 0 })
