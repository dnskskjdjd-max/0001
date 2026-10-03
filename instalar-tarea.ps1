# Registra (o vuelve a registrar) la tarea de Windows que ejecuta el tracker cada 5 minutos en esta PC.
# Ejecutalo desde la carpeta donde esta clonado el repositorio. Para quitarla:
#   Unregister-ScheduledTask -TaskName 'FirePolymarket Tracker' -Confirm:$false
$TaskName = 'FirePolymarket Tracker'
$Vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'

$action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$Vbs`"" -WorkingDirectory $PSScriptRoot
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Tracker de firepolymarket.com y copiador NFL; sube los datos a GitHub' -Force | Out-Null
Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo | Select-Object TaskName, NextRunTime
