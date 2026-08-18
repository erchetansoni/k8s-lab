<#
.SYNOPSIS
    Manages the lifecycle of cloud-provider-kind on Windows.

.EXAMPLE
    .\cloud-provider.ps1 start
    .\cloud-provider.ps1 stop
    .\cloud-provider.ps1 status
    .\cloud-provider.ps1 logs
#>

param(
    [ValidateSet("start", "stop", "restart", "status", "logs")]
    [string]$Action = "status"
)

$binPath = "$HOME\go\bin\cloud-provider-kind.exe"
$logPath = "$env:TEMP\cloud-provider-kind.log"

if (-not (Test-Path $binPath)) {
    # Check if in PATH
    $cmd = Get-Command "cloud-provider-kind.exe" -ErrorAction SilentlyContinue
    if ($cmd) {
        $binPath = $cmd.Source
    } else {
        Write-Error "cloud-provider-kind.exe not found! Please install via: go install sigs.k8s.io/cloud-provider-kind@latest"
        exit 1
    }
}

function Get-CPProcess {
    return Get-Process -Name "cloud-provider-kind" -ErrorAction SilentlyContinue
}

switch ($Action) {
    "start" {
        $proc = Get-CPProcess
        if ($proc) {
            Write-Host "cloud-provider-kind is already running (PID: $($proc.Id))." -ForegroundColor Yellow
        } else {
            Write-Host "Starting cloud-provider-kind in background..." -ForegroundColor Cyan
            Start-Process -FilePath $binPath `
                          -ArgumentList "--enable-default-ingress=false -v 2" `
                          -RedirectStandardOutput $logPath `
                          -RedirectStandardError "$env:TEMP\cloud-provider-kind.err.log" `
                          -WindowStyle Hidden
            Start-Sleep -Seconds 1
            $proc = Get-CPProcess
            if ($proc) {
                Write-Host "cloud-provider-kind started successfully (PID: $($proc.Id))" -ForegroundColor Green
                Write-Host "Log file: $logPath" -ForegroundColor DarkGray
            } else {
                Write-Host "Failed to start cloud-provider-kind. Check $logPath" -ForegroundColor Red
            }
        }
    }

    "stop" {
        $proc = Get-CPProcess
        if ($proc) {
            Write-Host "Stopping cloud-provider-kind (PID: $($proc.Id))..." -ForegroundColor Yellow
            Stop-Process -Name "cloud-provider-kind" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Write-Host "cloud-provider-kind stopped." -ForegroundColor Green
        } else {
            Write-Host "cloud-provider-kind is not running." -ForegroundColor Gray
        }
    }

    "restart" {
        & $MyInvocation.MyCommand.Path -Action stop
        Start-Sleep -Seconds 1
        & $MyInvocation.MyCommand.Path -Action start
    }

    "status" {
        $proc = Get-CPProcess
        if ($proc) {
            Write-Host "Status: RUNNING (PID: $($proc.Id))" -ForegroundColor Green
            Write-Host "Log file: $logPath" -ForegroundColor DarkGray
        } else {
            Write-Host "Status: STOPPED" -ForegroundColor Red
        }
    }

    "logs" {
        if (Test-Path $logPath) {
            Get-Content -Path $logPath -Tail 30 -Wait
        } else {
            Write-Host "No log file found at $logPath" -ForegroundColor Yellow
        }
    }
}
