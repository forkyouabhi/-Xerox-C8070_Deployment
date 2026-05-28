#Requires -RunAsAdministrator
# ============================================================
# XEROX C8070 UNIFIED MASTER DEPLOYMENT SCRIPT
# Version    : 4.0.9 (The PnP Assassin - Final UI Ghost Fix)
# Context    : SYSTEM/Admin via ManageEngine Endpoint Central
# Impact     : Obliterates ALL C8070 ghosts across OS & User Hives
# ============================================================
$ErrorActionPreference = "Stop"

# ============================================================
# PATH CONSTANTS & LOGGING SETUP
# ============================================================
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

# ============================================================
# HELPER: Scrub one loaded user hive path
# ============================================================
function Remove-PrinterFromUserHive {
    param([string]$HivePSPath)

    $rundllExe = "$env:windir\System32\rundll32.exe"
    if (Test-Path "$env:windir\sysnative\rundll32.exe") {
        $rundllExe = "$env:windir\sysnative\rundll32.exe"
    }

    # --- Devices and PrinterPorts ---
    foreach ($subkey in @("Software\Microsoft\Windows NT\CurrentVersion\Devices",
                          "Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts")) {
        $fullPath = "$HivePSPath\$subkey"
        if (Test-Path $fullPath) {
            $props = Get-ItemProperty $fullPath -ErrorAction SilentlyContinue
            if ($props) {
                $props | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "C8070" -or $_.Name -match "_v1" } |
                    ForEach-Object {
                        Write-Log "    Removing user hive value [$subkey]: $($_.Name)" WARN
                        Remove-ItemProperty -Path $fullPath -Name $_.Name -Force -ErrorAction SilentlyContinue
                    }
            }
        }
    }

    # --- Printers\Connections ---
    $connPath = "$HivePSPath\Printers\Connections"
    if (Test-Path $connPath) {
        Get-ChildItem -Path $connPath -ErrorAction SilentlyContinue | ForEach-Object {
            $keyName = $_.PSChildName
            $keyProps = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue

            $isC8070 = ($keyName -match "C8070" -or $keyName -match "_v1") -or
                       ($keyProps.PrinterName -match "C8070" -or $keyProps.PrinterName -match "_v1") -or
                       ($keyProps.'(default)' -match "C8070")

            if ($isC8070) {
                Write-Log "    Removing user Connections key: $keyName" WARN
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue

                if ($keyName -match "^,,(.+),(.+)$") {
                    $uncName = "\\$($Matches[1])\$($Matches[2])"
                    Write-Log "    printui /dn for UNC: $uncName" WARN
                    $killArgs = "printui.dll,PrintUIEntry /dn /n `"$uncName`" /q"
                    Start-Process $rundllExe -ArgumentList $killArgs -Wait -NoNewWindow -ErrorAction SilentlyContinue
                } elseif ($keyProps.PrinterName) {
                    Write-Log "    printui /dn for: $($keyProps.PrinterName)" WARN
                    $killArgs = "printui.dll,PrintUIEntry /dn /n `"$($keyProps.PrinterName)`" /q"
                    Start-Process $rundllExe -ArgumentList $killArgs -Wait -NoNewWindow -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # --- Printers\Settings (Windows 11 UI Cache) ---
    $settingsPath = "$HivePSPath\Printers\Settings"
    if (Test-Path $settingsPath) {
        Get-ChildItem -Path $settingsPath -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSChildName -match "C8070" -or $_.PSChildName -match "_v1") {
                Write-Log "    Removing user Settings key: $($_.PSChildName)" WARN
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --- User-level printer queue subkeys ---
    $userPrinterPath = "$HivePSPath\Software\Microsoft\Windows NT\CurrentVersion\Windows"
    if (Test-Path $userPrinterPath) {
        $props = Get-ItemProperty $userPrinterPath -ErrorAction SilentlyContinue
        if ($props.Device -match "C8070" -or $props.Device -match "_v1") {
            Write-Log "    Clearing default printer Device value (matched C8070 or _v1)" WARN
            Remove-ItemProperty -Path $userPrinterPath -Name "Device" -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Log "==========================================================" STEP
Write-Log "Xerox C8070 Unified MEC Deployment v4.0.9 - START"        STEP
Write-Log "Source dir : $sourceDir"                                  INFO
Write-Log "Deploy dir : $deployDir"                                  INFO
Write-Log "Log file   : $logPath"                                    INFO
Write-Log "Running as : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" INFO
Write-Log "==========================================================" STEP

# ============================================================
# PHASE 00: STAGE FILES
# ============================================================
Write-Log "PHASE 00: Staging deployment files..." STEP
try {
    if (-not (Test-Path $sourceDir)) {
        Write-Log "FATAL: Source directory does not exist: $sourceDir" ERROR
        exit 1
    }
    $sourceFiles = Get-ChildItem -Path $sourceDir -ErrorAction SilentlyContinue
    if (-not $sourceFiles) {
        Write-Log "FATAL: Source directory is empty: $sourceDir" ERROR
        exit 1
    }
    Write-Log "  Source has $($sourceFiles.Count) items" INFO
    if (-not (Test-Path $deployDir)) { New-Item -ItemType Directory -Path $deployDir -Force | Out-Null }
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
        if (Test-Path $f) { Write-Log "  [FOUND]   $f" OK }
        else {
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
# PHASE 1: THE TOTAL ECLIPSE (BURN ALL C8070 DEVICES)
# ============================================================
Write-Log "PHASE 1: Aggressively sanitizing ALL OS-Level C8070 traces..." STEP
try {
    Stop-Process -Name SystemSettings -Force -ErrorAction SilentlyContinue

    Write-Log "  Purging V4 Print Support Appx packages..." INFO
    Get-AppxPackage -AllUsers *Xerox* -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "Xerox" } |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue

    Write-Log "  Removing V4 PS Drivers (all known names)..." INFO
    foreach ($oldDriver in @("Xerox AltaLink C8070 V4 PS", "Xerox AltaLink C8070 V4 PCL6", "Xerox AltaLink C8070 PS")) {
        Remove-PrinterDriver -Name $oldDriver -ErrorAction SilentlyContinue
    }

    # ========================================================
    # FIX: Native PnP Device Assassination (Bypass Print Spooler)
    # ========================================================
    Write-Log "  Hunting ALL PnP and SoftwareDevice ghosts..." INFO
    $pnpExe = "$env:windir\System32\pnputil.exe"
    if (Test-Path "$env:windir\sysnative\pnputil.exe") { $pnpExe = "$env:windir\sysnative\pnputil.exe" }

    $ghostDevices = Get-PnpDevice -Class PrintQueue -ErrorAction SilentlyContinue | Where-Object { 
        $_.FriendlyName -match "C8070" -or $_.FriendlyName -match "_v1" 
    }
    
    if ($ghostDevices) {
        foreach ($ghost in $ghostDevices) {
            Write-Log "  Executing PnP hardware kill for: $($ghost.FriendlyName)" WARN
            & $pnpExe /remove-device "$($ghost.InstanceId)" /device | Out-Null
        }
    } else {
        Write-Log "  No ghost PnP devices detected." OK
    }

    # Legacy Spooler Cleanup (just in case they survived the PnP purge)
    Write-Log "  Removing all C8070 print queues from legacy spooler..." INFO
    $rundllExe = "$env:windir\System32\rundll32.exe"
    if (Test-Path "$env:windir\sysnative\rundll32.exe") { $rundllExe = "$env:windir\sysnative\rundll32.exe" }

    Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "C8070" -or $_.Name -match "_v1" } | ForEach-Object {
        Write-Log "  [Get-Printer] Removing queue: $($_.Name)" WARN
        Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
        $killArgs = "printui.dll,PrintUIEntry /dl /n `"$($_.Name)`" /q"
        Start-Process $rundllExe -ArgumentList $killArgs -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }

    Write-Log "  [WMI] Sweeping for driver-unavailable queues..." INFO
    $wmiPrinters = Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "C8070" -or $_.Name -match "_v1" }
    foreach ($wp in $wmiPrinters) {
        Write-Log "  [WMI] Removing: $($wp.Name)" WARN
        Remove-CimInstance -InputObject $wp -ErrorAction SilentlyContinue
        $killArgs = "printui.dll,PrintUIEntry /dl /n `"$($wp.Name)`" /q"
        Start-Process $rundllExe -ArgumentList $killArgs -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }

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
# PHASE 2: SPOOLER RESTART & DEEP REGISTRY PURGE (INC. USER HIVES)
# ============================================================
Write-Log "PHASE 2: Cycling Print Spooler and Deep Registry Clean..." STEP
try {
    Write-Log "  Stopping spooler..." INFO
    & sc.exe stop Spooler | Out-Null
    $timeout = 30; $elapsed = 0
    while ((Get-Service Spooler).Status -ne "Stopped" -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2; $elapsed += 2
    }
    if ((Get-Service Spooler).Status -ne "Stopped") {
        Stop-Service Spooler -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Write-Log "  Spooler stopped." OK

    Write-Log "  Purging running context user UI cache (HKCU)..." INFO
    Remove-PrinterFromUserHive -HivePSPath "Registry::HKEY_CURRENT_USER"

    Write-Log "  Purging active user UI caches (HKEY_USERS - loaded hives)..." INFO
    $loadedSids = @()
    try {
        $baseKey = [Microsoft.Win32.Registry]::Users
        $loadedSids = $baseKey.GetSubKeyNames() | Where-Object { $_ -match "^S-1-5-21-" -and $_ -notmatch "_Classes" }
    } catch {
        Write-Log "  Warning: .NET Registry enumeration failed. $_" WARN
    }

    foreach ($sid in $loadedSids) {
        Write-Log "  Processing loaded hive via SID: $sid" INFO
        Remove-PrinterFromUserHive -HivePSPath "Registry::HKEY_USERS\$sid"
    }

    Write-Log "  Purging offline user hives (not currently loaded)..." INFO
    $loadedUsernames = @()
    foreach ($sidKey in $loadedSids) {
        $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sidKey" -ErrorAction SilentlyContinue).ProfileImagePath
        if ($profilePath) {
            $loadedUsernames += (Split-Path $profilePath -Leaf).ToLower()
        }
    }
    Write-Log "  Loaded hive usernames to skip: $($loadedUsernames -join ', ')" INFO

    Get-ChildItem "C:\Users" -ErrorAction SilentlyContinue | ForEach-Object {
        $profileDir  = $_.FullName
        $folderName  = $_.Name.ToLower()
        $ntuser      = Join-Path $profileDir "NTUSER.DAT"
        if (-not (Test-Path $ntuser)) { return }

        if ($folderName -in @("public","default","default user","all users")) { return }

        if ($folderName -in $loadedUsernames) {
            Write-Log "  Skipping $profileDir (username matches loaded hive - scrubbed above)" INFO
            return
        }

        $sidProps = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" -ErrorAction SilentlyContinue | Where-Object { (Split-Path $_.ProfileImagePath -Leaf) -ieq $folderName -or $_.ProfileImagePath -ieq $profileDir }
        $sid = $sidProps.PSChildName
        
        if ($sid -and ($sid -in $loadedSids)) {
            Write-Log "  Skipping $profileDir (SID $sid is loaded)" INFO
            return
        }

        $tempKey = "HKLM\NWMO_TempHive_$($_.Name)"
        Write-Log "  Loading offline hive: $ntuser -> $tempKey" INFO
        
        $oldErrPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $regResult = & reg.exe load $tempKey $ntuser 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldErrPref

        if ($exitCode -ne 0) {
            Write-Log "  Could not load hive for $($_.Name) (locked/in-use). Skipping." WARN
            return
        }

        try {
            $hivePSPath = "Registry::$tempKey"
            Remove-PrinterFromUserHive -HivePSPath $hivePSPath
        } finally {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 500
            
            $oldErrPref = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $unloadResult = & reg.exe unload $tempKey 2>&1
            $exitCode = $LASTEXITCODE
            $ErrorActionPreference = $oldErrPref

            if ($exitCode -ne 0) {
                Write-Log "  Warning: Could not unload hive $tempKey : $unloadResult" WARN
            } else {
                Write-Log "  Offline hive unloaded: $tempKey" OK
            }
        }
    }

    Write-Log "  Purging OS ghost queues from Print registry cache..." INFO
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Printers",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers"
    )
    foreach ($path in $regPaths) {
        if (Test-Path $path) {
            Get-ChildItem -Path $path -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match "C8070" -or $_.PSChildName -match "_v1" } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ========================================================
    # FIX: DAF Target Enhancement
    # ========================================================
    Write-Log "  Purging Device Association Framework (Settings App UI Cache)..." INFO
    $dafPath = "HKLM:\SOFTWARE\Microsoft\DeviceAssociationFramework\Store"
    if (Test-Path $dafPath) {
        Get-ChildItem -Path $dafPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if (($props.FriendlyName -match "C8070") -or ($props.System_ItemNameDisplay -match "C8070") -or ($props.FriendlyName -match "_v1") -or ($props.System_ItemNameDisplay -match "_v1")) {
                Write-Log "  Removing DAF Ghost Entry: $($_.PSChildName)" INFO
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Log "  Purging Device Manager PRINTENUM cache..." INFO
    $printEnum = "HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\PRINTENUM"
    if (Test-Path $printEnum) {
        Get-ChildItem -Path $printEnum -ErrorAction SilentlyContinue |
            Where-Object {
                $fn = (Get-ItemProperty $_.PSPath -Name "FriendlyName" -ErrorAction SilentlyContinue).FriendlyName
                $fn -match "C8070" -or $fn -match "_v1"
            } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "  Purging PRINTUI per-user settings cache..." INFO
    $puiPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\PackageInstallation"
    if (Test-Path $puiPath) {
        Get-ChildItem -Path $puiPath -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match "C8070" -or $_.PSChildName -match "_v1" } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "  Starting spooler and resetting Device Association Service..." INFO
    & sc.exe start Spooler | Out-Null
    
    # This forces the Settings App UI to dynamically drop the deleted devices
    Restart-Service -Name "DeviceAssociationService" -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 5
    if ((Get-Service Spooler).Status -ne "Running") {
        Write-Log "FATAL: Spooler failed to start. Cannot continue." ERROR
        exit 1
    }
    Write-Log "  Spooler running." OK
} catch {
    Write-Log "PHASE 2 FAILED: $_" ERROR
    exit 1
}

# ============================================================
# PHASE 3: DRIVER STAGING AND INSTALLATION
# ============================================================
Write-Log "PHASE 3: Staging Xerox V3 PCL6 driver..." STEP
try {
    $pnpExe = "$env:windir\System32\pnputil.exe"
    if (Test-Path "$env:windir\sysnative\pnputil.exe") { $pnpExe = "$env:windir\sysnative\pnputil.exe" }

    $pnpResult = & $pnpExe /add-driver $infPath /install 2>&1
    Write-Log "pnputil result: $pnpResult" INFO

    if (-not (Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue)) {
        Write-Log "Registering driver via native PrintUI engine..." INFO
        $rundllExe = "$env:windir\System32\rundll32.exe"
        if (Test-Path "$env:windir\sysnative\rundll32.exe") { $rundllExe = "$env:windir\sysnative\rundll32.exe" }
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
    $rundllExe = "$env:windir\System32\rundll32.exe"
    if (Test-Path "$env:windir\sysnative\rundll32.exe") { $rundllExe = "$env:windir\sysnative\rundll32.exe" }

    foreach ($p in $printers) {
        $portName = "IP_$($p.IP)"
        $existing = Get-Printer -Name $p.Name -ErrorAction SilentlyContinue

        if (-not $existing) {
            Write-Log "Creating queue: $($p.Name) on $portName" INFO
            $printuiArgs = "printui.dll,PrintUIEntry /if /b `"$($p.Name)`" /f `"$infPath`" /r `"$portName`" /m `"$driverName`" /z"
            Start-Process $rundllExe -ArgumentList $printuiArgs -Wait -NoNewWindow
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
            $retries = 5; $found = $false
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

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "  Existing scheduled task removed for re-registration: $taskName" WARN
    }

    $taskArgs  = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$enforceScriptPath`""
    $action    = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
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
    $msg = "XeroxC8070|DEPLOY_COMPLETE|Device=$env:COMPUTERNAME|Printers=$($printers.Count)|Script=v4.0.9"
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
Write-Log "Xerox C8070 Unified MEC Deployment v4.0.9 - COMPLETE"        STEP
Write-Log "==========================================================" STEP

exit 0