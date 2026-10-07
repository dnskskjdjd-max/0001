# Bot de Bitcoin: cada minuto actualiza la estrategia diaria y data/crypto.js (crypto-daily.ps1) y sube solo los datos
# de Bitcoin a GitHub, para que la pestana Bitcoin del panel se actualice cada minuto.
# Lo lanza la tarea de Windows "FirePolymarket Bitcoin 1 min" (instalar-tarea-bitcoin.ps1). El bot rapido (crypto-fast.ps1)
# corre aparte sin parar; aqui solo se publican sus datos.
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$LogFile = Join-Path $PSScriptRoot 'local-run.log'   # mismo registro local que run-local.ps1 (no se sube)

function L($msg) { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [bitcoin] $msg" -Encoding UTF8 }
$GitExe = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path $GitExe)) { $GitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source }
function Invoke-Git([string[]]$a) {
    $out = & $GitExe @a 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0 -and $out) { L "git $($a[0]): $($out -join ' | ')" }
    return $LASTEXITCODE
}

# Mismo bloqueo que run-local.ps1: los dos usan git en esta carpeta. Si la corrida de 5 minutos esta en curso, se espera
# un poco; si no termina, se omite este minuto (el siguiente lo recupera).
$mutex = New-Object System.Threading.Mutex($false, 'FirePolymarketTrackerLocal')
if (-not $mutex.WaitOne(45000)) { exit 0 }
try {
    if ((Invoke-Git @('pull', '--rebase', '--autostash', '-q')) -ne 0) { L 'Fallo git pull; se sigue con los datos locales' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'crypto-daily.ps1') | Out-Null

    & $GitExe add -- 'data/crypto*' 2>&1 | Out-Null
    & $GitExe diff --cached --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Git @('commit', '-q', '-m', "Bitcoin $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC (PC)") | Out-Null
        for ($i = 1; $i -le 2; $i++) {
            if ((Invoke-Git @('push', '-q')) -eq 0) { break }
            Invoke-Git @('pull', '--rebase', '--autostash', '-q') | Out-Null
        }
    }
} finally {
    $mutex.ReleaseMutex()
}
