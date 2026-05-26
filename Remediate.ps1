# ============================================================
# XEROX C8070 REMEDIATION SCRIPT — Remediate.ps1
# Version    : 2.0 (MEC Edition)
# Context    : SYSTEM via ManageEngine Endpoint Central
#
# Scope      : Queue correction and dirty queue removal ONLY.
#              Does NOT reinstall the driver — if driver is
#              missing, exits 1 to signal full re-deployment needed.
#
# Reads config from C:\ProgramData\NWMO\Printers\printers.json
# ============================================================
$ErrorActionPreference = "SilentlyContinue"

$persistDir = Join-Path $env:ProgramData "NWMO\Printers"
$configPath = Join-Path $persistDir "printers.json"

if (-not (Test-Path $configPath)) {
    Write-Host "REMEDIATION_FAILED|CONFIG_MISSING — Re-run Stage-Files.ps1 then Install.ps1."
    exit 1
}

try {
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "REMEDIATION_FAILED|CONFIG_MALFORMED|$_"
    exit 1
}

$driverName = $config.driverName
$taskName   = $config.taskName
$printers   = $config.printers | ForEach-Object { @{ Name = $_.Name; IP = $_.IP } }
$validPorts = $printers | ForEach-Object { "IP_$($_.IP)" }

# If driver is gone, queue recreation will fail — signal for full re-deployment
if (-not (Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue)) {
    Write-Host "REMEDIATION_FAILED|DRIVER_MISSING — Full deployment required. Run Install.ps1."
    exit 1
}

# ---- STEP 1: Remove dirty queues ----
Get-Printer -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like "*C8070*" -and ($_.PortName -notin $validPorts)
} | ForEach-Object {
    Write-Host "REMEDIATE|REMOVING_DIRTY_QUEUE|$($_.Name)"
    Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
}

# ---- STEP 2: Ensure correct ports exist ----
foreach ($p in $printers) {
    $portName = "IP_$($p.IP)"
    if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
        Write-Host "REMEDIATE|CREATING_PORT|$portName"
        Add-PrinterPort -Name $portName -PrinterHostAddress $p.IP -ErrorAction SilentlyContinue
    }
}

# ---- STEP 3: Recreate missing queues / correct drifted ports ----
foreach ($p in $printers) {
    $portName = "IP_$($p.IP)"
    $queue    = Get-Printer -Name $p.Name -ErrorAction SilentlyContinue

    if (-not $queue) {
        Write-Host "REMEDIATE|RECREATING_QUEUE|$($p.Name)"
        Add-Printer -Name $p.Name -DriverName $driverName -PortName $portName -ErrorAction SilentlyContinue
    } elseif ($queue.PortName -ne $portName) {
        Write-Host "REMEDIATE|CORRECTING_PORT|$($p.Name)|was=$($queue.PortName)|now=$portName"
        Set-Printer -Name $p.Name -PortName $portName -ErrorAction SilentlyContinue
    }
}

# ---- STEP 4: Re-register scheduled task if missing ----
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    $enforceScript = Join-Path $persistDir "Enforce-SecurePrint.ps1"

    if (Test-Path $enforceScript) {
        Write-Host "REMEDIATE|REREGISTERING_TASK|$taskName"
        $action    = New-ScheduledTaskAction -Execute "PowerShell.exe" `
                        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$enforceScript`""
        $trigger   = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Force -ErrorAction SilentlyContinue | Out-Null
    } else {
        Write-Host "REMEDIATE_WARN|ENFORCE_SCRIPT_MISSING — Run Install.ps1 for full rebuild."
    }
}

Write-Host "REMEDIATION_COMPLETE|Device=$env:COMPUTERNAME|$(Get-Date -Format 'yyyy-MM-dd HH:mm')"
exit 0