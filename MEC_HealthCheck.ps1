# ============================================================
# MEC_HealthCheck.ps1 — Detect + Remediate Wrapper
# Version    : 2.0 (MEC Edition)
# Context    : SYSTEM via ManageEngine Endpoint Central
# Schedule   : Run every 60 minutes via MEC recurring script
#
# MEC does not have native detect-then-remediate chaining like
# Intune Proactive Remediations. This wrapper replicates that
# pattern: runs Detect.ps1 first, then conditionally runs
# Remediate.ps1 only if the device is non-compliant.
#
# Both scripts must already exist in:
#   C:\ProgramData\NWMO\Printers\
# (written there by Install.ps1 at initial deployment)
# ============================================================
$ErrorActionPreference = "SilentlyContinue"

$persistDir      = Join-Path $env:ProgramData "NWMO\Printers"
$detectScript    = Join-Path $persistDir "Detect.ps1"
$remediateScript = Join-Path $persistDir "Remediate.ps1"
$logPath         = Join-Path $persistDir "healthcheck.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line -ErrorAction SilentlyContinue
}

Write-Log "=== MEC Health Check Started ==="
Write-Log "Device: $env:COMPUTERNAME"

# ---- Validate scripts are present ----
if (-not (Test-Path $detectScript)) {
    Write-Log "FATAL: Detect.ps1 not found at $detectScript — Install.ps1 has not run." "ERROR"
    Write-Log "Action required: Deploy Stage-Files.ps1 then Install.ps1 to this device." "ERROR"
    exit 1
}

# ---- Run Detection ----
Write-Log "Running detection..."
& $detectScript
$detectExitCode = $LASTEXITCODE
Write-Log "Detection exit code: $detectExitCode"

if ($detectExitCode -eq 0) {
    Write-Log "=== COMPLIANT — No remediation needed. ==="
    exit 0
}

# ---- Device is non-compliant — run remediation ----
Write-Log "NON-COMPLIANT detected. Initiating remediation..." "WARN"

if (-not (Test-Path $remediateScript)) {
    Write-Log "FATAL: Remediate.ps1 not found at $remediateScript" "ERROR"
    exit 1
}

& $remediateScript
$remediateExitCode = $LASTEXITCODE
Write-Log "Remediation exit code: $remediateExitCode"

if ($remediateExitCode -eq 0) {
    Write-Log "=== REMEDIATION COMPLETE — Device should now be compliant. ==="
    Write-Log "Next health check will confirm compliance."
    exit 0
} else {
    Write-Log "=== REMEDIATION FAILED — Manual investigation required. ===" "ERROR"
    Write-Log "Check: $logPath and C:\ProgramData\NWMO\Printers\install.log" "ERROR"
    exit 1
}