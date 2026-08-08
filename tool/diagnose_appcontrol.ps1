# Kdo zablokoval gen_snapshot.exe?
#
# `flutter build apk --release` spadl na
#   ProcessException: Zásada řízení aplikací tento soubor zablokovala
# u gen_snapshot.exe. Debug buildy chodí, protože AOT kompilátor se v nich
# nepoužívá — proto se to projevilo až u prvního release buildu.
#
# Kandidátů je víc a každý se řeší jinak:
#   • Smart App Control  — vypnutí je nevratné bez reinstalace Windows
#   • WDAC / App Control — firemní nebo lokální politika, dá se upravit
#   • AppLocker          — pravidla, dají se doplnit
#   • antivirus          — stačí výjimka
#
# Tenhle skript nic nemění. Jen se ptá a zapíše odpovědi do souboru.
#
#   .\tool\diagnose_appcontrol.ps1

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path _logs | Out-Null
$out = "_logs/appcontrol.txt"
"" | Set-Content $out

function Section($name) {
    "" | Add-Content $out
    "===== $name =====" | Add-Content $out
}

Section 'Smart App Control'
# 0 = vypnuto (a už nejde zapnout), 1 = vynucuje, 2 = hodnotící režim
$sac = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
    -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue
if ($null -eq $sac) {
    "klic neexistuje -> Smart App Control na tomhle stroji neni" | Add-Content $out
} else {
    $v = $sac.VerifiedAndReputablePolicyState
    $slovy = switch ($v) {
        0 { 'vypnuto' }
        1 { 'ZAPNUTO, vynucuje' }
        2 { 'hodnotici rezim' }
        default { 'neznama hodnota' }
    }
    "VerifiedAndReputablePolicyState = $v ($slovy)" | Add-Content $out
}

Section 'Device Guard / WDAC'
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
    -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue |
    Select-Object CodeIntegrityPolicyEnforcementStatus,
                  UsermodeCodeIntegrityPolicyEnforcementStatus,
                  SecurityServicesRunning |
    Format-List | Out-String | Add-Content $out

Section 'Aktivni CI politiky'
& "$env:SystemRoot\System32\CiTool.exe" -lp 2>&1 |
    Select-String -Pattern 'FriendlyName|PolicyID|IsEnforced|IsSystemPolicy' |
    Out-String | Add-Content $out

Section 'CodeIntegrity - co se blokovalo (poslednich 40)'
# 3077 = zablokovano, 3076 = jen by se zablokovalo (audit),
# 3033/3034 = blok v user-mode
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' `
    -MaxEvents 40 -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 3033, 3034, 3076, 3077 } |
    ForEach-Object {
        "[{0}] Id={1}" -f $_.TimeCreated, $_.Id
        ($_.Message -split "`r?`n" | Select-Object -First 6) -join "`n"
        "---"
    } | Out-String | Add-Content $out

Section 'AppLocker'
Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty RuleCollections |
    Select-Object RuleCollectionType, EnforcementMode |
    Format-Table | Out-String | Add-Content $out

Section 'Defender'
Get-MpComputerStatus -ErrorAction SilentlyContinue |
    Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled,
                  IsTamperProtected |
    Format-List | Out-String | Add-Content $out
"-- detekce za poslednich 24 h --" | Add-Content $out
Get-MpThreatDetection -ErrorAction SilentlyContinue |
    Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-1) } |
    Select-Object InitialDetectionTime, Resources |
    Format-List | Out-String | Add-Content $out

Section 'Sam gen_snapshot'
$gs = "$env:LOCALAPPDATA\..\..\tests\flutter\bin\cache\artifacts\engine\android-arm64-release\windows-x64\gen_snapshot.exe"
$gs = 'C:\Users\patri\tests\flutter\bin\cache\artifacts\engine\android-arm64-release\windows-x64\gen_snapshot.exe'
if (Test-Path $gs) {
    "existuje: $gs" | Add-Content $out
    (Get-Item $gs).Length | ForEach-Object { "velikost: $_ B" } | Add-Content $out
    # Podepsaný? Tohle je jádro věci — nepodepsaný soubor je přesně to,
    # co Smart App Control odmítá.
    Get-AuthenticodeSignature $gs |
        Select-Object Status, StatusMessage, SignerCertificate |
        Format-List | Out-String | Add-Content $out
    # Stažený z internetu? Zone.Identifier taky umí blokovat spuštění.
    $z = Get-Item -Path $gs -Stream Zone.Identifier -ErrorAction SilentlyContinue
    if ($z) { "MA Zone.Identifier (stazeno z internetu)" | Add-Content $out }
    else    { "bez Zone.Identifier" | Add-Content $out }
} else {
    "NENALEZEN: $gs" | Add-Content $out
}

Write-Host ""
Write-Host "Hotovo -> $out" -ForegroundColor Green
Write-Host "Rekni a prectu si to." -ForegroundColor Cyan
