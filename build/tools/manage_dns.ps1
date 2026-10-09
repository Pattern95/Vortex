param (
    [string]$Action = "menu",
    [string]$Preset = "comss",
    [string]$PrimaryDns = "",
    [string]$SecondaryDns = "",
    [string]$Lang = ""
)

# Автоопределение языка если не задан
if ([string]::IsNullOrWhiteSpace($Lang)) {
    $uiCulture = (Get-UICulture).TwoLetterISOLanguageName.ToLower()
    if ($uiCulture -eq "ru" -or $uiCulture -eq "be" -or $uiCulture -eq "uk") {
        $Lang = "ru"
    } else {
        $Lang = "en"
    }
} else {
    $Lang = $Lang.ToLower()
}
$isRu = ($Lang -eq "ru")

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupFile = Join-Path $ScriptDir "dns_backup.json"
$LogFile = Join-Path $ScriptDir "dns_history.log"

# Профили DNS
$DNS_PROFILES = @{
    "comss" = @{
        NameRu = "Comss.one (Разблокировка Gemini, ChatGPT, Spotify, Xbox)"
        NameEn = "Comss.one (Unblock Gemini, ChatGPT, Spotify, Xbox)"
        DNS1   = "92.223.109.31"
        DNS2   = "92.38.151.107"
    }
    "cloudflare" = @{
        NameRu = "Cloudflare (1.1.1.1 и 1.0.0.1 - быстрый глобальный)"
        NameEn = "Cloudflare (1.1.1.1 & 1.0.0.1 - Fast Global)"
        DNS1   = "1.1.1.1"
        DNS2   = "1.0.0.1"
    }
    "google" = @{
        NameRu = "Google Public DNS (8.8.8.8 и 8.8.4.4)"
        NameEn = "Google Public DNS (8.8.8.8 & 8.8.4.4)"
        DNS1   = "8.8.8.8"
        DNS2   = "8.8.4.4"
    }
    "adguard" = @{
        NameRu = "AdGuard DNS (94.140.14.14 - Блокировка рекламы)"
        NameEn = "AdGuard DNS (94.140.14.14 - Ad & Tracker Blocking)"
        DNS1   = "94.140.14.14"
        DNS2   = "94.140.15.15"
    }
    "yandex" = @{
        NameRu = "Яндекс DNS (77.88.8.8 и 77.88.8.1 - Серверы в РФ)"
        NameEn = "Yandex DNS (77.88.8.8 & 77.88.8.1 - RU Fast Servers)"
        DNS1   = "77.88.8.8"
        DNS2   = "77.88.8.1"
    }
    "quad9" = @{
        NameRu = "Quad9 (9.9.9.9 и 149.112.112.112 - Антифишинг)"
        NameEn = "Quad9 (9.9.9.9 & 149.112.112.112 - Privacy & Anti-phishing)"
        DNS1   = "9.9.9.9"
        DNS2   = "149.112.112.112"
    }
}

function Write-LogMsg([string]$msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp] $msg"
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

function Set-CustomDns([string]$dns1, [string]$dns2) {
    if ([string]::IsNullOrWhiteSpace($dns1)) { $dns1 = "1.1.1.1" }
    if ([string]::IsNullOrWhiteSpace($dns2)) { $dns2 = "1.0.0.1" }

    $title = if ($isRu) { "=== Установка DNS: $dns1, $dns2 ===" } else { "=== Setting DNS: $dns1, $dns2 ===" }
    Write-Host ""
    Write-Host $title -ForegroundColor Cyan

    $adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
    if (-not $adapters) {
        $noAdapters = if ($isRu) { "[!] Активных сетевых адаптеров не найдено." } else { "[!] No active network adapters found." }
        Write-Host $noAdapters -ForegroundColor Red
        return
    }

    $backupList = @()

    foreach ($a in $adapters) {
        $ipv4Dns = (Get-DnsClientServerAddress -InterfaceAlias $a.Name -AddressFamily IPv4).ServerAddresses
        $guid = $a.InterfaceGuid
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
        $nameServer = ""
        if (Test-Path $regPath) {
            $nameServer = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).NameServer
        }
        $isDhcp = [string]::IsNullOrWhiteSpace($nameServer)

        $entry = [PSCustomObject]@{
            InterfaceName = $a.Name
            InterfaceGuid = $guid
            IsDhcp        = $isDhcp
            IPv4Addresses = $ipv4Dns
            BackupDate    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $backupList += $entry

        $origDesc = if ($isDhcp) { "DHCP ($($ipv4Dns -join ', '))" } else { "Static ($($ipv4Dns -join ', '))" }
        Write-LogMsg "DNS '$($a.Name)': $origDesc -> $dns1, $dns2"

        try {
            Set-DnsClientServerAddress -InterfaceAlias $a.Name -ServerAddresses ($dns1, $dns2)
            $okMsg = if ($isRu) { "[OK] Адаптер '$($a.Name)': установлен DNS $dns1, $dns2" } else { "[OK] Adapter '$($a.Name)': set DNS to $dns1, $dns2" }
            Write-Host $okMsg -ForegroundColor Green
        } catch {
            $errMsg = if ($isRu) { "[!] Ошибка для '$($a.Name)': $_" } else { "[!] Error on '$($a.Name)': $_" }
            Write-Host $errMsg -ForegroundColor Red
        }
    }

    try {
        $backupList | ConvertTo-Json -Depth 3 | Set-Content -Path $BackupFile -Encoding UTF8
    } catch { }

    Clear-DnsClientCache
    $flushMsg = if ($isRu) { "[*] Кэш DNS очищен." } else { "[*] DNS cache flushed." }
    Write-Host $flushMsg -ForegroundColor Gray

    $doneMsg = if ($isRu) { "DNS успешно применен!" } else { "DNS successfully applied!" }
    Write-Host $doneMsg -ForegroundColor Green
}

function Apply-DnsProfile([string]$profileKey) {
    if (-not $DNS_PROFILES.ContainsKey($profileKey)) {
        $profileKey = "comss"
    }
    $prof = $DNS_PROFILES[$profileKey]
    $dns1 = $prof.DNS1
    $dns2 = $prof.DNS2
    Set-CustomDns $dns1 $dns2
}

function Reset-AllDnsToDhcp {
    $title = if ($isRu) { "=== Сброс DNS на автоматический (DHCP) ===" } else { "=== Resetting DNS to Automatic (DHCP) ===" }
    Write-Host ""
    Write-Host $title -ForegroundColor Cyan

    $adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
    foreach ($a in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceAlias $a.Name -ResetServerAddresses
            Write-LogMsg "RESET DHCP: '$($a.Name)'"
            $okMsg = if ($isRu) { "[OK] '$($a.Name)' переключен на DHCP." } else { "[OK] '$($a.Name)' reset to DHCP." }
            Write-Host $okMsg -ForegroundColor Green
        } catch {
            $errMsg = if ($isRu) { "[!] Ошибка для '$($a.Name)': $_" } else { "[!] Error on '$($a.Name)': $_" }
            Write-Host $errMsg -ForegroundColor Red
        }
    }
    Clear-DnsClientCache
    $doneMsg = if ($isRu) { "DNS успешно сброшен на DHCP!" } else { "DNS successfully reset to DHCP!" }
    Write-Host $doneMsg -ForegroundColor Green
}

function Restore-OriginalDns {
    $title = if ($isRu) { "=== Восстановление исходных настроек DNS ===" } else { "=== Restoring Original DNS Settings ===" }
    Write-Host ""
    Write-Host $title -ForegroundColor Cyan

    if (-not (Test-Path $BackupFile)) {
        $notFoundMsg = if ($isRu) { "[!] Резервная копия не найдена. Выполнить сброс на DHCP? (Y/N)" } else { "[!] Backup file not found. Reset to DHCP? (Y/N)" }
        Write-Host $notFoundMsg -ForegroundColor Yellow
        $choice = Read-Host
        if ($choice -eq 'Y' -or $choice -eq 'y') {
            Reset-AllDnsToDhcp
        }
        return
    }

    try {
        $jsonContent = Get-Content -Path $BackupFile -Raw -Encoding UTF8
        $backupData = $jsonContent | ConvertFrom-Json
        foreach ($item in $backupData) {
            $adapterName = $item.InterfaceName
            if ($item.IsDhcp) {
                Set-DnsClientServerAddress -InterfaceAlias $adapterName -ResetServerAddresses
            } else {
                if ($item.IPv4Addresses -and $item.IPv4Addresses.Count -gt 0) {
                    Set-DnsClientServerAddress -InterfaceAlias $adapterName -ServerAddresses $item.IPv4Addresses
                } else {
                    Set-DnsClientServerAddress -InterfaceAlias $adapterName -ResetServerAddresses
                }
            }
        }
        Clear-DnsClientCache
        $restoredMsg = if ($isRu) { "Исходный DNS успешно восстановлен!" } else { "Original DNS restored successfully!" }
        Write-Host $restoredMsg -ForegroundColor Green
    } catch {
        $errMsg = if ($isRu) { "[!] Ошибка восстановления: $_" } else { "[!] Restore error: $_" }
        Write-Host $errMsg -ForegroundColor Red
    }
}

function Show-Log {
    if (Test-Path $LogFile) {
        Write-Host ""
        $logTitle = if ($isRu) { "=== Журнал изменений DNS ($LogFile) ===" } else { "=== DNS History Log ($LogFile) ===" }
        Write-Host $logTitle -ForegroundColor Yellow
        Get-Content -Path $LogFile -Tail 25 -Encoding UTF8
        Write-Host "==========================================" -ForegroundColor Yellow
    } else {
        $emptyLog = if ($isRu) { "[!] Журнал пока пуст." } else { "[!] Log is empty." }
        Write-Host $emptyLog -ForegroundColor Gray
    }
}

# Обработка действий командной строки
switch ($Action.ToLower()) {
    "setdns" {
        Set-CustomDns $PrimaryDns $SecondaryDns
    }
    "apply" {
        Apply-DnsProfile $Preset
    }
    "reset" {
        Reset-AllDnsToDhcp
    }
    "resetdns" {
        Reset-AllDnsToDhcp
    }
    "restore" {
        Restore-OriginalDns
    }
    "log" {
        Show-Log
    }
    default {
        # Интерактивное двуязычное меню
        while ($true) {
            Write-Host ""
            if ($isRu) {
                Write-Host "========================================================" -ForegroundColor Cyan
                Write-Host "           Выбор и управление DNS серверами             " -ForegroundColor Cyan
                Write-Host "========================================================" -ForegroundColor Cyan
                Write-Host " [1] Comss.one (Разблокировка Gemini, ChatGPT, Spotify, Xbox)" -ForegroundColor Green
                Write-Host " [2] Cloudflare DNS (1.1.1.1 и 1.0.0.1 - быстрый глобальный)"
                Write-Host " [3] Google DNS (8.8.8.8 и 8.8.4.4)"
                Write-Host " [4] AdGuard DNS (94.140.14.14 - блокировка рекламы)"
                Write-Host " [5] Яндекс DNS (77.88.8.8 - серверы в РФ)"
                Write-Host " [6] Quad9 (9.9.9.9 - антифишинг и приватность)"
                Write-Host " --------------------------------------------------------"
                Write-Host " [7] Вернуть исходные настройки DNS из бэкапа" -ForegroundColor Yellow
                Write-Host " [8] Сбросить DNS на автоматический роутера (DHCP)"
                Write-Host " [9] Посмотреть журнал изменений (лог)"
                Write-Host " [E] Switch language to English" -ForegroundColor Magenta
                Write-Host " [0] Выход"
                Write-Host "========================================================" -ForegroundColor Cyan
                Write-Host -NoNewline "Выберите действие [0-9, E]: "
            } else {
                Write-Host "========================================================" -ForegroundColor Cyan
                Write-Host "             DNS Server Management Tool                 " -ForegroundColor Cyan
                Write-Host "========================================================" -ForegroundColor Cyan
                Write-Host " [1] Comss.one (Unblock Gemini, ChatGPT, Spotify, Xbox)" -ForegroundColor Green
                Write-Host " [2] Cloudflare DNS (1.1.1.1 & 1.0.0.1 - Fast Global)"
                Write-Host " [3] Google DNS (8.8.8.8 & 8.8.4.4)"
                Write-Host " [4] AdGuard DNS (94.140.14.14 - Ad & Tracker Blocking)"
                Write-Host " [5] Yandex DNS (77.88.8.8 - RU Fast Servers)"
                Write-Host " [6] Quad9 (9.9.9.9 - Privacy & Anti-phishing)"
                Write-Host " --------------------------------------------------------"
                Write-Host " [7] Restore original DNS settings from backup" -ForegroundColor Yellow
                Write-Host " [8] Reset DNS to automatic (DHCP)"
                Write-Host " [9] View DNS change history log"
                Write-Host " [R] Переключить язык на Русский" -ForegroundColor Magenta
                Write-Host " [0] Exit"
                Write-Host "========================================================" -ForegroundColor Cyan
                Write-Host -NoNewline "Choose an action [0-9, R]: "
            }
            $inputVal = Read-Host

            switch ($inputVal.ToUpper()) {
                "1" { Apply-DnsProfile "comss" }
                "2" { Apply-DnsProfile "cloudflare" }
                "3" { Apply-DnsProfile "google" }
                "4" { Apply-DnsProfile "adguard" }
                "5" { Apply-DnsProfile "yandex" }
                "6" { Apply-DnsProfile "quad9" }
                "7" { Restore-OriginalDns }
                "8" { Reset-AllDnsToDhcp }
                "9" { Show-Log }
                "E" { $script:isRu = $false }
                "R" { $script:isRu = $true }
                "0" { return }
                default {
                    $invalidMsg = if ($isRu) { "Неверный выбор." } else { "Invalid choice." }
                    Write-Host $invalidMsg -ForegroundColor Red
                }
            }
        }
    }
}
