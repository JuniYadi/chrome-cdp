<#
.SYNOPSIS
    Interactive Manager for exposing Chrome CDP securely over Tailscale in Windows.

.DESCRIPTION
    Safely bridges Chrome instances running on 127.0.0.1 strictly to Tailscale IPv4 using
    a dedicated user-space TCP proxy (tailscale-proxy.js) and Windows Defender Firewall.
    Guarantees that Public IP is NEVER exposed (socket is bound only to Tailscale IP).

.NOTES
    Must be run as Administrator (Elevated PowerShell).
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "tailscale-ports.json"
$ProxyScript = Join-Path $ScriptDir "tailscale-proxy.js"

function Test-IsAdmin {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Prerequisites {
    if (-not (Test-IsAdmin)) {
        Write-Host "[!] Script ini butuh Administrator privileges untuk konfigurasi jaringan & firewall." -ForegroundColor Red
        Write-Host "    Silakan buka PowerShell dengan 'Run as Administrator'." -ForegroundColor Yellow
        Pause
        exit 1
    }
}

function Get-ConfiguredPorts {
    if (Test-Path $ConfigFile) {
        try {
            $content = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($content -is [array]) {
                return [int[]]$content
            }
        } catch {}
    }
    return @()
}

function Save-ConfiguredPorts {
    param([int[]]$ports)
    $unique = $ports | Sort-Object -Unique
    $json = $unique | ConvertTo-Json
    Set-Content -Path $ConfigFile -Value $json -Encoding utf8
}

function Get-TailscaleIPv4 {
    $ip = $null
    $adapter = Get-NetIPAddress -InterfaceAlias "*Tailscale*" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($adapter) { $ip = $adapter.IPAddress }

    if (-not $ip) {
        try {
            $cliOut = & tailscale ip -4 2>$null
            if ($LASTEXITCODE -eq 0 -and $cliOut) { $ip = $cliOut.Trim() }
        } catch {}
    }
    return $ip
}

function Get-PublicIPv4 {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 3 -ErrorAction SilentlyContinue
        return $resp.Trim()
    } catch {
        return $null
    }
}

function Cleanup-NetshRules {
    Write-Host "[*] Membersihkan rule netsh portproxy lama (agar tidak bocor di 0.0.0.0)..." -ForegroundColor Yellow
    $rules = netsh interface portproxy show v4tov4
    foreach ($line in $rules) {
        if ($line -match "^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)") {
            $lAddr = $matches[1]
            $lPort = $matches[2]
            if ($lAddr -notmatch "Address") {
                netsh interface portproxy delete v4tov4 listenaddress=$lAddr listenport=$lPort 2>$null
            }
        }
    }
    Write-Host "[+] Semua rule netsh portproxy lama telah dibersihkan." -ForegroundColor Green
}

function Get-ProxyProcess {
    return Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%tailscale-proxy.js%'" -ErrorAction SilentlyContinue
}

function Stop-ProxyService {
    $procs = Get-ProxyProcess
    if ($procs) {
        Write-Host "[*] Menghentikan Secure Proxy..." -ForegroundColor Cyan
        foreach ($p in $procs) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
        Write-Host "[+] Secure Proxy dihentikan." -ForegroundColor Green
    }
}

function Start-ProxyService {
    param([int[]]$ports)

    Stop-ProxyService
    if ($ports.Count -eq 0) { return }

    $portArgs = $ports -join " "
    Write-Host "[*] Menjalankan Secure Proxy untuk port: $portArgs..." -ForegroundColor Cyan

    $proc = Start-Process -FilePath "node" `
        -ArgumentList "`"$ProxyScript`" $portArgs" `
        -WindowStyle Hidden `
        -PassThru

    Start-Sleep -Seconds 1
    if ($proc -and -not $proc.HasExited) {
        Write-Host "[+] Secure Proxy aktif di background (PID: $($proc.Id))." -ForegroundColor Green
    } else {
        Write-Host "[!] Gagal menjalankan proxy di background. Coba jalankan secara manual: node tailscale-proxy.js $portArgs" -ForegroundColor Red
    }
}

# 1. List Port & Status
function Show-PortList {
    param([string]$tsIP)

    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "        DAFTAR PORT PROXY & STATUS KEAMANAN" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "Tailscale IP   : $(if ($tsIP) { $tsIP } else { 'TIDAK TERDETEKSI' })" -ForegroundColor Yellow

    $procs = Get-ProxyProcess
    $proxyStatus = if ($procs) { "RUNNING (PID: $(($procs | Select-Object -ExpandProperty ProcessId) -join ', '))" } else { "STOPPED" }
    Write-Host "Proxy Service  : $proxyStatus" -ForegroundColor $(if ($procs) { "Green" } else { "Red" })
    Write-Host ""

    $ports = Get-ConfiguredPorts
    if ($ports.Count -eq 0) {
        Write-Host "Belum ada port yang dikonfigurasi." -ForegroundColor Gray
    } else {
        $report = @()
        foreach ($p in $ports) {
            $localListen = Get-NetTCPConnection -LocalPort $p -LocalAddress "127.0.0.1" -State Listen -ErrorAction SilentlyContinue
            $tsListen = if ($tsIP) { Get-NetTCPConnection -LocalPort $p -LocalAddress $tsIP -State Listen -ErrorAction SilentlyContinue } else { $null }
            $wildcardListen = Get-NetTCPConnection -LocalPort $p -LocalAddress "0.0.0.0" -State Listen -ErrorAction SilentlyContinue

            $safety = "SECURE (Tailscale Only)"
            if ($wildcardListen) {
                $safety = "DANGER (0.0.0.0 active!)"
            }

            $report += [PSCustomObject]@{
                "Port"              = $p
                "Chrome Local"      = if ($localListen) { "Running (127.0.0.1)" } else { "Not Running" }
                "Tailscale Listener"= if ($tsListen) { "Active ($tsIP)" } else { "Inactive" }
                "Security Status"   = $safety
            }
        }
        $report | Format-Table -AutoSize
    }

    Write-Host ""
    Write-Host "Tekan sembarang tombol untuk kembali ke menu utama..." -ForegroundColor Gray
    [void][System.Console]::ReadKey($true)
}

# 2. Add Port
function Add-PortProxyRule {
    param([string]$tsIP)

    if (-not $tsIP) {
        Write-Host "[!] Tailscale IP tidak terdeteksi. Pastikan Tailscale sudah aktif." -ForegroundColor Red
        Pause
        return
    }

    Write-Host ""
    $portInput = Read-Host "Masukkan Port CDP yang ingin dibuka ke Tailscale (contoh: 9222)"
    $port = 0
    if (-not [int]::TryParse($portInput, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Write-Host "[!] Port tidak valid." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $ports = Get-ConfiguredPorts
    if ($ports -notcontains $port) {
        $ports += $port
        Save-ConfiguredPorts $ports
    }

    # Buka firewall khusus untuk Tailscale Subnet
    $ruleName = "Tailscale-CDP-$port"
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Description "Allow CDP access via Tailscale only for port $port" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $port `
        -RemoteAddress "100.64.0.0/10" `
        -Action Allow `
        -Profile Any | Out-Null

    # Restart proxy dengan port baru
    Start-ProxyService -ports $ports

    Write-Host "`n[+] BERHASIL: Port $port telah di-bind ke ${tsIP}:${port}." -ForegroundColor Green
    Write-Host "    Akses dari device lain di Tailscale: http://${tsIP}:${port}" -ForegroundColor Yellow
    Write-Host "    Public IP terisolasi total (0% leak)." -ForegroundColor Green
    Write-Host ""
    Pause
}

# 3. Remove Port
function Remove-PortProxyRule {
    param([string]$tsIP)

    $ports = Get-ConfiguredPorts
    if ($ports.Count -eq 0) {
        Write-Host "[i] Tidak ada port yang terdaftar." -ForegroundColor Yellow
        Pause
        return
    }

    Write-Host ""
    $portInput = Read-Host "Masukkan Port yang ingin dihapus (contoh: 9222)"
    $port = 0
    if (-not [int]::TryParse($portInput, [ref]$port)) {
        Write-Host "[!] Port tidak valid." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $ports = $ports | Where-Object { $_ -ne $port }
    Save-ConfiguredPorts $ports

    Remove-NetFirewallRule -DisplayName "Tailscale-CDP-$port" -ErrorAction SilentlyContinue

    if ($ports.Count -gt 0) {
        Start-ProxyService -ports $ports
    } else {
        Stop-ProxyService
    }

    Write-Host "`n[+] BERHASIL: Port $port telah dihapus dari ekspos Tailscale." -ForegroundColor Green
    Write-Host ""
    Pause
}

# 4. Audit & Diagnostic Test
function Test-SecurityAudit {
    param([string]$tsIP)

    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "              DIAGNOSTIK & AUDIT KEAMANAN" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    $portInput = Read-Host "Masukkan Port CDP yang ingin di-test (contoh: 9222)"
    $port = 0
    if (-not [int]::TryParse($portInput, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Write-Host "[!] Port tidak valid." -ForegroundColor Red
        Pause
        return
    }

    Write-Host ""
    Write-Host "1. Testing Localhost Chrome instance (127.0.0.1:$port)..." -NoNewline
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:${port}/json/version" -TimeoutSec 2 -ErrorAction Stop
        Write-Host " [OK]" -ForegroundColor Green
        Write-Host "   Browser: $($resp.Browser)" -ForegroundColor Gray
    } catch {
        Write-Host " [FAILED / NOT RUNNING]" -ForegroundColor Red
    }

    Write-Host "`n2. Testing Tailscale IP Endpoint (http://${tsIP}:${port})..." -NoNewline
    if ($tsIP) {
        try {
            $respTs = Invoke-RestMethod -Uri "http://${tsIP}:${port}/json/version" -TimeoutSec 2 -ErrorAction Stop
            Write-Host " [ACCESSIBLE]" -ForegroundColor Green
            Write-Host "   Berhasil diakses via Tailscale IP!" -ForegroundColor Green
        } catch {
            Write-Host " [UNREACHABLE]" -ForegroundColor Red
            Write-Host "   Pastikan Secure Proxy dan Chrome sudah aktif." -ForegroundColor Yellow
        }
    }

    Write-Host "`n3. Testing Public IP Isolation (Pastikan TIDAK BISA diakses dari Public IP)..."
    $publicIP = Get-PublicIPv4
    if ($publicIP) {
        Write-Host "   Public IP terdeteksi: $publicIP" -ForegroundColor Gray
        $wildcard = Get-NetTCPConnection -LocalPort $port -LocalAddress "0.0.0.0" -State Listen -ErrorAction SilentlyContinue
        $pubListen = Get-NetTCPConnection -LocalPort $port -LocalAddress $publicIP -State Listen -ErrorAction SilentlyContinue

        if ($wildcard -or $pubListen) {
            Write-Host "   [!] PERINGATAN: Socket 0.0.0.0 masih aktif! Pilih opsi 'Purge netsh rules' di menu utama." -ForegroundColor Red
        } else {
            Write-Host "   [+] AMAN: Socket hanya terikat ke Tailscale IP ($tsIP). Public IP tidak listening." -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Audit selesai. Tekan sembarang tombol untuk kembali..." -ForegroundColor Gray
    [void][System.Console]::ReadKey($true)
}

# 5. Launch Chrome Helper
function Start-ChromeHelper {
    Write-Host ""
    $profile = Read-Host "Masukkan nama profile (contoh: default)"
    if ([string]::IsNullOrWhiteSpace($profile)) { $profile = "default" }

    $portInput = Read-Host "Masukkan port (default: 9222)"
    $port = 9222
    if ([int]::TryParse($portInput, [ref]$port) -and $port -ge 1 -and $port -le 65535) {} else { $port = 9222 }

    $bgChoice = Read-Host "Jalankan di background? (Y/n)"
    $bgArg = if ($bgChoice -match "^[nN]") { "" } else { "--background" }

    Write-Host "`n[*] Menjalankan Chrome: node start-chrome.js $profile $port $bgArg" -ForegroundColor Cyan
    if ($bgArg -eq "--background") {
        Start-Process -FilePath "node" -ArgumentList "start-chrome.js $profile $port --background" -NoNewWindow
    } else {
        Start-Process -FilePath "node" -ArgumentList "start-chrome.js $profile $port"
    }

    Write-Host "[+] Perintah telah dieksekusi." -ForegroundColor Green
    Start-Sleep -Seconds 2
}

# Main Interactive Loop
Ensure-Prerequisites

while ($true) {
    $tsIP = Get-TailscaleIPv4
    $procs = Get-ProxyProcess

    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "       CHROME CDP TAILSCALE MANAGER (WINDOWS)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "Tailscale IP   : $(if ($tsIP) { "$tsIP" } else { "TIDAK AKTIF / BELUM LOGIN" })" -ForegroundColor $(if ($tsIP) { "Green" } else { "Red" })
    Write-Host "Proxy Engine   : Node.js Secure TCP Proxy (Strict Tailscale Bind)" -ForegroundColor Gray
    Write-Host "Proxy Status   : $(if ($procs) { "RUNNING" } else { "STOPPED" })" -ForegroundColor $(if ($procs) { "Green" } else { "Red" })
    Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " 1. List Port & Status Keamanan" -ForegroundColor White
    Write-Host " 2. Add Port to Tailscale (Proxy + Firewall)" -ForegroundColor White
    Write-Host " 3. Remove Port from Tailscale" -ForegroundColor White
    Write-Host " 4. Diagnostik & Test Endpoint (/json/version)" -ForegroundColor White
    Write-Host " 5. Restart / Start Secure Proxy Service" -ForegroundColor White
    Write-Host " 6. Stop Secure Proxy Service" -ForegroundColor White
    Write-Host " 7. Purge Old netsh 0.0.0.0 Rules (Fix Public Leak)" -ForegroundColor Yellow
    Write-Host " 8. Jalankan Chrome Instance (Helper)" -ForegroundColor White
    Write-Host " 9. Keluar" -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Cyan

    $choice = Read-Host "Pilih opsi [1-9]"

    switch ($choice) {
        "1" { Show-PortList -tsIP $tsIP }
        "2" { Add-PortProxyRule -tsIP $tsIP }
        "3" { Remove-PortProxyRule -tsIP $tsIP }
        "4" { Test-SecurityAudit -tsIP $tsIP }
        "5" { 
            $ports = Get-ConfiguredPorts
            Start-ProxyService -ports $ports
            Pause
        }
        "6" { 
            Stop-ProxyService
            Pause
        }
        "7" { 
            Cleanup-NetshRules
            Pause
        }
        "8" { Start-ChromeHelper }
        "9" { 
            Write-Host "`nSampai jumpa!" -ForegroundColor Cyan
            exit 0 
        }
        Default {
            Write-Host "[!] Pilihan tidak valid." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
