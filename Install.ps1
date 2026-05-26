#Requires -RunAsAdministrator
# ============================================================
# XEROX C8070 UNIFIED MASTER DEPLOYMENT SCRIPT
# Version    : 3.1 (MEC-Hardened - Scorched Earth Edition)
# Context    : SYSTEM via ManageEngine Endpoint Central
# Idempotent : YES - safe to re-run at any cadence
# ============================================================
$ErrorActionPreference = "Stop"

# ============================================================
# PATH CONSTANTS & LOGGING SETUP
# ============================================================

# FIX #1: Reliable source path resolution for MEC SYSTEM context.
# $PSScriptRoot is empty when MEC launches scripts via cmd wrapper.
# $MyInvocation.MyCommand.Path is the only reliable source in all contexts.
if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
    $sourceDir = $PSScriptRoot
} elseif (-not [string]::IsNullOrEmpty($MyInvocation.MyCommand.Path)) {
    $sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $sourceDir = (Get-Location).Path
}

$persistDir  = Join-Path $env:ProgramData "NWMO\Printers"
$deployDir   = Join-Path $env:ProgramData "NWMO\Printers\Deploy"
$configPath  = Join-Path $deployDir "printers.json"
$datPath     = Join-Path $deployDir "SecurePrint.dat"
$binPath     = Join-Path $deployDir "SecurePrintDevMode.bin"
$infFolder   = Join-Path $deployDir "AltaLink_C8030-C8070_5.639.3.0_PCL6_x64_Driver"
$infPath     = Join-Path $infFolder "x3ASKYX.inf"
$logPath     = Join-Path $persistDir "install.log"

if (-not (Test-Path $persistDir)) { New-Item -ItemType Directory -Path $persistDir -Force | Out-Null }

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","OK","STEP")][string]$Level = "INFO"
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line -ErrorAction SilentlyContinue
}

Write-Log "==========================================================" STEP
Write-Log "Xerox C8070 Unified MEC Deployment v3.1 - START"          STEP
Write-Log "Source dir : $sourceDir"                                  INFO
Write-Log "Deploy dir : $deployDir"                                  INFO
Write-Log "Log file   : $logPath"                                    INFO
Write-Log "Running as : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" INFO
Write-Log "==========================================================" STEP

# ============================================================
# PHASE 00: STAGE FILES
# Copies files from MEC's temporary extraction folder to ProgramData
# so they persist after MEC cleans up the temp directory.
# ============================================================
Write-Log "PHASE 00: Staging deployment files..." STEP
try {
    if (-not (Test-Path $deployDir)) {
        New-Item -ItemType Directory -Path $deployDir -Force | Out-Null
    }
    Copy-Item -Path "$sourceDir\*" -Destination $deployDir -Recurse -Force -ErrorAction Stop
    Write-Log "  Files staged: $sourceDir -> $deployDir" OK
} catch {
    Write-Log "FATAL: Failed to stage files from $sourceDir. $_" ERROR
    exit 1
}

# ============================================================
# PHASE 0: ENVIRONMENT VALIDATION
# ============================================================
Write-Log "PHASE 0: Validating environment..." STEP
try {
    $requiredFiles = @($configPath, $datPath, $binPath, $infPath)
    foreach ($f in $requiredFiles) {
        if (Test-Path $f) {
            Write-Log "  [FOUND]   $f" OK
        } else {
            Write-Log "FATAL: Required file missing after staging: $f" ERROR
            exit 1
        }
    }
    Write-Log "  All required files verified." OK
} catch {
    Write-Log "FATAL: Phase 0 validation failed. $_" ERROR
    exit 1
}

# ============================================================
# CONFIG LOADER
# ============================================================
Write-Log "Loading printers.json config..." STEP
try {
    $config      = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    $driverName  = $config.driverName
    $taskName    = $config.taskName
    $eventSource = $config.eventSource
    $printers    = $config.printers | ForEach-Object { @{ Name = $_.Name; IP = $_.IP } }
    $validPorts  = $printers | ForEach-Object { "IP_$($_.IP)" }

    Write-Log "  Driver     : $driverName" INFO
    Write-Log "  Task name  : $taskName"   INFO
    Write-Log "  Printers   : $($printers.Count)" INFO
    foreach ($p in $printers) { Write-Log "    - $($p.Name) -> $($p.IP)" INFO }

    Copy-Item -Path $configPath -Destination (Join-Path $persistDir "printers.json") -Force
    Write-Log "  Config loaded and persisted." OK
} catch {
    Write-Log "FATAL: Could not load or parse printers.json. $_" ERROR
    exit 1
}

# ============================================================
# PHASE 1: AGGRESSIVE QUEUE SANITIZATION (SCORCHED EARTH)
# ============================================================
Write-Log "PHASE 1: Aggressively sanitizing legacy and dirty queues..." STEP
try {
    # Extract just the exact names we WANT to keep eventually
    $approvedNames = $printers | Select-Object -ExpandProperty Name

    # 1. Obliterate ANY printer with "C8070" that doesn't perfectly match our final list
    # This catches _v1, _MCE, typos, and old tests on ANY port.
    Get-Printer -ErrorAction SilentlyContinue | Where-Object { 
        $_.Name -match "C8070" -and $_.Name -notin $approvedNames 
    } | ForEach-Object {
        Write-Log "  Removing unauthorized/old test queue: $($_.Name)" WARN
        Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
        
        # Native bypass kill just in case WMI fails on a ghost queue
        $killArgs = "printui.dll,PrintUIEntry /dl /n `"$($_.Name)`" /q"
        Start-Process "$env:windir\System32\rundll32.exe" -ArgumentList $killArgs -Wait -NoNewWindow
    }

    # 2. Remove the existing exact matches so Phase 5 builds them completely fresh
    foreach ($p in $printers) {
        if (Get-Printer -Name $p.Name -ErrorAction SilentlyContinue) {
            Write-Log "  Removing existing approved queue to rebuild fresh: $($p.Name)" INFO
            Remove-Printer -Name $p.Name -ErrorAction SilentlyContinue
            
            # Native bypass kill for approved queues too, ensuring no ghosts
            $killArgs = "printui.dll,PrintUIEntry /dl /n `"$($p.Name)`" /q"
            Start-Process "$env:windir\System32\rundll32.exe" -ArgumentList $killArgs -Wait -NoNewWindow
        }
    }

    # 3. Remove stale IP_ ports no longer in config
    Get-PrinterPort -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "IP_192.168.*" -and ($_.Name -notin $validPorts)
    } | ForEach-Object {
        Write-Log "  Removing stale port: $($_.Name)" WARN
        Remove-PrinterPort -Name $_.Name -ErrorAction SilentlyContinue
    }
} catch {
    Write-Log "PHASE 1 FAILED: $_" ERROR
    exit 1
}

# ============================================================
# PHASE 2: SPOOLER RESTART
# FIX #4: Verify spooler actually starts before proceeding.
# ============================================================
Write-Log "PHASE 2: Cycling Print Spooler..." STEP
try {
    Write-Log "  Stopping spooler..." INFO
    & sc.exe stop Spooler | Out-Null

    # Wait up to 30s for stopped state
    $timeout = 30
    $elapsed = 0
    while ((Get-Service Spooler).Status -ne "Stopped" -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    if ((Get-Service Spooler).Status -ne "Stopped") {
        Write-Log "  Spooler didn't stop gracefully after ${timeout}s. Forcing." WARN
        Stop-Service Spooler -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Write-Log "  Spooler stopped." OK

    Write-Log "  Starting spooler..." INFO
    & sc.exe start Spooler | Out-Null

    # FIX #4: Verify spooler actually came back up before continuing
    Start-Sleep -Seconds 5
    $spoolerStatus = (Get-Service Spooler).Status
    Write-Log "  Spooler status after start: $spoolerStatus" INFO
    if ($spoolerStatus -ne "Running") {
        Write-Log "FATAL: Spooler failed to start. Cannot continue." ERROR
        exit 1
    }
    Write-Log "  Spooler running." OK
} catch {
    Write-Log "PHASE 2 FAILED: $_" ERROR
    exit 1
}

# ============================================================
# PHASE 3: DRIVER STAGING AND INSTALLATION (WMI Bypass)
# ============================================================
Write-Log "PHASE 3: Staging Xerox PCL6 driver..." STEP
try {
    # Bypass 32-bit MEC File System Redirector to find the true 64-bit pnputil.exe
    $pnpExe = "$env:windir\System32\pnputil.exe"
    if (Test-Path "$env:windir\sysnative\pnputil.exe") { 
        $pnpExe = "$env:windir\sysnative\pnputil.exe" 
    }
    
    $pnpResult = & $pnpExe /add-driver $infPath /install 2>&1
    Write-Log "pnputil result: $pnpResult" INFO

    if (-not (Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue)) {
        Write-Log "Registering driver via native PrintUI engine..." INFO
        
        # Ensure we use 64-bit rundll32 for the driver installation
        $rundllExe = "$env:windir\System32\rundll32.exe"
        if (Test-Path "$env:windir\sysnative\rundll32.exe") { 
            $rundllExe = "$env:windir\sysnative\rundll32.exe" 
        }
        
        $printuiArgs = "printui.dll,PrintUIEntry /ia /m `"$driverName`" /h `"x64`" /f `"$infPath`""
        Start-Process $rundllExe -ArgumentList $printuiArgs -Wait -NoNewWindow
    } else {
        Write-Log "Driver already registered with Spooler. Skipping." OK
    }
    Write-Log "Driver stage complete: $driverName" OK
} catch {
    Write-Log "PHASE 3 FAILED: $_" ERROR
    exit 1
}

# ============================================================
# PHASE 4: TCP/IP PORT CREATION
# ============================================================
Write-Log "PHASE 4: Mapping TCP/IP ports..." STEP
try {
    foreach ($p in $printers) {
        $portName = "IP_$($p.IP)"
        if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
            Write-Log "  Creating port: $portName -> $($p.IP)" INFO
            Add-PrinterPort -Name $portName -PrinterHostAddress $p.IP -ErrorAction Stop
            Write-Log "  Port created: $portName" OK
        } else {
            Write-Log "  Port already exists: $portName" OK
        }
    }
} catch {
    Write-Log "PHASE 4 FAILED: $_" ERROR
    exit 1
}

# ============================================================
# PHASE 5: PRINTER QUEUE CREATION (Native PrintUI Bypass)
# ============================================================
Write-Log "PHASE 5: Building printer queues via native PrintUI engine..." STEP
try {
    # Bypass 32-bit MEC File System Redirector
    $rundllExe = "$env:windir\System32\rundll32.exe"
    if (Test-Path "$env:windir\sysnative\rundll32.exe") { 
        $rundllExe = "$env:windir\sysnative\rundll32.exe" 
    }

    foreach ($p in $printers) {
        $portName = "IP_$($p.IP)"
        $existing = Get-Printer -Name $p.Name -ErrorAction SilentlyContinue

        if (-not $existing) {
            Write-Log "Creating queue: $($p.Name) on $portName" INFO
            
            # /if = install via inf, /b = queue name, /f = inf path, /r = port, /m = driver name, /z = do not share
            $printuiArgs = "printui.dll,PrintUIEntry /if /b `"$($p.Name)`" /f `"$infPath`" /r `"$portName`" /m `"$driverName`" /z"
            Start-Process $rundllExe -ArgumentList $printuiArgs -Wait -NoNewWindow
            
            # Brief 3-second pause to let the spooler commit the new registry keys before Phase 6 checks for them
            Start-Sleep -Seconds 3 
            
        } elseif ($existing.PortName -ne $portName) {
            Write-Log "Correcting port on $($p.Name): $($existing.PortName) -> $portName" WARN
            Set-Printer -Name $p.Name -PortName $portName -ErrorAction SilentlyContinue
        } else {
            Write-Log "Queue OK: $($p.Name) on $portName" OK
        }
    }
} catch {
    Write-Log "PHASE 5 FAILED: $_" ERROR
    exit 1
}

# ============================================================
# PHASE 6: HKLM DEVMODE INJECTION
# FIX: Added retry loop - spooler writes the registry key
#      asynchronously after queue creation; without a wait
#      the key often doesn't exist yet and DevMode is silently skipped.
# ============================================================
Write-Log "PHASE 6: Injecting machine-level DevMode (HKLM)..." STEP
try {
    if (-not (Test-Path $binPath)) {
        Write-Log "  SecurePrintDevMode.bin not found. Skipping DevMode injection." WARN
    } else {
        $devModeBytes = [System.IO.File]::ReadAllBytes($binPath)
        Write-Log "  DevMode binary loaded: $($devModeBytes.Length) bytes" INFO

        foreach ($p in $printers) {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\$($p.Name)"

            # FIX: Retry up to 5 times (15s total) for spooler to commit the key
            $retries = 5
            $found   = $false
            for ($i = 1; $i -le $retries; $i++) {
                if (Test-Path $regPath) { $found = $true; break }
                Write-Log "  Waiting for registry key ($i/$retries): $($p.Name)" WARN
                Start-Sleep -Seconds 3
            }

            if ($found) {
                Set-ItemProperty -Path $regPath -Name "Default DevMode" -Value $devModeBytes -Type Binary -ErrorAction Stop
                Write-Log "  DevMode injected: $($p.Name)" OK
            } else {
                Write-Log "  Registry key not found after $retries retries for $($p.Name). DevMode skipped." WARN
            }
        }
    }
} catch {
    Write-Log "PHASE 6 FAILED: $_" ERROR
    exit 1
}

# ============================================================
# PHASE 7: PERSIST ENFORCEMENT SCRIPT + SCHEDULED TASK
# FIX #5: RunLevel changed from Highest to Limited.
#         BUILTIN\Users are standard users - Windows will silently
#         refuse to run a Highest task for non-admins, meaning
#         the per-logon .dat injection would never fire.
# ============================================================
Write-Log "PHASE 7: Persisting enforcement files and registering scheduled task..." STEP
try {
    if (Test-Path $datPath) {
        Copy-Item -Path $datPath -Destination "$persistDir\SecurePrint.dat" -Force
        Write-Log "  SecurePrint.dat persisted to: $persistDir" OK
    } else {
        Write-Log "  SecurePrint.dat not found at: $datPath" WARN
    }

    $enforceScriptPath = Join-Path $persistDir "Enforce-SecurePrint.ps1"

    # This script runs as the logged-on standard user.
    # printui.dll/PrintUIEntry does not require elevation - Limited is correct.
    $enforceScriptContent = @'
$persistDir = "C:\ProgramData\NWMO\Printers"
$configPath = Join-Path $persistDir "printers.json"
$datFile    = Join-Path $persistDir "SecurePrint.dat"

if (-not (Test-Path $configPath)) { exit 1 }
if (-not (Test-Path $datFile))    { exit 1 }

$config = Get-Content $configPath -Raw | ConvertFrom-Json
foreach ($p in $config.printers) {
    $pName = $p.Name
    if (Get-Printer -Name $pName -ErrorAction SilentlyContinue) {
        $arg = "printui.dll,PrintUIEntry /Sr /n " + [char]34 + $pName + [char]34 + " /a " + [char]34 + $datFile + [char]34 + " r"
        Start-Process rundll32.exe -ArgumentList $arg -Wait -WindowStyle Hidden
    }
}
'@
    Set-Content -Path $enforceScriptPath -Value $enforceScriptContent -Encoding UTF8 -Force
    Write-Log "  Enforce-SecurePrint.ps1 written to: $enforceScriptPath" OK

    # Remove existing task if present (idempotent re-run)
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "  Existing scheduled task removed for re-registration: $taskName" WARN
    }

    $taskArgs  = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$enforceScriptPath`""
    $action    = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn

    # FIX #5: Limited (not Highest) - standard users cannot elevate for scheduled tasks.
    $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Log "  Scheduled task registered: $taskName (RunLevel: Limited)" OK
} catch {
    Write-Log "PHASE 7 FAILED: $_" ERROR
    exit 1
}

# ============================================================
# PHASE 8: WSD AUTO-DISCOVERY SUPPRESSION
# ============================================================
Write-Log "PHASE 8: Suppressing WSD printer auto-discovery..." STEP
try {
    $printPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers"
    if (-not (Test-Path $printPolicyPath)) { New-Item -Path $printPolicyPath -Force | Out-Null }
    Set-ItemProperty -Path $printPolicyPath -Name "DisableHTTPPrinting"   -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $printPolicyPath -Name "DisableWebPnPDownload"  -Value 1 -Type DWord -Force

    $deviceInstallPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings"
    if (-not (Test-Path $deviceInstallPath)) { New-Item -Path $deviceInstallPath -Force | Out-Null }
    Set-ItemProperty -Path $deviceInstallPath -Name "DisableWindowsUpdateAccess" -Value 1 -Type DWord -Force

    Write-Log "  WSD suppression applied." OK
} catch {
    Write-Log "  Phase 8 WARNING: WSD suppression failed (non-fatal). $_" WARN
}

# ============================================================
# PHASE 9: PRINT SPOOLER SECURITY HARDENING
# ============================================================
Write-Log "PHASE 9: Applying spooler security hardening..." STEP
try {
    $spoolerPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers"
    if (-not (Test-Path $spoolerPolicyPath)) { New-Item -Path $spoolerPolicyPath -Force | Out-Null }
    Set-ItemProperty -Path $spoolerPolicyPath -Name "RegisterSpoolerRemoteRpcEndPoint" -Value 2 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Print" -Name "RpcAuthnLevelPrivacyEnabled" -Value 1 -Type DWord -Force

    $pnpPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
    if (-not (Test-Path $pnpPath)) { New-Item -Path $pnpPath -Force | Out-Null }
    Set-ItemProperty -Path $pnpPath -Name "Restricted"                    -Value 1 -Type DWord  -Force
    Set-ItemProperty -Path $pnpPath -Name "TrustedServers"                -Value 1 -Type DWord  -Force
    Set-ItemProperty -Path $pnpPath -Name "ServerList"                    -Value "" -Type String -Force
    Set-ItemProperty -Path $pnpPath -Name "InForest"                      -Value 0 -Type DWord  -Force
    Set-ItemProperty -Path $pnpPath -Name "NoWarningNoElevationOnInstall" -Value 0 -Type DWord  -Force
    Set-ItemProperty -Path $pnpPath -Name "UpdatePromptSettings"          -Value 0 -Type DWord  -Force

    Write-Log "  Spooler security hardening applied." OK
} catch {
    Write-Log "  Phase 9 WARNING: Security hardening partially failed (non-fatal). $_" WARN
}

# ============================================================
# PHASE 10: WINDOWS EVENT LOG EMISSION
# ============================================================
Write-Log "PHASE 10: Writing Windows Event Log entry..." STEP
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
        New-EventLog -LogName Application -Source $eventSource -ErrorAction SilentlyContinue
    }
    $msg = "XeroxC8070|DEPLOY_COMPLETE|Device=$env:COMPUTERNAME|Printers=$($printers.Count)|Script=v3.1"
    Write-EventLog -LogName Application -Source $eventSource -EventId 1001 -EntryType Information -Message $msg
    Write-Log "  Event log entry written (Source: $eventSource, EventID: 1001)." OK
} catch {
    Write-Log "  Phase 10 WARNING: Event log write failed (non-fatal). $_" WARN
}

# ============================================================
# FINAL SUMMARY
# ============================================================
Write-Log "==========================================================" STEP
Write-Log "DEPLOYMENT SUMMARY" STEP
$allOk = $true
foreach ($p in $printers) {
    $q = Get-Printer -Name $p.Name -ErrorAction SilentlyContinue
    if ($q) {
        Write-Log "  [OK]      $($p.Name)" OK
        Write-Log "            Port: $($q.PortName) | Driver: $($q.DriverName)" INFO
    } else {
        Write-Log "  [MISSING] $($p.Name)" ERROR
        $allOk = $false
    }
}
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Log "  [OK]      Scheduled task: $taskName ($($task.State))" OK
} else {
    Write-Log "  [MISSING] Scheduled task not found: $taskName" ERROR
    $allOk = $false
}
if ($allOk) {
    Write-Log "All components confirmed. Deployment successful." OK
} else {
    Write-Log "One or more components missing. Review log above." WARN
}
Write-Log "Log saved to: $logPath" INFO
Write-Log "==========================================================" STEP
Write-Log "Xerox C8070 Unified MEC Deployment v3.1 - COMPLETE"        STEP
Write-Log "==========================================================" STEP

exit 0