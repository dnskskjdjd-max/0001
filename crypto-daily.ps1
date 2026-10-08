# Bot de cripto, estrategia DIARIA (simulada): mercados "Bitcoin above X on <fecha>" de Polymarket.
# Se resuelven con el cierre de la vela de 1 minuto de Binance BTCUSDT de las 12:00 (hora del Este de EE. UU.).
# Modelo: probabilidad de que BTC termine por encima de X con un paseo aleatorio lognormal (sin tendencia):
#   P = N( (ln(S/X) - s^2 t / 2) / (s raiz(t)) )   S = precio actual en Binance, s = volatilidad anual, t = anos que faltan
# Se apuesta (simulado) cuando el precio de compra en Polymarket mas la comision queda por debajo del modelo
# (ventaja >= 5 / 8 / 12 puntos -> $1 / $2 / $3), maximo una apuesta por fecha (los precios de una misma fecha se mueven juntos).
# Ademas guarda:
#   - senales: cada mercado+lado que alguna vez supero la ventaja minima (lo que se habria apostado sin el tope por fecha)
#   - fotos: modelo vs mercado de cada precio a 24/12/6/3/1 h del cierre, para medir quien acierta mas (Brier)
# Al final arma data/crypto.js para la pestana Cripto (incluye los datos del bot rapido, crypto-fast.ps1).
# Lo llama crypto-publish.ps1 cada minuto (tarea "FirePolymarket Bitcoin 1 min"), que sube solo los datos de Bitcoin.
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$DataDir = Join-Path $Root 'data'
. (Join-Path $Root 'crypto-common.ps1')
$LogFile = Join-Path $DataDir 'log.txt'
$BetsFile = Join-Path $DataDir 'crypto-daily-bets.json'
$SigFile = Join-Path $DataDir 'crypto-daily-signals.json'
$SnapFile = Join-Path $DataDir 'crypto-daily-snaps.json'
$FastBetsFile = Join-Path $DataDir 'crypto-fast-bets.json'
$FastWinFile = Join-Path $DataDir 'crypto-fast-windows.json'
$FastStateFile = Join-Path $DataDir 'crypto-fast-state.json'
$JsFile = Join-Path $DataDir 'crypto.js'
$Cfg = Get-Content (Join-Path $Root 'crypto-strategy.json') -Raw | ConvertFrom-Json
$D = $Cfg.daily
$Horizons = @(24, 12, 6, 3, 1)
function Log($m) { Write-CLog $LogFile 'cripto' $m }

$nowUtc = (Get-Date).ToUniversalTime()
$now = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$bets = [System.Collections.ArrayList]@(Read-CJsonArray $BetsFile)
$sigs = [System.Collections.ArrayList]@(Read-CJsonArray $SigFile)
$snaps = [System.Collections.ArrayList]@(Read-CJsonArray $SnapFile)
$ladder = @(); $spot = $null; $dvol = $null; $rv = $null; $sigma = $null
$newBets = 0; $newSigs = 0; $resolvedCount = 0

try {
    # 1. Precio y volatilidad
    $spot = Get-BtcSpot
    $dvol = Get-Dvol
    $rv = Get-RealizedVol 1000
    $sigma = if ($D.volSource -eq 'dvol' -and $dvol) { $dvol } elseif ($rv) { $rv } else { $dvol }
    if (-not $sigma) { throw 'sin volatilidad (Deribit y Binance fallaron)' }

    # 2. Eventos de hoy, manana y pasado (fecha del Este de EE. UU.)
    $et = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $etNow = [TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $et)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($dd in 0..3) {
        # (ojo: en PowerShell $day no puede llamarse $d: pisaria $D, la configuracion diaria)
        $day = $etNow.Date.AddDays($dd)
        $evSlug = "bitcoin-above-on-$($day.ToString('MMMM', $inv).ToLower())-$($day.Day)-$($day.Year)"
        $ev = @(Get-CJson "https://gamma-api.polymarket.com/events?slug=$evSlug" | ForEach-Object { $_ }) | Select-Object -First 1
        if (-not $ev) { continue }
        $rows = @()
        foreach ($m in @($ev.markets | ForEach-Object { $_ })) {
            if ($m.closed) { continue }
            $k = [double](("$($m.groupItemTitle)") -replace '[^\d.]', '')
            if (-not $k) { continue }
            $end = [DateTimeOffset]::Parse("$($m.endDate)").UtcDateTime
            $tauH = ($end - $nowUtc).TotalHours
            if ($tauH -le 0) { continue }
            $tauY = $tauH * 3600 / $CSecPerYear
            $sd = $sigma * [Math]::Sqrt($tauY)
            $p = Get-NormCdf (([Math]::Log($spot / $k) - $sd * $sd / 2) / $sd)
            $tok = (Get-JArr $m.clobTokenIds)
            $yesAsk = if ($m.bestAsk) { [double]$m.bestAsk } else { $null }
            $yesBid = if ($m.bestBid) { [double]$m.bestBid } else { $null }
            $noAsk = if ($null -ne $yesBid) { [Math]::Round(1 - $yesBid, 4) } else { $null }
            $noBid = if ($null -ne $yesAsk) { [Math]::Round(1 - $yesAsk, 4) } else { $null }
            $eYes = if ($yesAsk) { $p - $yesAsk - (Get-CryptoFee $yesAsk) } else { $null }
            $eNo = if ($noAsk) { (1 - $p) - $noAsk - (Get-CryptoFee $noAsk) } else { $null }
            $mid = if ($null -ne $yesAsk -and $null -ne $yesBid) { ($yesAsk + $yesBid) / 2 } else { $null }
            $rows += [pscustomobject]@{ ev = $evSlug; slug = $m.slug; k = $k; end = $m.endDate; tauH = $tauH; p = $p; yesAsk = $yesAsk; yesBid = $yesBid
                noAsk = $noAsk; noBid = $noBid; eYes = $eYes; eNo = $eNo; mid = $mid; tokYes = $tok[0]; tokNo = $tok[1] }
        }
        if (-not $rows.Count) { continue }
        $ladder += [pscustomobject]@{ ev = $evSlug; title = $ev.title; end = $rows[0].end; tauH = [Math]::Round($rows[0].tauH, 2)
            strikes = @($rows | Sort-Object k | ForEach-Object { [ordered]@{ k = $_.k; p = [Math]::Round($_.p, 4); yesAsk = $_.yesAsk; noAsk = $_.noAsk
                eYes = $(if ($null -ne $_.eYes) { [Math]::Round($_.eYes, 4) }); eNo = $(if ($null -ne $_.eNo) { [Math]::Round($_.eNo, 4) }) } }) }

        # 2a. Fotos modelo vs mercado a 24/12/6/3/1 h del cierre (solo dentro de la media hora previa a cada marca)
        foreach ($r in $rows) {
            if ($null -eq $r.mid) { continue }
            foreach ($h in $Horizons) {
                if ($r.tauH -le $h -and $r.tauH -gt $h - 0.5) {
                    if (-not ($snaps | Where-Object { $_.slug -eq $r.slug -and $_.h -eq $h })) {
                        [void]$snaps.Add([pscustomobject]@{ ev = $r.ev; slug = $r.slug; k = $r.k; h = $h; t = $now; p = [Math]::Round($r.p, 4); mid = [Math]::Round($r.mid, 4)
                            S = [Math]::Round($spot, 2); sig = [Math]::Round($sigma, 4); end = $r.end; won = $null })
                    }
                }
            }
        }

        # 2b. Senales y apuesta (solo dentro de la ventana de horas)
        $cands = @()
        foreach ($r in $rows) {
            if ($r.tauH -lt $D.minHours -or $r.tauH -gt $D.maxHours) { continue }
            foreach ($side in 'YES', 'NO') {
                $ask = if ($side -eq 'YES') { $r.yesAsk } else { $r.noAsk }
                $edge = if ($side -eq 'YES') { $r.eYes } else { $r.eNo }
                if ($null -eq $ask -or $null -eq $edge -or $ask -lt $D.minPrice -or $ask -gt $D.maxPrice) { continue }
                if ((Get-StakeForEdge $edge $D.tiers) -le 0) { continue }
                $pSide = if ($side -eq 'YES') { $r.p } else { 1 - $r.p }
                $key = "$($r.slug)|$side"
                if (-not ($sigs | Where-Object { $_.key -eq $key })) {
                    [void]$sigs.Add([pscustomobject]@{ key = $key; ev = $r.ev; slug = $r.slug; k = $r.k; side = $side; t = $now; p = [Math]::Round($pSide, 4)
                        price = $ask; fee = [Math]::Round((Get-CryptoFee $ask), 5); edge = [Math]::Round($edge, 4); tauH = [Math]::Round($r.tauH, 2)
                        S = [Math]::Round($spot, 2); sig = [Math]::Round($sigma, 4); end = $r.end; status = 'open' })
                    $newSigs++
                }
                $cands += [pscustomobject]@{ r = $r; side = $side; pSide = $pSide; edge = $edge }
            }
        }
        $placedHere = @($bets | Where-Object { $_.ev -eq $evSlug }).Count
        if ($cands.Count -and $placedHere -lt $D.maxPerEvent) {
            # Se confirma con el libro de ordenes real (precio medio para el monto) la mejor oportunidad que siga valiendo
            foreach ($c in @($cands | Sort-Object { - $_.edge })) {
                # Una sola apuesta por precio (mercado): nunca el mismo precio dos veces ni los dos lados
                if ($bets | Where-Object { $_.slug -eq $c.r.slug }) { continue }
                $tokB = if ($c.side -eq 'YES') { $c.r.tokYes } else { $c.r.tokNo }
                $books = Get-Books @($tokB)
                $asks = $books["$tokB"].asks
                $stake = Get-StakeForEdge $c.edge $D.tiers
                $fill = Get-FillPrice $asks $stake
                if ($null -eq $fill) { continue }
                $fill = [Math]::Min(0.999, $fill + [double]$D.slip)
                $edge = $c.pSide - $fill - (Get-CryptoFee $fill)
                $stake = Get-StakeForEdge $edge $D.tiers
                if ($stake -le 0 -or $fill -lt $D.minPrice -or $fill -gt $D.maxPrice) { continue }
                $fill2 = Get-FillPrice $asks $stake
                if ($null -eq $fill2) { continue }
                $fill = [Math]::Min(0.999, $fill2 + [double]$D.slip)
                $edge = $c.pSide - $fill - (Get-CryptoFee $fill)
                $shares = $stake / $fill
                $bet = [pscustomobject]@{ id = "$($c.r.slug)|$($c.side)"; ev = $evSlug; slug = $c.r.slug; k = $c.r.k; side = $c.side; token = $tokB
                    stake = $stake; price = [Math]::Round($fill, 4); fee = [Math]::Round($shares * (Get-CryptoFee $fill), 4); p = [Math]::Round($c.pSide, 4)
                    edge = [Math]::Round($edge, 4); S = [Math]::Round($spot, 2); sig = [Math]::Round($sigma, 4); tauH = [Math]::Round($c.r.tauH, 2)
                    placedAt = $now; end = $c.r.end; status = 'open'; curPrice = $null; pnl = $null; version = $Cfg.version }
                [void]$bets.Add($bet); $newBets++
                Log "Apuesta diaria: BTC $($c.side) > $($c.r.k) ($evSlug) `$$stake a $([Math]::Round($fill * 100, 1))c, modelo $([Math]::Round($c.pSide * 100, 1))%, ventaja $([Math]::Round($edge * 100, 1)) pp"
                break
            }
        }

        # 2c. Valor actual de las apuestas abiertas de esta fecha (precio de venta), modelo y BTC ahora;
        #     ademas un punto por hora en hist para ver como evoluciona cada apuesta
        foreach ($b in @($bets | Where-Object { $_.ev -eq $evSlug -and $_.status -eq 'open' })) {
            $r = $rows | Where-Object { $_.slug -eq $b.slug } | Select-Object -First 1
            if (-not $r) { continue }
            $b.curPrice = if ($b.side -eq 'YES') { $r.yesBid } else { $r.noBid }
            $pNow = if ($b.side -eq 'YES') { $r.p } else { 1 - $r.p }
            $b | Add-Member -NotePropertyName curPriceAt -NotePropertyValue $now -Force
            $b | Add-Member -NotePropertyName curP -NotePropertyValue ([Math]::Round($pNow, 4)) -Force
            $b | Add-Member -NotePropertyName curSpot -NotePropertyValue ([Math]::Round($spot, 2)) -Force
            $hist = @($b.hist | Where-Object { $_ })
            $lastT = if ($hist.Count) { [DateTimeOffset]::Parse("$($hist[$hist.Count - 1].t)").UtcDateTime } else { [datetime]::MinValue }
            if (($nowUtc - $lastT).TotalMinutes -ge 60) {
                $hist += [pscustomobject]@{ t = $now; px = $b.curPrice; p = [Math]::Round($pNow, 4); S = [Math]::Round($spot, 0) }
            }
            $b | Add-Member -NotePropertyName hist -NotePropertyValue @($hist) -Force
        }
    }

    # 3. Resultados: fechas ya cerradas con apuestas, senales o fotos pendientes
    $pendingEv = @(@($bets | Where-Object { $_.status -eq 'open' } | ForEach-Object { $_.ev }) + @($sigs | Where-Object { $_.status -eq 'open' } | ForEach-Object { $_.ev }) +
        @($snaps | Where-Object { $null -eq $_.won } | ForEach-Object { $_.ev }) | Sort-Object -Unique)
    foreach ($evSlug in $pendingEv) {
        $anyEnd = @(@($bets) + @($sigs) + @($snaps) | Where-Object { $_.ev -eq $evSlug -and $_.end } | Select-Object -First 1 | ForEach-Object { $_.end })
        if ($anyEnd.Count -and [DateTimeOffset]::Parse("$($anyEnd[0])").UtcDateTime -gt $nowUtc.AddMinutes(-2)) { continue }
        $ev = @(Get-CJson "https://gamma-api.polymarket.com/events?slug=$evSlug" | ForEach-Object { $_ }) | Select-Object -First 1
        if (-not $ev) { $ev = @(Get-CJson "https://gamma-api.polymarket.com/events?slug=$evSlug&closed=true" | ForEach-Object { $_ }) | Select-Object -First 1 }
        if (-not $ev) { continue }
        $res = @{}
        foreach ($m in @($ev.markets | ForEach-Object { $_ })) {
            if (-not $m.closed) { continue }
            $op = (Get-JArr $m.outcomePrices)
            if ([double]$op[0] -ge 0.99) { $res[$m.slug] = $true } elseif ([double]$op[0] -le 0.01) { $res[$m.slug] = $false }
        }
        foreach ($b in @($bets | Where-Object { $_.ev -eq $evSlug -and $_.status -eq 'open' -and $res.ContainsKey($_.slug) })) {
            $won = if ($b.side -eq 'YES') { $res[$b.slug] } else { -not $res[$b.slug] }
            $b.status = if ($won) { 'won' } else { 'lost' }; $b.pnl = Get-CryptoPnl $b $won; $b.curPrice = [double][int]$won
            $b | Add-Member -NotePropertyName resolvedAt -NotePropertyValue $now -Force
            $resolvedCount++
            Log "Resuelta diaria: BTC $($b.side) > $($b.k) -> $($b.status) ($([Math]::Round($b.pnl, 2)) USD)"
        }
        foreach ($s in @($sigs | Where-Object { $_.ev -eq $evSlug -and $_.status -eq 'open' -and $res.ContainsKey($_.slug) })) {
            $won = if ($s.side -eq 'YES') { $res[$s.slug] } else { -not $res[$s.slug] }
            $s.status = if ($won) { 'won' } else { 'lost' }
        }
        foreach ($s in @($snaps | Where-Object { $_.ev -eq $evSlug -and $null -eq $_.won -and $res.ContainsKey($_.slug) })) { $s.won = [int]$res[$s.slug] }
    }
} catch {
    Log "ERROR diario: $($_.Exception.Message) (linea $($_.InvocationInfo.ScriptLineNumber))"
}

# Se guardan siempre (aunque una parte haya fallado)
Write-CFileAtomic $BetsFile (ConvertTo-Json -InputObject @($bets) -Depth 5)
Write-CFileAtomic $SigFile (ConvertTo-Json -InputObject @($sigs) -Depth 5 -Compress)
Write-CFileAtomic $SnapFile (ConvertTo-Json -InputObject @($snaps) -Depth 5 -Compress)

# 4. Datos para la pestana Cripto
$fastBets = @(Read-CJsonArray $FastBetsFile)
$fastWin = @(Read-CJsonArray $FastWinFile)
$fastState = if (Test-Path $FastStateFile) { try { Get-Content $FastStateFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
$out = [ordered]@{
    generatedAt = $now; spot = $spot; dvol = $dvol; rv = $rv; sigma = $sigma; cfg = $Cfg
    ladder = @($ladder)
    daily = [ordered]@{ bets = @($bets); signals = @($sigs); snaps = @($snaps) }
    fast = [ordered]@{ bets = @($fastBets); windows = @($fastWin | Select-Object -Last 700); state = $fastState }
    fast3 = [ordered]@{ bets = @(Read-CJsonArray (Join-Path $DataDir 'crypto-fast3-bets.json')) }   # estrategia "3 tramos"
    fast4 = [ordered]@{ bets = @(Read-CJsonArray (Join-Path $DataDir 'crypto-fast4-bets.json')) }   # estrategia "al contrario"
}
Write-CFileAtomic $JsFile ("window.CRYPTO = " + (ConvertTo-Json -InputObject $out -Depth 8 -Compress) + ";")

# 5. Datos para la pestana "Bitcoin 5 min" (crypto5.html): bot de 5 min (crypto-fast.ps1 -Market 5m)
$st5File = Join-Path $DataDir 'crypto5m-state.json'
$out5 = [ordered]@{
    generatedAt = $now; spot = $spot; cfg = $Cfg
    fast = [ordered]@{ bets = @(Read-CJsonArray (Join-Path $DataDir 'crypto5m-bets.json')); windows = @(Read-CJsonArray (Join-Path $DataDir 'crypto5m-windows.json') | Select-Object -Last 1500)
        state = $(if (Test-Path $st5File) { try { Get-Content $st5File -Raw | ConvertFrom-Json } catch { $null } } else { $null }) }
    fast4 = [ordered]@{ bets = @(Read-CJsonArray (Join-Path $DataDir 'crypto5m4-bets.json')) }
}
Write-CFileAtomic (Join-Path $DataDir 'crypto5.js') ("window.CRYPTO5 = " + (ConvertTo-Json -InputObject $out5 -Depth 8 -Compress) + ";")
# Corre cada minuto (crypto-publish.ps1): la linea de estado va al registro cada 5 minutos o si hubo novedades
if ($newBets -or $newSigs -or $resolvedCount -or $nowUtc.Minute % 5 -eq 0) { Log "OK diario: BTC $([Math]::Round([double]$spot, 0)), vol $([Math]::Round([double]$sigma * 100, 1))%, $($ladder.Count) fechas, $newSigs senales nuevas, $newBets apuestas nuevas ($($bets.Count) en el historial), $resolvedCount resueltas; rapido: $($fastBets.Count) apuestas" }
