# Ejecuta el tracker y el copiador en esta PC y sube los datos a GitHub.
# Lo lanza la tarea de Windows "FirePolymarket Tracker" cada 5 minutos (via run-hidden.vbs, sin ventana).
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$LogFile = Join-Path $PSScriptRoot 'local-run.log'   # registro local (no se sube; esta en .gitignore)

function L($msg) { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" -Encoding UTF8 }
# Ruta completa: la tarea de Windows puede no tener git en el PATH
$GitExe = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path $GitExe)) { $GitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source }
function Invoke-Git([string[]]$a) {
    $out = & $GitExe @a 2>&1 | ForEach-Object { "$_" }
    if ($out) { L "git $($a[0]): $($out -join ' | ')" }
    return $LASTEXITCODE
}

# Evita dos ejecuciones a la vez (si una tarda mas de 5 minutos)
$mutex = New-Object System.Threading.Mutex($false, 'FirePolymarketTrackerLocal')
if (-not $mutex.WaitOne(0)) { L 'Ya hay una ejecucion en curso; se omite esta'; exit 0 }
try {
    # Trae cambios hechos en GitHub (por ejemplo, strategy.json editado en la web)
    if ((Invoke-Git @('pull', '--rebase', '--autostash', '-q')) -ne 0) { L 'Fallo git pull; se sigue con los datos locales' }

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'tracker.ps1') | Out-Null
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'copier.ps1') | Out-Null

    & $GitExe add data 2>&1 | Out-Null
    & $GitExe diff --cached --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Git @('commit', '-q', '-m', "Datos $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC (PC)") | Out-Null
        for ($i = 1; $i -le 3; $i++) {
            if ((Invoke-Git @('push', '-q')) -eq 0) { break }
            L "Fallo git push (intento $i); se reintenta tras pull"
            Invoke-Git @('pull', '--rebase', '-q') | Out-Null
            Start-Sleep -Seconds 5
        }
    }
    L 'OK'
} finally {
    $mutex.ReleaseMutex()
    # El registro local guarda solo las ultimas 3000 lineas
    $lines = @(Get-Content $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 3000) { $lines[-3000..-1] | Set-Content $LogFile -Encoding UTF8 }
}
