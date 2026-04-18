# setup_battery_limiter.ps1
# Deploys battery-limiter artifacts to a Linux device via SSH.

param(
    [string]$SshHost = "",
    [string]$SshUser = "",
    [string]$SshKey = "",
    [string]$ServiceName = "battery-limiter.service",
    [string]$RemoteScriptPath = "/usr/local/bin/battery-limiter.sh",
    [string]$RemoteServicePath = "/etc/systemd/system/battery-limiter.service",
    [string]$RemoteJournaldPath = "/etc/systemd/journald.conf.d/battery-limiter.conf",
    [string]$RemoteEnvPath = "/etc/default/battery-limiter",
    [string]$CapacityPath = "",
    [string]$TempPath = "",
    [string]$CurrentMaxPath = ""
)

$ToolDir = $PSScriptRoot
$effectiveCapLow = 40
$effectiveCapHigh = 80

if ([string]::IsNullOrWhiteSpace($SshHost)) {
    $SshHost = $env:BATTERY_LIMITER_SSH_HOST
}
if ([string]::IsNullOrWhiteSpace($SshUser)) {
    $SshUser = $env:BATTERY_LIMITER_SSH_USER
}
if ([string]::IsNullOrWhiteSpace($SshKey)) {
    $SshKey = $env:BATTERY_LIMITER_SSH_KEY
}

if ([string]::IsNullOrWhiteSpace($SshHost) -or [string]::IsNullOrWhiteSpace($SshUser) -or [string]::IsNullOrWhiteSpace($SshKey)) {
    Write-Host "Specify -SshHost, -SshUser and -SshKey, or set BATTERY_LIMITER_SSH_HOST / BATTERY_LIMITER_SSH_USER / BATTERY_LIMITER_SSH_KEY." -ForegroundColor Yellow
    exit 1
}

$sshArgs = @("-i", $SshKey, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10")
$target  = "${SshUser}@${SshHost}"
$detectBatteryGaugeBasePathCmd = @(
    'for candidate in /sys/class/power_supply/*; do'
    'if [ -e "$candidate/capacity" ] && [ -e "$candidate/temp" ] && [ -e "$candidate/status" ] && [ -e "$candidate/current_now" ]; then'
    'printf "%s" "$candidate";'
    'break;'
    'fi;'
    'done'
) -join ' '
$detectCurrentMaxPathCmd = @(
    'for candidate in /sys/class/power_supply/*/current_max; do'
    'if [ -e "$candidate" ]; then'
    'printf "%s" "$candidate";'
    'break;'
    'fi;'
    'done'
) -join ' '

function Invoke-SshCommand($cmd) {
    $out = & ssh @sshArgs $target $cmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  SSH command failed: $cmd" -ForegroundColor Red
        Write-Host "  $out" -ForegroundColor Red
        return $false
    }
    if ($out) { Write-Host "  $out" }
    return $true
}

Write-Host "=== Battery Limiter Installer ===" -ForegroundColor Cyan
Write-Host "Target: $target"
Write-Host ""

# --- Step 1: Upload files via tar (handles line endings correctly) ---
Write-Host "[1/4] Uploading files ..." -ForegroundColor Cyan

# Upload battery-limiter.sh
$shContent = Get-Content "$ToolDir\battery-limiter.sh" -Raw -Encoding UTF8
# Ensure LF line endings (not CRLF), strip BOM if present
$shContent = $shContent -replace "`r`n", "`n"
$shContent = $shContent -replace "^\xEF\xBB\xBF", ""
$shBytes = [System.Text.Encoding]::UTF8.GetBytes($shContent)
$shB64 = [Convert]::ToBase64String($shBytes)

$svcContent = Get-Content "$ToolDir\battery-limiter.service" -Raw -Encoding UTF8
$svcContent = $svcContent -replace "`r`n", "`n"
$svcContent = $svcContent -replace "^\xEF\xBB\xBF", ""
$svcBytes = [System.Text.Encoding]::UTF8.GetBytes($svcContent)
$svcB64 = [Convert]::ToBase64String($svcBytes)

# Upload script
$uploadSh = "echo '$shB64' | base64 -d | sudo tee $RemoteScriptPath > /dev/null && sudo chmod 755 $RemoteScriptPath"
if (-not (Invoke-SshCommand $uploadSh)) { exit 1 }
Write-Host "  battery-limiter.sh -> $RemoteScriptPath" -ForegroundColor Green

# Upload service
$uploadSvc = "echo '$svcB64' | base64 -d | sudo tee $RemoteServicePath > /dev/null"
if (-not (Invoke-SshCommand $uploadSvc)) { exit 1 }
Write-Host "  battery-limiter.service -> $RemoteServicePath" -ForegroundColor Green

# Upload journald retention config (30-day persistent logs)
$jrnlContent = Get-Content "$ToolDir\journald-battery-limiter.conf" -Raw -Encoding UTF8
$jrnlContent = $jrnlContent -replace "`r`n", "`n"
$jrnlContent = $jrnlContent -replace "^\xEF\xBB\xBF", ""
$jrnlBytes = [System.Text.Encoding]::UTF8.GetBytes($jrnlContent)
$jrnlB64 = [Convert]::ToBase64String($jrnlBytes)
$uploadJrnl = "echo '$jrnlB64' | base64 -d | sudo tee $RemoteJournaldPath > /dev/null"
if (-not (Invoke-SshCommand $uploadJrnl)) { exit 1 }
Write-Host "  journald-battery-limiter.conf -> $RemoteJournaldPath" -ForegroundColor Green

# Upload optional device-specific overrides if present
$localEnvPath = Join-Path $ToolDir "battery-limiter.env"
if (Test-Path $localEnvPath) {
    $envContent = Get-Content $localEnvPath -Raw -Encoding UTF8
    $envContent = $envContent -replace "`r`n", "`n"
    $envContent = $envContent -replace "^\xEF\xBB\xBF", ""
    $envBytes = [System.Text.Encoding]::UTF8.GetBytes($envContent)
    $envB64 = [Convert]::ToBase64String($envBytes)
    $uploadEnv = "echo '$envB64' | base64 -d | sudo tee $RemoteEnvPath > /dev/null"
    if (-not (Invoke-SshCommand $uploadEnv)) { exit 1 }
    Write-Host "  battery-limiter.env -> $RemoteEnvPath" -ForegroundColor Green

    $capLowMatch = [regex]::Match($envContent, '(?m)^CAP_LOW=(\d+)\s*$')
    if ($capLowMatch.Success) {
        $effectiveCapLow = [int]$capLowMatch.Groups[1].Value
    }
    $capHighMatch = [regex]::Match($envContent, '(?m)^CAP_HIGH=(\d+)\s*$')
    if ($capHighMatch.Success) {
        $effectiveCapHigh = [int]$capHighMatch.Groups[1].Value
    }
}

# --- Step 2: Reload systemd ---
Write-Host "[2/4] Reloading systemd ..." -ForegroundColor Cyan
Invoke-SshCommand "sudo systemctl daemon-reload" | Out-Null
Invoke-SshCommand "sudo systemctl restart systemd-journald" | Out-Null

# --- Step 3: Enable and start ---
Write-Host "[3/4] Enabling and starting service ..." -ForegroundColor Cyan
Invoke-SshCommand "sudo systemctl enable $ServiceName" | Out-Null
Invoke-SshCommand "sudo systemctl restart $ServiceName" | Out-Null

# --- Step 4: Verify ---
Write-Host "[4/4] Verifying ..." -ForegroundColor Cyan
Invoke-SshCommand "systemctl is-active $ServiceName" | Out-Null
$status = & ssh @sshArgs $target "systemctl is-active $ServiceName" 2>$null
$resolvedCapacityPath = $CapacityPath
$resolvedTempPath = $TempPath
if ([string]::IsNullOrWhiteSpace($resolvedCapacityPath) -or [string]::IsNullOrWhiteSpace($resolvedTempPath)) {
    $detectedBatteryGaugeBasePath = & ssh @sshArgs $target $detectBatteryGaugeBasePathCmd 2>$null
    if (-not [string]::IsNullOrWhiteSpace($detectedBatteryGaugeBasePath)) {
        if ([string]::IsNullOrWhiteSpace($resolvedCapacityPath)) {
            $resolvedCapacityPath = "$detectedBatteryGaugeBasePath/capacity"
        }
        if ([string]::IsNullOrWhiteSpace($resolvedTempPath)) {
            $resolvedTempPath = "$detectedBatteryGaugeBasePath/temp"
        }
    }
}

$capacity = ""
if (-not [string]::IsNullOrWhiteSpace($resolvedCapacityPath)) {
    $capacity = & ssh @sshArgs $target "cat $resolvedCapacityPath" 2>$null
}

$temp = ""
if (-not [string]::IsNullOrWhiteSpace($resolvedTempPath)) {
    $temp = & ssh @sshArgs $target "cat $resolvedTempPath" 2>$null
}
$resolvedCurrentMaxPath = $CurrentMaxPath
if ([string]::IsNullOrWhiteSpace($resolvedCurrentMaxPath)) {
    $resolvedCurrentMaxPath = & ssh @sshArgs $target $detectCurrentMaxPathCmd 2>$null
}

$currentMax = ""
if (-not [string]::IsNullOrWhiteSpace($resolvedCurrentMaxPath)) {
    $currentMax = & ssh @sshArgs $target "cat $resolvedCurrentMaxPath" 2>$null
}

Write-Host ""
Write-Host "=== Status ===" -ForegroundColor Cyan
Write-Host "  Service:     $status"
Write-Host "  Battery:     ${capacity}%"
if (-not [string]::IsNullOrWhiteSpace($temp)) {
    Write-Host "  Temperature: $([math]::Round([int]$temp / 10, 1))C"
} else {
    Write-Host "  Temperature: not detected" -ForegroundColor Yellow
}
if (-not [string]::IsNullOrWhiteSpace($resolvedCapacityPath)) {
    Write-Host "  capacity path: $resolvedCapacityPath"
} else {
    Write-Host "  capacity path: not detected" -ForegroundColor Yellow
}
if (-not [string]::IsNullOrWhiteSpace($resolvedTempPath)) {
    Write-Host "  temp path: $resolvedTempPath"
} else {
    Write-Host "  temp path: not detected" -ForegroundColor Yellow
}
Write-Host "  current_max: ${currentMax} uA"
if (-not [string]::IsNullOrWhiteSpace($resolvedCurrentMaxPath)) {
    Write-Host "  current_max path: $resolvedCurrentMaxPath"
} else {
    Write-Host "  current_max path: not detected" -ForegroundColor Yellow
}
Write-Host ""

if ($status -eq "active") {
    Write-Host "Battery limiter is running. Range: $effectiveCapLow%-$effectiveCapHigh%." -ForegroundColor Green
    Write-Host "Logs: ssh $target 'journalctl -u $ServiceName -f'" -ForegroundColor DarkGray
} else {
    Write-Host "WARNING: Service is not active!" -ForegroundColor Red
    Write-Host "Check logs: ssh $target 'journalctl -u $ServiceName -e'" -ForegroundColor Yellow
}
