# Descarga partidos deportivos ya resueltos de Polymarket para investigar estrategias propias (sin FirePolymarket).
# Por cada mercado principal (ganador, spread, total) guarda: liga, tipo, linea, hora de inicio, comision, volumen,
# resultado y el precio del primer resultado en las 48 h previas al inicio (cada 10 min, historial de precios de la CLOB).
# Salida: research/data/sports/<liga>.jsonl (una linea por mercado). Se puede cortar y volver a correr.
param([string]$League = 'nfl', [int]$Days = 60, [double]$MinVolume = 5000)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Out = Join-Path $PSScriptRoot 'data\sports'; New-Item -ItemType Directory -Force $Out | Out-Null
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Inv = [Globalization.CultureInfo]::InvariantCulture
$LogFile = Join-Path $Out "download-$League.log"
function Log($m) { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" -Encoding UTF8 }
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
$file = Join-Path $Out "$League.jsonl"
$done = @{}; if (Test-Path $file) { foreach ($l in [IO.File]::ReadAllLines($file)) { if ($l -match '"slug":"([^"]+)"') { $done[$Matches[1]] = 1 } } }
$since = [DateTime]::UtcNow.AddDays(- $Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
$nowUtc = [DateTime]::UtcNow
Log "inicio $League ($Days dias, ya guardados $($done.Count))"
$sw = New-Object IO.StreamWriter($file, $true, $Utf8)
$nEv = 0; $nMk = 0
try {
    for ($off = 0; $off -lt 20000; $off += 100) {
        $evs = @(J "https://gamma-api.polymarket.com/events?tag_slug=$League&closed=true&end_date_min=$since&limit=100&offset=$off&order=endDate&ascending=false")
        if (-not $evs.Count) { break }
        foreach ($e in $evs) {
            foreach ($m in @($e.markets | ForEach-Object { $_ })) {
                if ($m.sportsMarketType -notin 'moneyline', 'spreads', 'totals') { continue }
                if (-not $m.gameStartTime -or -not $m.closed -or $done.ContainsKey($m.slug)) { continue }
                if ([double]$m.volumeNum -lt $MinVolume) { continue }
                $start = [DateTimeOffset]::Parse(("$($m.gameStartTime)" -replace '\+00$', '+00:00'), $Inv).ToUniversalTime()
                if ($start.UtcDateTime -lt [DateTime]::UtcNow.AddDays(- $Days) -or $start.UtcDateTime -gt $nowUtc) { continue }
                $op = @((ConvertFrom-Json "$($m.outcomePrices)") | ForEach-Object { [double]$_ })
                if ($op.Count -ne 2) { continue }
                $win = if ($op[0] -ge 0.99) { 0 } elseif ($op[1] -ge 0.99) { 1 } else { continue }   # 50/50 o sin resolver: se salta
                $outs = @((ConvertFrom-Json "$($m.outcomes)") | ForEach-Object { "$_" -replace '"', "'" })
                $tok = @((ConvertFrom-Json "$($m.clobTokenIds)") | ForEach-Object { "$_" })
                $s0 = $start.ToUnixTimeSeconds()
                $h = $null
                try { $h = J "https://clob.polymarket.com/prices-history?market=$($tok[0])&startTs=$($s0 - 172800)&endTs=$($s0 + 60)&fidelity=10" } catch { }
                $pts = @(); if ($h -and $h.history) { $pts = @($h.history | ForEach-Object { "[$([int](([long]$_.t - $s0) / 60)),$(([double]$_.p).ToString($Inv))]" }) }
                if ($pts.Count -lt 3) { continue }
                $fee = if ($m.feesEnabled -eq $true -and $m.feeSchedule -and $null -ne $m.feeSchedule.rate) { [double]$m.feeSchedule.rate } else { 0 }
                $line = if ($null -ne $m.line) { ([double]$m.line).ToString($Inv) } else { 'null' }
                $sw.WriteLine("{`"slug`":`"$($m.slug)`",`"ev`":`"$($e.slug)`",`"league`":`"$League`",`"type`":`"$($m.sportsMarketType)`",`"line`":$line,`"start`":$s0,`"fee`":$($fee.ToString($Inv)),`"vol`":$([int]$m.volumeNum),`"o`":[`"$($outs[0])`",`"$($outs[1])`"],`"win`":$win,`"h`":[$($pts -join ',')]}")
                $sw.Flush(); $done[$m.slug] = 1; $nMk++
            }
            $nEv++
        }
        if ($off % 500 -eq 0) { Log "eventos $nEv, mercados nuevos $nMk" }
        if ($evs.Count -lt 100) { break }
    }
} finally { $sw.Close() }
Log "fin $League : eventos $nEv, mercados nuevos $nMk"
