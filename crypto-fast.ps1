# Bot de cripto, estrategia RAPIDA (simulada): mercados "Bitcoin Up or Down" de 15 minutos de Polymarket.
# Se resuelven "Up" si el precio de Chainlink BTC/USD (flujo "TWAP 60s": promedio de 60 s) al final de la ventana es
# >= al del inicio. (La primera ventana observada confirmo que NO es el promedio de toda la ventana.)
# Corre sin parar (tarea de Windows "FirePolymarket Cripto rapido"); cada ~2 s:
#   1. Trae de Binance las velas de 1 segundo de la ventana actual y del minuto previo (precio de inicio, ultimo precio S)
#   2. Tres modelos (se usa el de crypto-strategy.json; los tres se guardan para compararlos):
#      'end60': promedio del ultimo minuto vs promedio del minuto previo al inicio: P(Up) = N(ln(S/base) / (s raiz(r - 40)))
#      'end'  : precio final vs precio de inicio S0: P(Up) = N(ln(S/S0) / (s raiz(r)))
#      'twap' : promedio de toda la ventana vs S0 (descartado, se guarda solo como referencia)
#      r = segundos que faltan, s = volatilidad por segundo (realizada de las ultimas 2 h en Binance)
#   3. En los ultimos 10 minutos lee el libro de ordenes de Up y Down; si el modelo supera al precio de compra
#      (con 1 c de deslizamiento y la comision) en 5 / 8 / 12 puntos, apuesta $1 / $2 / $3. Maximo una apuesta por ventana.
#      Solo despues de la fase de observacion: la regla del modelo debe coincidir con la resolucion real de Polymarket
#      en >= 90% de al menos 25 ventanas (minRuleMatch / minObserved en crypto-strategy.json).
#   4. Estrategia paralela "3 tramos" (fast3 en crypto-strategy.json, historial data/crypto-fast3-bets.json): mismo modelo,
#      pero mira la ventaja una sola vez en cada momento fijo (faltando 10, 6 y 3 min) y apuesta en cada uno si la hay.
#   5. Estrategia paralela "al contrario" (fast4, data/crypto-fast4-bets.json): identica a la original, salvo cuando esta
#      apuesta a un lado al que el modelo da < 30%: ahi compra el lado opuesto por el mismo monto.
# Guarda cada ventana (para saber que modelo describe mejor la resolucion real y medir modelo vs mercado) y las apuestas.
# Los datos los sube run-local.ps1 (cada 5 min) y los muestra la pestana Cripto (crypto.html).
param([int]$RunMinutes = 0)   # 0 = sin fin; para probar: -RunMinutes 3
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$DataDir = Join-Path $Root 'data'
. (Join-Path $Root 'crypto-common.ps1')
$LogFile = Join-Path $DataDir 'log.txt'
$BetsFile = Join-Path $DataDir 'crypto-fast-bets.json'
$WinFile = Join-Path $DataDir 'crypto-fast-windows.json'
$StateFile = Join-Path $DataDir 'crypto-fast-state.json'
$CfgFile = Join-Path $Root 'crypto-strategy.json'
$T = 900
$Checkpoints = @(600, 360, 300, 180, 120, 60, 30)
$Bets3File = Join-Path $DataDir 'crypto-fast3-bets.json'   # estrategia "3 tramos"
$Bets4File = Join-Path $DataDir 'crypto-fast4-bets.json'   # estrategia "al contrario"
function Log($m) { Write-CLog $LogFile 'cripto-rapido' $m }

# Una sola copia a la vez (la tarea intenta arrancarlo cada 5 minutos por si se cerro)
$mutex = New-Object System.Threading.Mutex($false, 'FirePolymarketCryptoFast')
if (-not $mutex.WaitOne(0)) { exit 0 }

$bets = [System.Collections.ArrayList]@(Read-CJsonArray $BetsFile)
$wins = [System.Collections.ArrayList]@(Read-CJsonArray $WinFile)
$bets3 = [System.Collections.ArrayList]@(Read-CJsonArray $Bets3File)
$bets4 = [System.Collections.ArrayList]@(Read-CJsonArray $Bets4File)
$startedAt = Get-Date
$cur = $null
$volSec = $null; $volAt = [datetime]::MinValue
$cfgAt = [datetime]::MinValue; $F = $null; $F3 = $null; $F4 = $null; $cfgVersion = $null
$lastState = [datetime]::MinValue; $lastResolve = [datetime]::MinValue; $lastErrLog = [datetime]::MinValue
$loops = 0; $errors = 0; $lastErr = $null
$view = @{}
$rule = @{ n = 0; rate = $null; canBet = $false }
$synced4 = $false

function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function New-Window([long]$winStart) {
    # (ojo: en PowerShell $w y $W son la misma variable)
    $slug = "btc-updown-15m-$winStart"
    $m = @(Get-CJson "https://gamma-api.polymarket.com/markets?slug=$slug" | ForEach-Object { $_ }) | Select-Object -First 1
    $nw = @{ W = $winStart; slug = $slug; up = $null; down = $null; pre = New-Object System.Collections.Generic.List[double]
        closes = New-Object System.Collections.Generic.List[double]; lastMs = $null; S0 = $null; checks = [ordered]@{}; slotsDone = [ordered]@{} }
    if ($m) {
        $tok = (Get-JArr $m.clobTokenIds); $outs = (Get-JArr $m.outcomes)
        $iu = [array]::IndexOf($outs, 'Up'); if ($iu -lt 0) { $iu = 0 }
        $nw.up = "$($tok[$iu])"; $nw.down = "$($tok[1 - $iu])"
    }
    return $nw
}
# Agrega las velas de 1 s nuevas (incluye el minuto previo para la comprobacion 'end60')
function Update-Window($w) {
    $start = if ($w.lastMs) { $w.lastMs + 1000 } else { ($w.W - 60) * 1000 }
    $endMs = ($w.W + $T) * 1000
    while ($start -lt $endMs) {
        $k = Get-BtcKlines '1s' 1000 $start
        if (-not $k.Count) { break }
        foreach ($c in $k) {
            $ot = [long]$c[0]
            if ($ot -ge $endMs) { break }
            if ($ot -lt $w.W * 1000) { $w.pre.Add([double]$c[4]) }
            else {
                if ($w.closes.Count -eq 0) { if ($ot -le $w.W * 1000 + 3000) { $w.S0 = [double]$c[1] } }
                $w.closes.Add([double]$c[4])
            }
            $w.lastMs = $ot
        }
        if ($k.Count -lt 1000 -or -not $w.lastMs -or $w.lastMs + 1000 -le $start) { break }   # sin avance: se corta
        $start = $w.lastMs + 1000
    }
}
function Get-Model($w, [double]$sigS) {
    $n = $w.closes.Count
    if (-not $n -or -not $w.S0) { return $null }
    $sum = 0.0; foreach ($x in $w.closes) { $sum += $x }
    $A = $sum / $n; $S = $w.closes[$n - 1]; $r = [Math]::Max(0, $T - $n)
    $M = ($n * $A + $r * $S) / $T
    $sd = $S * $sigS * [Math]::Sqrt($r * ($r + 1) * (2 * $r + 1) / 6.0) / $T
    $pT = if ($sd -gt 0) { Get-NormCdf (($M - $w.S0) / $sd) } else { [double]($M -ge $w.S0) }
    $pE = if ($r -gt 0) { Get-NormCdf ([Math]::Log($S / $w.S0) / ($sigS * [Math]::Sqrt($r))) } else { [double]($S -ge $w.S0) }
    # 'end60': promedio de los ultimos 60 s de la ventana vs promedio de los 60 s previos al inicio (TWAP de 60 s de Chainlink)
    $pE60 = $null
    if ($w.pre.Count -ge 30) {
        $base = 0.0; foreach ($x in $w.pre) { $base += $x }; $base /= $w.pre.Count
        if ($r -ge 60) {
            $sd60 = $sigS * [Math]::Sqrt($r - 40)   # varianza del promedio del ultimo minuto: s^2 (r - 60 + 60/3)
            $pE60 = Get-NormCdf ([Math]::Log($S / $base) / $sd60)
        } else {
            $k = [Math]::Min($n, 60 - $r); $sk = 0.0; for ($i = $n - $k; $i -lt $n; $i++) { $sk += $w.closes[$i] }
            $M60 = ($sk + $r * $S) / 60
            $sdM = $S * $sigS * [Math]::Sqrt($r * ($r + 1) * (2 * $r + 1) / 6.0) / 60
            $pE60 = if ($sdM -gt 0) { Get-NormCdf (($M60 - $base) / $sdM) } else { [double]($M60 -ge $base) }
        }
    }
    return @{ n = $n; A = $A; S = $S; r = $r; pTwap = $pT; pEnd = $pE; pEnd60 = $pE60 }
}
function Close-Window($w) {
    try { Update-Window $w } catch {}
    $n = $w.closes.Count
    $rec = [ordered]@{ W = $w.W; slug = $w.slug; S0 = $w.S0; n = $n; twap = $null; end = $null; end60 = $null; start60 = $null
        checks = $w.checks; bet = $null; upWon = $null; twapUp = $null; endUp = $null; end60Up = $null }
    if ($n -and $w.S0) {
        $sum = 0.0; foreach ($x in $w.closes) { $sum += $x }
        $rec.twap = [Math]::Round($sum / $n, 2); $rec.end = $w.closes[$n - 1]
        $last = @($w.closes | Select-Object -Last 60); $rec.end60 = [Math]::Round(($last | Measure-Object -Average).Average, 2)
        if ($w.pre.Count) { $rec.start60 = [Math]::Round(($w.pre | Measure-Object -Average).Average, 2) }
        $rec.twapUp = [int]($rec.twap -ge $w.S0); $rec.endUp = [int]($rec.end -ge $w.S0)
        if ($rec.start60) { $rec.end60Up = [int]($rec.end60 -ge $rec.start60) }
    }
    $b = $bets | Where-Object { $_.W -eq $w.W } | Select-Object -First 1
    if ($b) { $rec.bet = $b.side }
    [void]$wins.Add([pscustomobject]$rec)
    while ($wins.Count -gt 3000) { $wins.RemoveAt(0) }
    Write-CFileAtomic $WinFile (ConvertTo-Json -InputObject @($wins) -Depth 6 -Compress)
}
# Mejor apuesta posible ahora segun la configuracion $cfg (tiers, slip, minPrice, maxPrice): el lado (Up o Down) con mas
# ventaja = modelo - precio medio de compra (+ deslizamiento) - comision. $null si ninguno llega a la ventaja minima.
function Find-BestBet($bu, $bd, $p, $cfg) {
    $best = $null
    $maxStake = (@($cfg.tiers) | Measure-Object -Property stake -Maximum).Maximum
    foreach ($side in 'UP', 'DOWN') {
        $bk = if ($side -eq 'UP') { $bu } else { $bd }
        if (-not $bk -or -not $bk.asks.Count) { continue }
        $pS = if ($side -eq 'UP') { $p } else { 1 - $p }
        $fill = Get-FillPrice $bk.asks $maxStake
        if ($null -eq $fill) { continue }
        $fill = [Math]::Min(0.999, $fill + [double]$cfg.slip)
        $edge = $pS - $fill - (Get-CryptoFee $fill)
        $stake = Get-StakeForEdge $edge $cfg.tiers
        if ($stake -le 0 -or $fill -lt $cfg.minPrice -or $fill -gt $cfg.maxPrice) { continue }
        $f2 = Get-FillPrice $bk.asks $stake
        if ($null -eq $f2) { continue }
        $f2 = [Math]::Min(0.999, $f2 + [double]$cfg.slip)
        $e2 = $pS - $f2 - (Get-CryptoFee $f2)
        if (-not $best -or $e2 -gt $best.edge) { $best = @{ side = $side; pS = $pS; fill = $f2; edge = $e2; stake = $stake; tok = $(if ($side -eq 'UP') { $cur.up } else { $cur.down }) } }
    }
    if ($best -and $best.edge -ge (@($cfg.tiers) | Measure-Object -Property edge -Minimum).Minimum) { return $best }
    return $null
}
function New-FastBet($best, $md, $secLeft, $askUp, $askDn, $id) {
    $shares = $best.stake / $best.fill
    return [pscustomobject]@{ id = $id; W = $cur.W; slug = $cur.slug; side = $best.side; token = $best.tok
        stake = $best.stake; price = [Math]::Round($best.fill, 4); fee = [Math]::Round($shares * (Get-CryptoFee $best.fill), 4)
        p = [Math]::Round($best.pS, 4); edge = [Math]::Round($best.edge, 4); model = "$($F.model)"; secLeft = $secLeft
        S0 = $cur.S0; S = $md.S; twapSoFar = [Math]::Round($md.A, 2); pTwap = [Math]::Round($md.pTwap, 4); pEnd = [Math]::Round($md.pEnd, 4); pEnd60 = $view.pEnd60
        askUp = $askUp; askDown = $askDn; placedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); status = 'open'; pnl = $null; version = $cfgVersion }
}
# Estrategia 4 ("al contrario"): identica a la original (mismas apuestas, mismo precio y monto), salvo cuando la original
# apuesta a un lado al que el modelo da menos de maxModelP (30%): entonces compra el lado opuesto en ese mismo momento,
# por el mismo monto, al precio real del libro (+ deslizamiento + comision)
function Add-CopyBet($orig) {
    $copy = $orig.PSObject.Copy()
    $copy | Add-Member -NotePropertyName flipped -NotePropertyValue $false -Force
    [void]$bets4.Add($copy)
    Write-CFileAtomic $Bets4File (ConvertTo-Json -InputObject @($bets4) -Depth 5)
}
# Al arrancar: las apuestas de la original que no tengan su par en la estrategia 4 (p. ej. hechas antes de este cambio o
# mientras el bot estaba parado) se agregan; si eran de modelo < 30% se invierten con el precio del lado opuesto guardado
function Sync-Fast4 {
    if (-not ($F4 -and $F4.enabled)) { return }
    $added = 0
    foreach ($b in @($bets)) {
        if ($bets4 | Where-Object { $_.W -eq $b.W }) { continue }
        if ([double]$b.p -ge [double]$F4.maxModelP) { $copy = $b.PSObject.Copy(); $copy | Add-Member -NotePropertyName flipped -NotePropertyValue $false -Force; [void]$bets4.Add($copy); $added++; continue }
        $side = if ($b.side -eq 'UP') { 'DOWN' } else { 'UP' }
        $ask = if ($side -eq 'UP') { $b.askUp } else { $b.askDown }
        if (-not $ask) { continue }
        $fill = [Math]::Min(0.999, [double]$ask + [double]$F4.slip); $sh = [double]$b.stake / $fill
        $c = $b.PSObject.Copy()
        $c.id = "$($b.slug)|$side"; $c.side = $side; $c.price = [Math]::Round($fill, 4); $c.fee = [Math]::Round($sh * (Get-CryptoFee $fill), 4)
        $c.p = [Math]::Round(1 - [double]$b.p, 4); $c.edge = [Math]::Round((1 - [double]$b.p) - $fill - (Get-CryptoFee $fill), 4)
        $c.status = 'open'; $c.pnl = $null
        if ($b.status -in 'won', 'lost') { $won = $b.status -eq 'lost'; $c.status = if ($won) { 'won' } else { 'lost' }; $c.pnl = Get-CryptoPnl $c $won }
        $c | Add-Member -NotePropertyName flipped -NotePropertyValue $true -Force
        $c | Add-Member -NotePropertyName origSide -NotePropertyValue $b.side -Force
        $c | Add-Member -NotePropertyName origP -NotePropertyValue ([double]$b.p) -Force
        [void]$bets4.Add($c); $added++
    }
    if ($added) { Write-CFileAtomic $Bets4File (ConvertTo-Json -InputObject @($bets4 | Sort-Object { [long]$_.W }) -Depth 5); Log "Al contrario: $added apuestas sincronizadas con la estrategia original" }
}
function Add-ContraBet($orig, $bu, $bd, $md, $secLeft, $askUp, $askDn) {
    $side = if ($orig.side -eq 'UP') { 'DOWN' } else { 'UP' }
    $bk = if ($side -eq 'UP') { $bu } else { $bd }
    if (-not $bk -or -not $bk.asks.Count) { return }
    $stake = [double]$orig.stake
    $fill = Get-FillPrice $bk.asks $stake
    if ($null -eq $fill) { return }
    $fill = [Math]::Min(0.999, $fill + [double]$F4.slip)
    $pS = 1 - $orig.pS
    $c = @{ side = $side; pS = $pS; fill = $fill; edge = $pS - $fill - (Get-CryptoFee $fill); stake = $stake; tok = $(if ($side -eq 'UP') { $cur.up } else { $cur.down }) }
    $bet = New-FastBet $c $md $secLeft $askUp $askDn "$($cur.slug)|$side"
    $bet | Add-Member -NotePropertyName flipped -NotePropertyValue $true
    $bet | Add-Member -NotePropertyName origSide -NotePropertyValue $orig.side
    $bet | Add-Member -NotePropertyName origP -NotePropertyValue ([Math]::Round($orig.pS, 4))
    [void]$bets4.Add($bet)
    Write-CFileAtomic $Bets4File (ConvertTo-Json -InputObject @($bets4) -Depth 5)
    Log "Apuesta al contrario $($cur.slug): $side `$$stake a $([Math]::Round($fill * 100, 1))c (el modelo daba $([Math]::Round($orig.pS * 100, 1))% a $($orig.side))"
}
# Fase de observacion: solo se apuesta cuando la regla del modelo coincidio con la resolucion real de Polymarket
# en al menos minRuleMatch de minObserved ventanas (si no, el modelo estaria midiendo otra cosa)
function Get-RuleMatch {
    $field = switch ("$($F.model)") { 'end' { 'endUp' } 'end60' { 'end60Up' } default { 'twapUp' } }
    $r = @($wins | Where-Object { ($_.upWon -eq 0 -or $_.upWon -eq 1) -and $null -ne $_.$field })
    $ok = @($r | Where-Object { $_.$field -eq $_.upWon }).Count
    return @{ n = $r.Count; rate = $(if ($r.Count) { [Math]::Round($ok / $r.Count, 4) } else { $null }); field = $field
        canBet = ($r.Count -ge [int]$F.minObserved -and $r.Count -gt 0 -and $ok / $r.Count -ge [double]$F.minRuleMatch) }
}
function Resolve-Windows {
    $nowS = Get-UnixNow; $changed = $false
    # Si el bot se cerro (o lo cerraron) antes de terminar la ventana de una apuesta, esa ventana no quedo registrada y la
    # apuesta no se resolveria nunca: se reconstruye con el historial de 1 s de Binance (sin las fotos de modelo vs mercado)
    foreach ($b in @(@($bets) + @($bets3) + @($bets4) | Where-Object { $_.status -eq 'open' -and $_.W + $T -lt $nowS - 30 })) {
        if ($wins | Where-Object { $_.W -eq $b.W }) { continue }
        if ($cur -and $cur.W -eq $b.W) { continue }
        try { Close-Window (New-Window ([long]$b.W)); Log "Ventana $($b.slug) reconstruida (el bot no estaba corriendo al cerrarse)" } catch {}
    }
    foreach ($rec in @($wins | Where-Object { $null -eq $_.upWon -and $_.W + $T -lt $nowS - 60 })) {
        if ($rec.W + $T -lt $nowS - 172800) { $rec.upWon = -1; $changed = $true; continue }   # sin resolver tras 2 dias: se descarta
        try {
            $m = @(Get-CJson "https://gamma-api.polymarket.com/markets?slug=$($rec.slug)&closed=true" | ForEach-Object { $_ }) | Select-Object -First 1
            if (-not $m -or -not $m.closed) { continue }
            $op = (Get-JArr $m.outcomePrices); $outs = (Get-JArr $m.outcomes)
            $iu = [array]::IndexOf($outs, 'Up'); if ($iu -lt 0) { $iu = 0 }
            if ([double]$op[$iu] -ge 0.99) { $rec.upWon = 1 } elseif ([double]$op[$iu] -le 0.01) { $rec.upWon = 0 } else { continue }
            $changed = $true
            foreach ($b in @($bets | Where-Object { $_.W -eq $rec.W -and $_.status -eq 'open' })) {
                $won = ($b.side -eq 'UP') -eq ($rec.upWon -eq 1)
                $b.status = if ($won) { 'won' } else { 'lost' }; $b.pnl = Get-CryptoPnl $b $won
                $b | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
                Log "Resuelta rapida $($rec.slug): $($b.side) -> $($b.status) ($([Math]::Round($b.pnl, 2)) USD)"
                Write-CFileAtomic $BetsFile (ConvertTo-Json -InputObject @($bets) -Depth 5)
            }
            # Estrategias paralelas (3 tramos, al contrario): cada una con su historial
            foreach ($L in @(@{ list = $bets3; file = $Bets3File; name = '3 tramos' }, @{ list = $bets4; file = $Bets4File; name = 'al contrario' })) {
                $resX = @($L.list | Where-Object { $_.W -eq $rec.W -and $_.status -eq 'open' })
                foreach ($b in $resX) {
                    $won = ($b.side -eq 'UP') -eq ($rec.upWon -eq 1)
                    $b.status = if ($won) { 'won' } else { 'lost' }; $b.pnl = Get-CryptoPnl $b $won
                    $b | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
                }
                if ($resX.Count) {
                    Log "Resueltas $($L.name) $($rec.slug): $(($resX | ForEach-Object { "$(if ($_.tramo) { "$($_.tramo) min " })$($_.side) $($_.status)" }) -join ', ') ($([Math]::Round(($resX | Measure-Object pnl -Sum).Sum, 2)) USD)"
                    Write-CFileAtomic $L.file (ConvertTo-Json -InputObject @($L.list) -Depth 5)
                }
            }
        } catch {}
    }
    if ($changed) { Write-CFileAtomic $WinFile (ConvertTo-Json -InputObject @($wins) -Depth 6 -Compress) }
}

Log "Iniciado (pid $PID)"
try {
    while ($true) {
        $loopStart = Get-Date
        if ($RunMinutes -gt 0 -and ($loopStart - $startedAt).TotalMinutes -ge $RunMinutes) { break }
        try {
            if (($loopStart - $cfgAt).TotalMinutes -ge 5) { $c = Get-Content $CfgFile -Raw | ConvertFrom-Json; $F = $c.fast; $F3 = $c.fast3; $F4 = $c.fast4; $cfgVersion = $c.version; $cfgAt = $loopStart }
            if (-not $synced4) { Sync-Fast4; $synced4 = $true }
            if (-not $volSec -or ($loopStart - $volAt).TotalMinutes -ge 5) {
                $v = Get-RealizedVol ([int]$F.volMinutes)
                if ($v) { $volSec = $v / [Math]::Sqrt($CSecPerYear); $volAt = $loopStart }
            }
            $nowS = Get-UnixNow
            $W = $nowS - ($nowS % $T)
            if (-not $cur -or $cur.W -ne $W) {
                if ($cur) { Close-Window $cur }
                $cur = New-Window $W
            }
            Update-Window $cur
            $md = Get-Model $cur $volSec
            $secLeft = $cur.W + $T - (Get-UnixNow)
            $view = @{ W = $cur.W; secLeft = $secLeft; S0 = $cur.S0 }
            if ($md) {
                $p = switch ("$($F.model)") { 'end' { $md.pEnd } 'end60' { $md.pEnd60 } default { $md.pTwap } }
                $view.S = $md.S; $view.twap = [Math]::Round($md.A, 2); $view.pTwap = [Math]::Round($md.pTwap, 4); $view.pEnd = [Math]::Round($md.pEnd, 4)
                $view.pEnd60 = $(if ($null -ne $md.pEnd60) { [Math]::Round($md.pEnd60, 4) } else { $null })
                $maxLeft = [Math]::Max([int]$F.maxSecLeft, $(if ($F3 -and $F3.enabled) { (@($F3.slots) | Measure-Object -Maximum).Maximum } else { 0 }))
                if ($cur.up -and $secLeft -le $maxLeft -and $secLeft -gt 0) {
                    $books = Get-Books @($cur.up, $cur.down)
                    $bu = $books[$cur.up]; $bd = $books[$cur.down]
                    $askUp = if ($bu -and $bu.asks.Count) { [double]$bu.asks[0].price } else { $null }
                    $bidUp = if ($bu -and $bu.bids.Count) { [double]$bu.bids[0].price } else { $null }
                    $askDn = if ($bd -and $bd.asks.Count) { [double]$bd.asks[0].price } else { $null }
                    $view.askUp = $askUp; $view.askDown = $askDn
                    $mid = if ($null -ne $askUp -and $null -ne $bidUp) { ($askUp + $bidUp) / 2 } else { $null }
                    # Fotos a 10/5/2/1 min y 30 s del cierre: modelo vs mercado
                    foreach ($cp in $Checkpoints) {
                        if ($secLeft -le $cp -and $secLeft -gt $cp - 20 -and -not $cur.checks.Contains("$cp")) {
                            # [modelo twap, modelo end, precio medio del mercado, modelo end60]
                            $cur.checks["$cp"] = @([Math]::Round($md.pTwap, 4), [Math]::Round($md.pEnd, 4), $(if ($null -ne $mid) { [Math]::Round($mid, 4) } else { $null }),
                                $(if ($null -ne $md.pEnd60) { [Math]::Round($md.pEnd60, 4) } else { $null }))
                        }
                    }
                    # Estrategia 1 (original): una apuesta por ventana, en cualquier momento de los ultimos 10 min
                    $already = $bets | Where-Object { $_.W -eq $cur.W } | Select-Object -First 1
                    if (-not $already -and $null -ne $p -and $rule.canBet -and $secLeft -le [int]$F.maxSecLeft -and $secLeft -ge [int]$F.minSecLeft) {
                        $best = Find-BestBet $bu $bd $p $F
                        if ($best) {
                            $bet = New-FastBet $best $md $secLeft $askUp $askDn "$($cur.slug)|$($best.side)"
                            [void]$bets.Add($bet)
                            Write-CFileAtomic $BetsFile (ConvertTo-Json -InputObject @($bets) -Depth 5)
                            Log "Apuesta rapida $($cur.slug): $($best.side) `$$($best.stake) a $([Math]::Round($best.fill * 100, 1))c, modelo $([Math]::Round($best.pS * 100, 1))%, ventaja $([Math]::Round($best.edge * 100, 1)) pp, faltan $secLeft s"
                            # Estrategia 4: misma apuesta que la original, salvo que el modelo de < 30% al lado elegido (se invierte)
                            if ($F4 -and $F4.enabled) {
                                if ($best.pS -lt [double]$F4.maxModelP) { Add-ContraBet $best $bu $bd $md $secLeft $askUp $askDn }
                                else { Add-CopyBet $bet }
                            }
                        }
                    }
                    # Estrategia 2 ("3 tramos"): se mira la ventaja una vez en cada momento fijo (faltando 10, 6 y 3 min);
                    # si hay ventaja se apuesta, si no ese tramo se salta. Hasta 3 apuestas por ventana, historial aparte.
                    if ($F3 -and $F3.enabled -and $null -ne $p -and $rule.canBet) {
                        foreach ($slot in @($F3.slots)) {
                            $sl = [int]$slot
                            if ($secLeft -gt $sl -or $secLeft -le $sl - [int]$F3.slotToleranceSec -or $cur.slotsDone.Contains("$sl")) { continue }
                            $cur.slotsDone["$sl"] = $true
                            if ($bets3 | Where-Object { $_.W -eq $cur.W -and $_.tramo -eq [int]($sl / 60) }) { continue }
                            $best = Find-BestBet $bu $bd $p $F3
                            if (-not $best) { continue }
                            $bet = New-FastBet $best $md $secLeft $askUp $askDn "$($cur.slug)|$([int]($sl / 60))"
                            $bet | Add-Member -NotePropertyName tramo -NotePropertyValue ([int]($sl / 60))
                            [void]$bets3.Add($bet)
                            Write-CFileAtomic $Bets3File (ConvertTo-Json -InputObject @($bets3) -Depth 5)
                            Log "Apuesta 3 tramos ($([int]($sl / 60)) min) $($cur.slug): $($best.side) `$$($best.stake) a $([Math]::Round($best.fill * 100, 1))c, modelo $([Math]::Round($best.pS * 100, 1))%, ventaja $([Math]::Round($best.edge * 100, 1)) pp"
                        }
                    }
                }
            }
            if (($loopStart - $lastResolve).TotalSeconds -ge 60) { Resolve-Windows; $rule = Get-RuleMatch; $lastResolve = $loopStart }
            $loops++
        } catch {
            $errors++; $lastErr = "$($_.Exception.Message) (linea $($_.InvocationInfo.ScriptLineNumber))"
            if (($loopStart - $lastErrLog).TotalMinutes -ge 10) { Log "ERROR: $lastErr"; $lastErrLog = $loopStart }
            Start-Sleep -Seconds 3
        }
        if (((Get-Date) - $lastState).TotalSeconds -ge 15) {
            $st = [ordered]@{ pid = $PID; startedAt = $startedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); lastLoop = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                loops = $loops; errors = $errors; lastErr = $lastErr; volAnnual = $(if ($volSec) { [Math]::Round($volSec * [Math]::Sqrt($CSecPerYear), 4) }); rule = $rule; now = $view }
            try { Write-CFileAtomic $StateFile (ConvertTo-Json -InputObject $st -Depth 4 -Compress) } catch {}
            $lastState = Get-Date
        }
        $wait = [double]$F.pollSec - ((Get-Date) - $loopStart).TotalSeconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
    }
} finally {
    Log "Detenido (pid $PID, $loops ciclos, $errors errores)"
    $mutex.ReleaseMutex()
}
