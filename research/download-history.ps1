# Descarga el historial para investigar una estrategia nueva de Bitcoin (mercados de 15 y 5 min). Se puede cortar y
# volver a correr: lo ya descargado se salta. Los datos quedan en research/data (no se suben a GitHub).
#   -Part binance : precio de BTC segundo a segundo en Binance (data/btc1s/AAAA-MM-DD.csv: segundo del dia, cierre)
#   -Part m15|m5  : por cada mercado, resultado (index-AAAA-MM-DD.csv) y sus operaciones en Polymarket agrupadas en
#                   tramos de 5 s (trades-AAAA-MM-DD.jsonl): por tramo, ultimo/min/max precio y volumen de Up y de Down
#   -FromDay / -ToDay : dias hacia atras (p. ej. 60 y 1 = los ultimos 60 dias sin hoy), para repartir entre procesos
param([ValidateSet('binance', 'm15', 'm5')][string]$Part, [int]$FromDay = 60, [int]$ToDay = 1)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Out = Join-Path $PSScriptRoot 'data'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$LogFile = Join-Path $Out "download-$Part-$FromDay-$ToDay.log"
New-Item -ItemType Directory -Force $Out | Out-Null
function Log($m) { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" -Encoding UTF8 }
$Inv = [Globalization.CultureInfo]::InvariantCulture   # punto decimal siempre (la PC esta en espanol)
# Descarga en texto pidiendo la respuesta comprimida (2-4 veces mas rapido que Invoke-WebRequest), con reintentos
function Get-Text($u) {
    for ($i = 1; $i -le 6; $i++) {
        try {
            $req = [Net.HttpWebRequest]::Create($u); $req.UserAgent = 'Mozilla/5.0'; $req.Timeout = 30000
            $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
            $resp = $req.GetResponse()
            try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); return $sr.ReadToEnd() } finally { $resp.Close() }
        } catch {
            $code = try { [int]$_.Exception.InnerException.Response.StatusCode } catch { 0 }
            Start-Sleep -Seconds $(if ($code -eq 429) { 20 * $i } else { 2 * $i })
        }
    }
    throw "fallo: $u"
}
function J($u) { return (ConvertFrom-Json (Get-Text $u)) }
$todayUtc = [DateTime]::UtcNow.Date
$days = @($FromDay..$ToDay | ForEach-Object { $todayUtc.AddDays(- $_) })
Log "inicio $Part dias $FromDay..$ToDay"

if ($Part -eq 'binance') {
    $dir = Join-Path $Out 'btc1s'; New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($d in $days) {
        $f = Join-Path $dir ($d.ToString('yyyy-MM-dd') + '.csv')
        if (Test-Path $f) { continue }
        $startMs = [DateTimeOffset]::new($d).ToUnixTimeMilliseconds(); $endMs = $startMs + 86400000
        $sb = New-Object System.Text.StringBuilder
        $cur = $startMs
        while ($cur -lt $endMs) {
            # (sin "| ForEach-Object": desarmaria cada vela en numeros sueltos)
            $k = @(J "https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=1s&startTime=$cur&limit=1000")
            if ($k.Count -and $k[0] -isnot [array]) { $k = @(, $k) }
            if (-not $k.Count) { $cur += 1000000; continue }
            foreach ($c in $k) { $t = [long]$c[0]; if ($t -ge $endMs) { break }; [void]$sb.Append([int](($t - $startMs) / 1000)).Append(',').Append([Math]::Round([double]$c[4], 2).ToString($Inv)).Append("`n") }
            $last = [long]$k[$k.Count - 1][0]
            $cur = if ($last -ge $cur) { $last + 1000 } else { $cur + 1000000 }
        }
        [IO.File]::WriteAllText($f, $sb.ToString(), $Utf8)
        Log "btc1s $($d.ToString('yyyy-MM-dd')) ok"
    }
} else {
    $T = if ($Part -eq 'm15') { 900 } else { 300 }
    $prefix = if ($Part -eq 'm15') { 'btc-updown-15m-' } else { 'btc-updown-5m-' }
    $dir = Join-Path $Out $Part; New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($d in $days) {
        $tag = $d.ToString('yyyy-MM-dd')
        $idxFile = Join-Path $dir "index-$tag.csv"; $trFile = Join-Path $dir "trades-$tag.jsonl"
        if ((Test-Path $idxFile) -and (Test-Path "$trFile.done")) { continue }
        $d0 = [DateTimeOffset]::new($d).ToUnixTimeSeconds()
        # 1. Resultado de cada mercado del dia (de a 20 por consulta)
        if (-not (Test-Path $idxFile)) {
            $slots = @(); for ($w = $d0; $w -lt $d0 + 86400; $w += $T) { $slots += $w }
            $lines = New-Object System.Collections.Generic.List[string]; $lines.Add('W,cond,upWon')
            for ($i = 0; $i -lt $slots.Count; $i += 20) {
                $chunk = $slots[$i..([Math]::Min($i + 19, $slots.Count - 1))]
                $qs = ($chunk | ForEach-Object { "slug=$prefix$_" }) -join '&'
                foreach ($m in @(J "https://gamma-api.polymarket.com/markets?$qs&closed=true&limit=100" | ForEach-Object { $_ })) {
                    $op = @((ConvertFrom-Json "$($m.outcomePrices)") | ForEach-Object { $_ }); $outs = @((ConvertFrom-Json "$($m.outcomes)") | ForEach-Object { $_ })
                    $iu = [array]::IndexOf($outs, 'Up'); if ($iu -lt 0) { continue }
                    $up = if ([double]$op[$iu] -ge 0.99) { 1 } elseif ([double]$op[$iu] -le 0.01) { 0 } else { continue }
                    $lines.Add("$([long]($m.slug -replace '^.*-', '')),$($m.conditionId),$up")
                }
            }
            [IO.File]::WriteAllLines($idxFile, $lines, $Utf8)
        }
        # 2. Operaciones de cada mercado, agrupadas en tramos de 5 s desde el inicio de la ventana
        $done = @{}
        if (Test-Path $trFile) { foreach ($l in [IO.File]::ReadAllLines($trFile)) { if ($l -match '^\{"W":(\d+)') { $done[$Matches[1]] = 1 } } }
        $sw = New-Object IO.StreamWriter($trFile, $true, $Utf8)
        try {
            foreach ($row in @(Import-Csv $idxFile)) {
                if ($done.ContainsKey("$($row.W)")) { continue }
                $W = [long]$row.W
                # Respuesta en texto y solo los 4 campos necesarios con una expresion regular (ConvertFrom-Json de
                # miles de operaciones con todos sus campos es muy lento en PowerShell 5.1)
                $raw = try { Get-Text "https://data-api.polymarket.com/trades?market=$($row.cond)&limit=10000" } catch { $null }
                if ($null -eq $raw) { Log "sin operaciones: $W"; continue }
                $ms = [regex]::Matches($raw, '"size":([\d.eE-]+),"price":([\d.eE-]+),"timestamp":(\d+).*?"outcome":"(Up|Down)"')
                $recs = foreach ($mm in $ms) { , @([long]$mm.Groups[3].Value, [double]$mm.Groups[2].Value, [double]$mm.Groups[1].Value, ($mm.Groups[4].Value -eq 'Up')) }
                $bk = @{}
                foreach ($x in @($recs | Sort-Object { $_[0] })) {
                    $rel = $x[0] - $W
                    if ($rel -lt -60 -or $rel -gt $T) { continue }
                    $i = [int][Math]::Floor($rel / 5)
                    if (-not $bk.ContainsKey($i)) { $bk[$i] = @(-1, 9, -1, 0, -1, 9, -1, 0) }
                    $o = if ($x[3]) { 0 } else { 4 }
                    $p = [Math]::Round($x[1], 4); $b = $bk[$i]
                    $b[$o] = $p; if ($p -lt $b[$o + 1]) { $b[$o + 1] = $p }; if ($p -gt $b[$o + 2]) { $b[$o + 2] = $p }; $b[$o + 3] += $x[2]
                }
                $parts = foreach ($i in ($bk.Keys | Sort-Object)) { $b = $bk[$i]; "[$i,$($b[0]),$($b[1]),$($b[2]),$([Math]::Round($b[3],1)),$($b[4]),$($b[5]),$($b[6]),$([Math]::Round($b[7],1))]" }
                $sw.WriteLine("{`"W`":$W,`"up`":$($row.upWon),`"n`":$($ms.Count),`"b`":[$(@($parts) -join ',')]}")
                $sw.Flush()
            }
        } finally { $sw.Close() }
        [IO.File]::WriteAllText("$trFile.done", '', $Utf8)
        Log "$Part $tag ok"
    }
}
Log "fin $Part"
