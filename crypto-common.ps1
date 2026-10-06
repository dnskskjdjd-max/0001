# Funciones compartidas por los bots de cripto (crypto-daily.ps1 y crypto-fast.ps1). Solo Bitcoin, todo simulado.
# Precio: Binance BTCUSDT. Volatilidad: indice DVOL de Deribit (implicita a 30 dias) o la realizada de Binance.
# Comision de Polymarket en cripto (solo taker): fee = acciones x 0.07 x p x (1 - p)  (docs.polymarket.com/trading/fees)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$CUtf8 = New-Object System.Text.UTF8Encoding $false
$CHeaders = @{ 'User-Agent' = 'Mozilla/5.0' }
$CFeeRate = 0.07
$CSecPerYear = 31536000.0

function Get-CJson([string]$u, [int]$tries = 3, [int]$timeout = 20) {
    for ($i = 1; $i -le $tries; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing $u -Headers $CHeaders -TimeoutSec $timeout
            return (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())))
        } catch { if ($i -eq $tries) { throw }; Start-Sleep -Milliseconds (700 * $i) }
    }
}
# Arreglo JSON guardado como texto (p. ej. clobTokenIds '["1","2"]'). PowerShell 5.1 no lo desarma solo.
function Get-JArr($s) { if (-not $s) { return , @() }; return , @((ConvertFrom-Json "$s") | ForEach-Object { $_ }) }
function Write-CFileAtomic($path, $text) { $tmp = "$path.tmp"; [IO.File]::WriteAllText($tmp, $text, $CUtf8); Move-Item -Force $tmp $path }
function Read-CJsonArray($path) {
    if (-not (Test-Path $path)) { return @() }
    $raw = [IO.File]::ReadAllText($path, $CUtf8)
    if (-not $raw.Trim()) { return @() }
    return @((ConvertFrom-Json $raw) | ForEach-Object { $_ } | Where-Object { $_ })
}
function Write-CLog($logFile, $tag, $msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$tag] $msg"
    for ($i = 0; $i -lt 3; $i++) { try { Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 200 } }
    Write-Host $line
}

# Funcion de distribucion normal estandar (Abramowitz-Stegun 26.2.17, error < 1e-7)
function Get-NormCdf([double]$x) {
    $t = 1 / (1 + 0.2316419 * [Math]::Abs($x))
    $d = 0.3989422804014327 * [Math]::Exp(-$x * $x / 2)
    $p = $d * $t * (0.319381530 + $t * (-0.356563782 + $t * (1.781477937 + $t * (-1.821255978 + $t * 1.330274429))))
    if ($x -ge 0) { return 1 - $p } else { return $p }
}

function Get-BtcSpot { return [double](Get-CJson 'https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT').price }
# Velas de Binance: [openTime, open, high, low, close, ...]. Devuelve siempre un arreglo de velas.
function Get-BtcKlines([string]$interval, [int]$limit, $startMs = $null) {
    $u = "https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=$interval&limit=$limit"
    if ($startMs) { $u += "&startTime=$startMs" }
    $k = Get-CJson $u
    if ($null -eq $k) { return , @() }
    if ($k.Count -gt 0 -and $k[0] -isnot [array]) { return , @(, $k) }   # una sola vela
    return , @($k)
}
# Volatilidad anual realizada con velas de 1 minuto
function Get-RealizedVol([int]$minutes = 240) {
    $k = Get-BtcKlines '1m' ([Math]::Min(1000, $minutes + 1))
    if ($k.Count -lt 10) { return $null }
    $r = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt $k.Count; $i++) { $r.Add([Math]::Log([double]$k[$i][4] / [double]$k[$i - 1][4])) }
    $m = ($r | Measure-Object -Average).Average
    $v = 0.0; foreach ($x in $r) { $v += ($x - $m) * ($x - $m) }
    return [Math]::Sqrt($v / ($r.Count - 1) * 525600)
}
# DVOL de Deribit (volatilidad implicita anual de BTC, en tanto por uno)
function Get-Dvol {
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $r = Get-CJson "https://www.deribit.com/api/v2/public/get_volatility_index_data?currency=BTC&resolution=3600&start_timestamp=$($now - 4 * 3600000)&end_timestamp=$now"
        $d = @($r.result.data)
        if (-not $d.Count) { return $null }
        return [double]$d[$d.Count - 1][4] / 100
    } catch { return $null }
}

function Get-CryptoFee([double]$p) { return $CFeeRate * $p * (1 - $p) }   # por accion, en USDC
function Get-StakeForEdge([double]$edge, $tiers) {
    foreach ($t in @($tiers | Sort-Object { - [double]$_.edge })) { if ($edge -ge [double]$t.edge) { return [double]$t.stake } }
    return 0
}
# Libros de ordenes de varios tokens en una sola llamada. Devuelve @{ token = @{ asks = [mejor primero]; bids = [mejor primero] } }
function Get-Books([string[]]$tokens) {
    $body = ConvertTo-Json -Compress -InputObject @($tokens | ForEach-Object { @{ token_id = $_ } })
    $r = $null
    for ($i = 1; $i -le 2; $i++) {
        try { $r = Invoke-RestMethod -Method Post -Uri 'https://clob.polymarket.com/books' -Body $body -ContentType 'application/json' -Headers $CHeaders -TimeoutSec 15; break }
        catch { if ($i -eq 2) { throw }; Start-Sleep -Milliseconds 500 }
    }
    $out = @{}
    foreach ($b in @($r | ForEach-Object { $_ })) {
        $out["$($b.asset_id)"] = @{
            asks = @(@($b.asks) | Where-Object { $_ } | Sort-Object { [double]$_.price })
            bids = @(@($b.bids) | Where-Object { $_ } | Sort-Object { - [double]$_.price })
        }
    }
    return $out
}
# Precio medio al comprar por $usd recorriendo las ofertas de venta (sin comision). $null si no hay profundidad suficiente.
function Get-FillPrice($asks, [double]$usd) {
    $left = $usd; $shares = 0.0
    foreach ($a in $asks) {
        $p = [double]$a.price; $cap = [double]$a.size * $p
        if ($cap -ge $left) { $shares += $left / $p; $left = 0; break }
        $shares += [double]$a.size; $left -= $cap
    }
    if ($left -gt 1e-9 -or $shares -le 0) { return $null }
    return $usd / $shares
}
# Resultado simulado de una apuesta: se gastan $stake en acciones a $price y se paga la comision aparte
function Get-CryptoPnl($bet, [bool]$won) {
    $shares = [double]$bet.stake / [double]$bet.price
    if ($won) { return [Math]::Round($shares - [double]$bet.stake - [double]$bet.fee, 4) }
    return [Math]::Round(- [double]$bet.stake - [double]$bet.fee, 4)
}
