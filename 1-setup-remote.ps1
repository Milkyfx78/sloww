# ============================================================
#  1-setup-remote.ps1
#  RUN THIS ON THE REMOTE PC (inside your RDP session), ONCE.
#  Right-click the file -> "Run with PowerShell".
#  It will ask for admin rights by itself.
# ============================================================

# --- Make sure we are running as Administrator -------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Asking Windows for admin rights..." -ForegroundColor Yellow
    Start-Process powershell.exe "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host ""
Write-Host "=== Setting up the SSH server on this PC ===" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: install OpenSSH Server ------------------------
Write-Host "[1/4] Installing OpenSSH Server..."
$ssh = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($ssh.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $ssh.Name | Out-Null
    Write-Host "      Installed." -ForegroundColor Green
} else {
    Write-Host "      Already installed." -ForegroundColor Green
}

# --- Step 2: start it and keep it starting on boot ---------
Write-Host "[2/4] Starting the service..."
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-Host "      Running, and it will start by itself every boot." -ForegroundColor Green

# --- Step 3: firewall door for port 22 ---------------------
Write-Host "[3/4] Opening port 22 in the firewall..."
if (-not (Get-NetFirewallRule -Name 'sshd-tunnel' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'sshd-tunnel' -DisplayName 'OpenSSH Server (tunnel)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Host "      Door opened." -ForegroundColor Green
} else {
    Write-Host "      Already open." -ForegroundColor Green
}

# --- Step 4: show the details you need on your own PC ------
Write-Host "[4/4] Collecting your connection details..."
Write-Host ""
Write-Host "=== DONE. Write these down ===" -ForegroundColor Cyan

$user = $env:USERNAME
Write-Host ("  Username : {0}" -f $user)

$ips = Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
       Select-Object -ExpandProperty IPAddress
Write-Host ("  Local IP : {0}" -f ($ips -join ', '))

try {
    $pub = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 8).ip
    Write-Host ("  Public IP: {0}" -f $pub)
} catch {
    Write-Host "  Public IP: (could not check - use the same address you use for RDP)"
}

Write-Host ""
Write-Host "NOTE: if you reach this PC over the internet, make sure port 22" -ForegroundColor Yellow
Write-Host "      is forwarded on the router, the same way port 3389 is for RDP." -ForegroundColor Yellow
Write-Host ""
Read-Host "Press Enter to close"
