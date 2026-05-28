#Requires -RunAsAdministrator
# ============================================================
# SILENT V1/V4 PRINTER REMEDIATION SCRIPT
# Context: SYSTEM via ManageEngine Endpoint Central
# Impact : Zero user interruption. Purges V4 Appx Ghosts.
# ============================================================
$ErrorActionPreference = "SilentlyContinue"

Write-Host "Starting silent remediation of legacy V4 test printers..."

# 1. Close Settings App in the background
Stop-Process -Name SystemSettings -Force

# 2. Identify and kill the specific test queues
$testPrinters = Get-Printer | Where-Object { $_.Name -match "_v1|_MCE" }
if ($testPrinters) {
    foreach ($p in $testPrinters) {
        $pName = $p.Name
        Remove-Printer -Name $pName
        
        $killArgs = "printui.dll,PrintUIEntry /dl /n `"$pName`" /q"
        Start-Process "$env:windir\System32\rundll32.exe" -ArgumentList $killArgs -Wait -NoNewWindow
    }
}

# 3. Purge the V4 Driver from the Driver Store
# This is the exact string you found in the properties dialog
Remove-PrinterDriver -Name "Xerox AltaLink C8070 V4 PS"

# 4. PnP Exorcism: Target both "Printer" and modern "SoftwareDevice" classes
$zombies = Get-PnpDevice | Where-Object { 
    ($_.Class -eq "Printer" -or $_.Class -eq "SoftwareDevice") -and $_.FriendlyName -match "_v1|_MCE" 
}
if ($zombies) {
    foreach ($zombie in $zombies) {
        $zombie | Uninstall-PnpDevice -Confirm:$false
    }
}

# 5. Nuke Xerox V4 Print Support Apps (Appx)
# V4 drivers install hidden UWP apps that lock the UI. We must purge them.
Get-AppxPackage -AllUsers *Xerox* | Remove-AppxPackage -AllUsers
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match "Xerox" } | Remove-AppxProvisionedPackage -Online

# 6. Deep Registry Scrub with a fast Spooler cycle
Stop-Service Spooler -Force
$printEnum = "HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\PRINTENUM"
if (Test-Path $printEnum) {
    Get-ChildItem -Path $printEnum | 
        Where-Object { (Get-ItemProperty $_.PSPath -Name "FriendlyName").FriendlyName -match "_v1|_MCE" } | 
        Remove-Item -Recurse -Force
}
Start-Service Spooler

Write-Host "Silent remediation complete. V4 ghosts destroyed."
exit 0