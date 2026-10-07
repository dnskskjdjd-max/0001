# Registra (o vuelve a registrar) la tarea de Windows que publica los datos de Bitcoin cada minuto (crypto-publish.ps1).
# Ejecutalo desde la carpeta del repositorio. Para quitarla:
#   Unregister-ScheduledTask -TaskName 'FirePolymarket Bitcoin 1 min' -Confirm:$false
$TaskName = 'FirePolymarket Bitcoin 1 min'
$Script = Join-Path $PSScriptRoot 'crypto-publish.ps1'

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`"" -WorkingDirectory $PSScriptRoot
$every    = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
# Al despertar la PC (dos eventos posibles segun el equipo), 1 minuto despues
$cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$wake = foreach ($q in @("Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=107", "Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1")) {
    $t = New-CimInstance -CimClass $cls -ClientOnly
    $t.Enabled = $true; $t.Delay = 'PT1M'
    $t.Subscription = "<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">*[System[$q]]</Select></Query></QueryList>"
    $t
}
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (@($every) + @($wake)) -Settings $settings `
    -Description 'Bot de Bitcoin: estrategia diaria y publicacion de los datos de la pestana Bitcoin cada minuto' -Force | Out-Null
Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo | Select-Object TaskName, NextRunTime
