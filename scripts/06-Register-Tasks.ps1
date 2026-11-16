#Requires -Version 5.1
#Requires -RunAsAdministrator
# 06-Register-Tasks.ps1 - registers the nightly tasks on the SOURCE server (Task Scheduler folder \AGACE\).
param(
    [string]$ScriptDir = 'C:\AGACE-Migration\scripts',
    [string]$RunAs = 'AGACE\svc-migration',
    [datetime]$FirstNight = '2026-11-23',
    [int]$BaselineNights = 10,
    [int]$BufferNights = 2,
    [datetime]$CutoverDate = '2026-12-05'
)
$ErrorActionPreference = 'Stop'
$cred = Get-Credential -UserName $RunAs -Message 'Password for the migration service account'
if (-not [System.Diagnostics.EventLog]::SourceExists('AGACE-Migration')) { New-EventLog -LogName Application -Source 'AGACE-Migration' }
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Register-AgaceTask([string]$name, [string]$hhmm, [string]$arguments, [timespan]$limit, [datetime]$until) {
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File $arguments" -WorkingDirectory $ScriptDir
    $trigger = New-ScheduledTaskTrigger -Daily -At $FirstNight.Date.Add([timespan]::Parse($hhmm))
    $trigger.EndBoundary = $until.ToString('yyyy-MM-ddTHH:mm:ss')
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit $limit -MultipleInstances IgnoreNew -Priority 4 `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -TaskPath '\AGACE\' -Action $action -Trigger $trigger -Settings $settings `
        -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
    Write-Host "Registered \AGACE\$name daily at $hhmm until $until"
}
$baselineEnd = $FirstNight.Date.AddDays($BaselineNights + $BufferNights).AddHours(6)
Register-AgaceTask '01-Baseline' '22:00' "`"$ScriptDir\04-Run-Robocopy.ps1`" -Mode Baseline -Window 2200-0500" (New-TimeSpan -Hours 7 -Minutes 30) $baselineEnd
Register-AgaceTask '02-DailySync' '23:59' "`"$ScriptDir\04-Run-Robocopy.ps1`" -Mode Delta -Window 2359-0400 -MaxParallel 2" (New-TimeSpan -Hours 4 -Minutes 30) $CutoverDate.Date.AddHours(6)
Register-AgaceTask '03-Monitor' '21:55' "`"$ScriptDir\05-Monitor-Bandwidth.ps1`" -Window 2155-0505" (New-TimeSpan -Hours 7 -Minutes 30) $baselineEnd
Get-ScheduledTask -TaskPath '\AGACE\' | Get-ScheduledTaskInfo | Format-Table TaskName, NextRunTime, LastRunTime, LastTaskResult -AutoSize
