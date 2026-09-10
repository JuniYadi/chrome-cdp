<#
.SYNOPSIS
    Interactive Manager for exposing Chrome CDP securely over Tailscale in Windows.

.DESCRIPTION
    Safely bridges Chrome instances running on 127.0.0.1 to Tailscale IPv4 using
    Windows PortProxy (netsh) and Windows Defender Firewall rules restricted to the Tailscale subnet.
    Ensures Public IP remains completely closed to Chrome CDP.

.NOTES
    Must be run as Administrator (Elevated PowerShell).
#>

# Requires Administrator
function Test-IsAdmin {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Host "[!] Script ini butuh Administrator privileges untuk mengatur netsh & firewall." -ForegroundColor Red
        Write-Host "    Silakan buka PowerShell dengan 'Run as Administrator'." -ForegroundColor Yellow
        Pause
        exit 1
    }
}

# Ambil IP Tailscale IPv4
function Get-TailscaleIPv4 {
    $ip = $null
    # 1. Coba dari Adapter Tailscale
    $adapter = Get-NetIPAddress -InterfaceAlias "*Tailscale*" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($adapter) {
        $ip = $adapter.IPAddress
    }

    # 2. Fallback ke tailscale CLI
    if (-not $ip) {
        try {
            $cliOut = & tailscale ip -4 2>$null
            if ($LASTEXITCODE -eq 0 -and $cliOut) {
                $ip = $cliOut.Trim()
            }
        } catch {}
    }

    return $ip
}

# Ambil Public IP (untuk audit verifikasi)
function Get-PublicIPv4 {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 3 -ErrorAction SilentlyContinue
        return $resp.Trim()
    } catch {
        return $null
    }
}

# Parse active portproxy rules
function Get-ActivePortProxies {
    $output = netsh interface portproxy show v4tov4
    $rules = @()
    $parsing = $false

    foreach ($line in $output) {
        if ($line -match "^\s*Address\s+Port\s+Address\s+Port") {
            $parsing = $true
            continue
        }
        if ($parsing -and $line -match "^-+") {
            continue
        }
        if ($parsing -and $line.Trim() -ne "") {
            $parts = $line.Trim() -split "\s+"
            if ($parts.Count -ge 4) {
                $rules += [PSCustomObject]@{
                    ListenAddress  = $parts[0]
                    ListenPort     = [int]$parts[1]
                    ConnectAddress = $parts[2]
                    ConnectPort    = [int]$parts[3]
                }
            }
        }
    }
    return $rules
}

# 1. List Port & Audit Keamanan
function Show-PortList {
    param([string]$tsIP)

    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "        DAFTAR PORT PROXY & STATUS KEAMANAN" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "Tailscale IP : $(if ($tsIP) { $tsIP } else { 'TIDAK TERDETEKSI' })" -ForegroundColor Yellow
    Write-Host ""

    $rules = Get-ActivePortProxies

    if ($rules.Count -eq 0) {
        Write-Host "Belum ada PortProxy yang terdaftar." -ForegroundColor Gray
    } else {
        $report = @()
        foreach ($r in $rules) {
            $localListen = Get-NetTCPConnection -LocalPort $r.ConnectPort -State Listen -ErrorAction SilentlyContinue
            $chromeStatus = "Not Running"
            $safety = "OK (Isolated)"

            if ($localListen) {
                $boundAddrs = ($localListen | Select-Object -ExpandProperty LocalAddress) -join ", "
                if ($boundAddrs -contains "0.0.0.0") {
                    $chromeStatus = "Running"
                    $safety = "DANGER! (0.0.0.0)"
                } elseif ($boundAddrs -contains "127.0.0.1") {
                    $chromeStatus = "Running (127.0.0.1)"
                    $safety = "SECURE (Tailscale Only)"
                } else {
                    $chromeStatus = "Running ($boundAddrs)"
                    $safety = "CUSTOM"
                }
            }

            # Cek apakah ListenAddress sesuai dengan IP Tailscale
            $targetMatch = if ($r.ListenAddress -eq $tsIP) { "MATCH ($tsIP)" } else { "MISMATCH ($($r.ListenAddress))" }

            $report += [PSCustomObject]@{
                "Port"           = $r.ListenPort
                "Listen IP"      = $r.ListenAddress
                "Target Forward" = "$($r.ConnectAddress):$($r.ConnectPort)"
                "Chrome Status"  = $chromeStatus
                "Security Check" = $safety
            }
        }

        $report | Format-Table -AutoSize
    }

    Write-Host ""
    Write-Host "Tekan sembarang tombol untuk kembali ke menu utama..." -ForegroundColor Gray
    [void][System.Console]::ReadKey($true)
}

# 2. Add Port to Tailscale
function Add-PortProxyRule {
    param([string]$tsIP)

    if (-not $tsIP) {
        Write-Host "[!] Tailscale IP tidak terdeteksi. Pastikan Tailscale sudah login dan aktif." -ForegroundColor Red
        Pause
        return
    }

    Write-Host ""
    $portInput = Read-Host "Masukkan Port CDP yang ingin dibuka ke Tailscale (contoh: 9222)"
    $port = 0
    if (-not [int]::TryParse($portInput, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Write-Host "[!] Port tidak valid. Harus angka antara 1 - 65535." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host "`n[*] Menambahkan PortProxy netsh ($tsIP : $port -> 127.0.0.1 : $port)..." -ForegroundColor Cyan
    # Tambah portproxy
    netsh interface portproxy add v4tov4 listenaddress=$tsIP listenport=$port connectaddress=127.0.0.1 connectport=$port

    Write-Host "[*] Mengonfigurasi Windows Firewall (Inbound Allow dari Tailscale Subnet 100.64.0.0/10)..." -ForegroundColor Cyan
    $ruleName = "Tailscale-CDP-$port"
    
    # Hapus rule lama jika ada
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    # Buat rule baru spesifik ke Tailscale IP / Subnet
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Description "Allow CDP access via Tailscale only for port $port" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $port `
        -RemoteAddress "100.64.0.0/10" `
        -Action Allow `
        -Profile Any | Out-Null

    Write-Host "`n[+] BERHASIL: Port $port telah di-expose ke Tailscale IP ($tsIP)." -ForegroundColor Green
    Write-Host "    Akses dari device lain di Tailscale: http://${tsIP}:${port}" -ForegroundColor Yellow
    Write-Host "    Public IP tetap AMAN & TERTUTUP." -ForegroundColor Green
    Write-Host ""
    Pause
}

# 3. Remove Port from Tailscale
function Remove-PortProxyRule {
    param([string]$tsIP)

    $rules = Get-ActivePortProxies
    if ($rules.Count -eq 0) {
        Write-Host "[i] Tidak ada port proxy yang terdaftar." -ForegroundColor Yellow
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

    Write-Host "`n[*] Menghapus PortProxy netsh..." -ForegroundColor Cyan
    if ($tsIP) {
        netsh interface portproxy delete v4tov4 listenaddress=$tsIP listenport=$port
    }
    # Coba hapus juga wildcard/0.0.0.0 jika sempat salah setting
    netsh interface portproxy delete v4tov4 listenaddress=* listenport=$port 2>$null
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port 2>$null

    Write-Host "[*] Menghapus Windows Firewall Rule..." -ForegroundColor Cyan
    Remove-NetFirewallRule -DisplayName "Tailscale-CDP-$port" -ErrorAction SilentlyContinue

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
        Write-Host "   User-Agent: $($resp.'User-Agent')" -ForegroundColor Gray
    } catch {
        Write-Host " [FAILED / NOT RUNNING]" -ForegroundColor Red
        Write-Host "   Peringatan: Chrome belum dijalankan di port $port (Jalankan: node start-chrome.js default $port)" -ForegroundColor Yellow
    }

    Write-Host "`n2. Testing Tailscale PortProxy (http://${tsIP}:${port})..." -NoNewline
    if ($tsIP) {
        try {
            $respTs = Invoke-RestMethod -Uri "http://${tsIP}:${port}/json/version" -TimeoutSec 2 -ErrorAction Stop
            Write-Host " [ACCESSIBLE]" -ForegroundColor Green
            Write-Host "   Berhasil diakses via Tailscale IP!" -ForegroundColor Green
        } catch {
            Write-Host " [UNREACHABLE]" -ForegroundColor Red
            Write-Host "   Cek apakah PortProxy & Chrome sudah aktif untuk port $port." -ForegroundColor Yellow
        }
    } else {
        Write-Host " [SKIPPED - Tailscale IP not found]" -ForegroundColor Yellow
    }

    Write-Host "`n3. Testing Public IP Leakage (Pastikan TIDAK BISA diakses dari Public IP)..."
    $publicIP = Get-PublicIPv4
    if ($publicIP) {
        Write-Host "   Public IP terdeteksi: $publicIP" -ForegroundColor Gray
        Write-Host "   Mengecek listener socket..." -NoNewline
        $leak = Get-NetTCPConnection -LocalPort $port -LocalAddress $publicIP -State Listen -ErrorAction SilentlyContinue
        $wildcard = Get-NetTCPConnection -LocalPort $port -LocalAddress "0.0.0.0" -State Listen -ErrorAction SilentlyContinue
        
        if ($leak -or $wildcard) {
            Write-Host " [CRITICAL WARNING]" -ForegroundColor Red
            Write-Host "   BAHAYA: Port $port terbuka ke 0.0.0.0 atau Public IP!" -ForegroundColor Red
        } else {
            Write-Host " [SECURE]" -ForegroundColor Green
            Write-Host "   Port $port TIDAK listen di Public IP / 0.0.0.0." -ForegroundColor Green
        }
    } else {
        Write-Host "   Tidak dapat mendeteksi Public IP (offline / rate limit)." -ForegroundColor Yellow
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
Ensure-Admin

while ($true) {
    $tsIP = Get-TailscaleIPv4

    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "       CHROME CDP TAILSCALE MANAGER (WINDOWS)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "Status Tailscale IP : $(if ($tsIP) { "$tsIP" } else { "TIDAK AKTIF / BELUM LOGIN" })" -ForegroundColor $(if ($tsIP) { "Green" } else { "Red" })
    Write-Host "Keamanan            : Isolasi Localhost + Tailscale Subnet" -ForegroundColor Gray
    Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " 1. List Port & Status Keamanan" -ForegroundColor White
    Write-Host " 2. Add Port to Tailscale (PortProxy + Firewall)" -ForegroundColor White
    Write-Host " 3. Remove Port from Tailscale" -ForegroundColor White
    Write-Host " 4. Diagnostik & Test Endpoint (/json/version)" -ForegroundColor White
    Write-Host " 5. Jalankan Chrome Instance (Helper)" -ForegroundColor White
    Write-Host " 6. Keluar" -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Cyan

    $choice = Read-Host "Pilih opsi [1-6]"

    switch ($choice) {
        "1" { Show-PortList -tsIP $tsIP }
        "2" { Add-PortProxyRule -tsIP $tsIP }
        "3" { Remove-PortProxyRule -tsIP $tsIP }
        "4" { Test-SecurityAudit -tsIP $tsIP }
        "5" { Start-ChromeHelper }
        "6" { 
            Write-Host "`nSampai jumpa!" -ForegroundColor Cyan
            exit 0 
        }
        Default {
            Write-Host "[!] Pilihan tidak valid." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
