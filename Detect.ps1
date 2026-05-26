# ============================================================
# XEROX C8070 DETECTION SCRIPT — Detect.ps1
# Version    : 2.0 (MEC Edition)
# Context    : SYSTEM via ManageEngine Endpoint Central
# Output     : exit 0 = COMPLIANT | exit 1 = NON-COMPLIANT
#
# Reads config from C:\ProgramData\NWMO\Printers\printers.json
# Written there by Install.ps1 — no dependency on source package.
# ============================================================

$persistDir = Join-Path $env:ProgramData "NWMO\Printers"
$configPath = Join-Path $persistDir "printers.json"

# ---- PRE-CHECK: Config must exist (Install.ps1 ran successfully) ----
if (-not (Test-Path $configPath)) {
    Write-Host "NON_COMPLIANT|CONFIG_MISSING|Install.ps1 has not run on this device."
    exit 1
}

try {
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "NON_COMPLIANT|CONFIG_MALFORMED|$_"
    exit 1
}

$driverName = $config.driverName
$taskName   = $config.taskName
$printers   = $config.printers | ForEach-Object { @{ Name = $_.Name; IP = $_.IP } }
$validPorts = $printers | ForEach-Object { "IP_$($_.IP)" }

# ---- CHECK 1: Xerox PCL6 driver registered with Spooler ----
if (-not (Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue)) {
    Write-Host "NON_COMPLIANT|DRIVER_MISSING|$driverName"
    exit 1
}

# ---- CHECK 2: All queues exist on correct Direct IP ports ----
foreach ($p in $printers) {
    $expectedPort = "IP_$($p.IP)"
    $queue = Get-Printer -Name $p.Name -ErrorAction SilentlyContinue

    if (-not $queue) {
        Write-Host "NON_COMPLIANT|QUEUE_MISSING|$($p.Name)"
        exit 1
    }

    if ($queue.PortName -ne $expectedPort) {
        Write-Host "NON_COMPLIANT|WRONG_PORT|$($p.Name)|expected=$expectedPort|actual=$($queue.PortName)"
        exit 1
    }
}

# ---- CHECK 3: Enforcement scheduled task exists ----
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    Write-Host "NON_COMPLIANT|TASK_MISSING|$taskName"
    exit 1
}

# ---- CHECK 4: No dirty queues present ----
$dirty = Get-Printer -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like "*C8070*" -and ($_.PortName -notin $validPorts)
}
if ($dirty) {
    $dirtyNames = ($dirty | ForEach-Object { $_.Name }) -join ","
    Write-Host "NON_COMPLIANT|DIRTY_QUEUES|$dirtyNames"
    exit 1
}

# ---- CHECK 5: Persistent enforcement files exist ----
$enforceScript = Join-Path $persistDir "Enforce-SecurePrint.ps1"
$datFile       = Join-Path $persistDir "SecurePrint.dat"

if (-not (Test-Path $enforceScript)) {
    Write-Host "NON_COMPLIANT|ENFORCE_SCRIPT_MISSING|$enforceScript"
    exit 1
}
if (-not (Test-Path $datFile)) {
    Write-Host "NON_COMPLIANT|DAT_MISSING|$datFile"
    exit 1
}

Write-Host "COMPLIANT|ALL_CHECKS_PASSED|Device=$env:COMPUTERNAME|$(Get-Date -Format 'yyyy-MM-dd HH:mm')"
exit 0