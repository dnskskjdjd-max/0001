# Descarga partidos deportivos ya resueltos de Polymarket para investigar estrategias propias (sin FirePolymarket).
# Por cada mercado principal (ganador, spread, total) guarda: liga, tipo, linea, hora de inicio, comision, volumen,
# resultado y el precio del primer resultado en las 48 h previas al inicio (cada 10 min, historial de precios de la CLOB).
# Salida: research/data/sports/<liga><Part>.jsonl (una linea por mercado). Se puede cortar y volver a correr.
# La API de eventos no pasa de ~2100 resultados por consulta (offset): se recorre por tramos de fecha de cierre
# (ChunkHours) y un tramo que llega al tope se divide en dos. Para ir mas rapido se puede repartir el periodo entre
# varios procesos con -FromDay/-Days/-Part (por ejemplo dias 0-15 en "-a", 15-30 en "-b"); cada uno escribe su archivo.
param([string]$League = 'nfl', [int]$Days = 60, [int]$FromDay = 0, [double]$ChunkHours = 24, [string]$Part = '',
    [int]$MaxDays = 60, [double]$MinVolume = 5000)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Out = Join-Path $PSScriptRoot 'data\sports'; New-Item -ItemType Directory -Force $Out | Out-Null
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Inv = [Globalization.CultureInfo]::InvariantCulture
$LogFile = Join-Path $Out "download-$League$Part.log"
function Log($msg) { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" -Encoding UTF8 }
function Get-Text($u) {
    for ($i = 1; $i -le 6; $i++) {
        try {
            $req = [Net.HttpWebRequest]::Create($u); $req.UserAgent = 'Mozilla/5.0'; $req.Timeout = 30000
            $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
            $resp = $req.GetResponse()
            try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); return $sr.ReadToEnd() } finally { $resp.Close() }
        } catch { Start-Sleep -Seconds (2 * $i) }
    }
    throw "fallo: $u"
}
function J($u) { return (ConvertFrom-Json (Get-Text $u)) }
# Lectura compartida: otros procesos pueden estar escribiendo sus archivos
function Read-Lines($path) {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $sr = New-Object IO.StreamReader($fs, $Utf8); return @($sr.ReadToEnd() -split "`n") } finally { $fs.Close() }
}
$file = Join-Path $Out "$League$Part.jsonl"
# Mercados ya guardados en cualquier archivo de la liga (soccer.jsonl, soccer-a.jsonl, ...)
$done = @{}
foreach ($f in @(Get-ChildItem $Out -Filter "$League*.jsonl")) {
    if ($f.BaseName -ne $League -and $f.BaseName -notlike "$League-*") { continue }
    foreach ($l in (Read-Lines $f.FullName)) { if ($l -match '"slug":"([^"]+)"') { $done[$Matches[1]] = 1 } }
}
$nowUtc = [DateTime]::UtcNow
$minStart = $nowUtc.AddDays(- $MaxDays)
Log "inicio $League$Part (dias $FromDay a $Days, tramos de $ChunkHours h, ya guardados $($done.Count))"
$sw = New-Object IO.StreamWriter($file, $true, $Utf8)
$script:nEv = 0; $script:nMk = 0

function Save-Market($e, $m) {
    if ($m.sportsMarketType -notin 'moneyline', 'spreads', 'totals') { return }
    if (-not $m.gameStartTime -or -not $m.closed -or $done.ContainsKey($m.slug)) { return }
    if ([double]$m.volumeNum -lt $MinVolume) { return }
    $start = [DateTimeOffset]::Parse(("$($m.gameStartTime)" -replace '\+00$', '+00:00'), $Inv).ToUniversalTime()
    if ($start.UtcDateTime -lt $minStart -or $start.UtcDateTime -gt $nowUtc) { return }
    $op = @((ConvertFrom-Json "$($m.outcomePrices)") | ForEach-Object { [double]$_ })
    if ($op.Count -ne 2) { return }
    $win = if ($op[0] -ge 0.99) { 0 } elseif ($op[1] -ge 0.99) { 1 } else { return }   # 50/50 o sin resolver: se salta
    $outs = @((ConvertFrom-Json "$($m.outcomes)") | ForEach-Object { "$_" -replace '"', "'" })
    $tok = @((ConvertFrom-Json "$($m.clobTokenIds)") | ForEach-Object { "$_" })
    $s0 = $start.ToUnixTimeSeconds()
    $h = $null
    try { $h = J "https://clob.polymarket.com/prices-history?market=$($tok[0])&startTs=$($s0 - 172800)&endTs=$($s0 + 60)&fidelity=10" } catch { }
    $pts = @(); if ($h -and $h.history) { $pts = @($h.history | ForEach-Object { "[$([int](([long]$_.t - $s0) / 60)),$(([double]$_.p).ToString($Inv))]" }) }
    if ($pts.Count -lt 3) { return }
    $fee = if ($m.feesEnabled -eq $true -and $m.feeSchedule -and $null -ne $m.feeSchedule.rate) { [double]$m.feeSchedule.rate } else { 0 }
    $line = if ($null -ne $m.line) { ([double]$m.line).ToString($Inv) } else { 'null' }
    $sw.WriteLine("{`"slug`":`"$($m.slug)`",`"ev`":`"$($e.slug)`",`"league`":`"$League`",`"type`":`"$($m.sportsMarketType)`",`"line`":$line,`"start`":$s0,`"fee`":$($fee.ToString($Inv)),`"vol`":$([int]$m.volumeNum),`"o`":[`"$($outs[0])`",`"$($outs[1])`"],`"win`":$win,`"h`":[$($pts -join ',')]}")
    $sw.Flush(); $done[$m.slug] = 1; $script:nMk++
}

# Eventos cerrados con fecha de cierre entre $lo y $hi; si la consulta llega al tope de la API, el tramo se divide
function Get-Range([DateTime]$lo, [DateTime]$hi) {
    $f1 = $lo.ToString('yyyy-MM-ddTHH:mm:ssZ'); $f2 = $hi.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $split = $false
    for ($off = 0; $off -le 2000; $off += 100) {
        $evs = $null
        try { $evs = @(J "https://gamma-api.polymarket.com/events?tag_slug=$League&closed=true&end_date_min=$f1&end_date_max=$f2&limit=100&offset=$off&order=endDate&ascending=false") } catch { }
        if ($null -eq $evs) { $split = $true; break }
        foreach ($e in $evs) {
            foreach ($m in @($e.markets | ForEach-Object { $_ })) { try { Save-Market $e $m } catch { Log "error en $($m.slug): $($_.Exception.Message)" } }
            $script:nEv++
        }
        if ($evs.Count -lt 100) { return }
        if ($off -eq 2000) { $split = $true }
    }
    if ($split) {
        if (($hi - $lo).TotalMinutes -lt 30) { Log "tramo $f1 .. $f2 sin terminar (tope de la API en menos de 30 min)"; return }
        $mid = $lo.AddTicks([long](($hi - $lo).Ticks / 2))
        Log "tramo $f1 .. $f2 llego al tope; se divide en dos"
        Get-Range $lo $mid; Get-Range $mid $hi
    }
}

try {
    $newest = $nowUtc.AddDays(- $FromDay); $oldest = $nowUtc.AddDays(- $Days)
    if ($FromDay -eq 0) { Get-Range $nowUtc $nowUtc.AddDays(90) }   # eventos ya cerrados con fecha de cierre futura
    for ($top = $newest; $top -gt $oldest; $top = $top.AddHours(- $ChunkHours)) {
        $bot = $top.AddHours(- $ChunkHours); if ($bot -lt $oldest) { $bot = $oldest }
        Get-Range $bot $top
        Log "hasta $($bot.ToString('MM-dd HH:mm')) UTC: eventos $($script:nEv), mercados nuevos $($script:nMk)"
    }
} finally { $sw.Close() }
Log "fin $League$Part : eventos $($script:nEv), mercados nuevos $($script:nMk)"
