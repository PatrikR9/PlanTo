# Builds an installable APK with the backend actually wired in.
#
# This script exists because `flutter build apk` on its own produces a working
# app that cannot talk to Supabase, and says so only in a small red stripe at
# the bottom of the screen. SUPABASE_URL and SUPABASE_ANON_KEY arrive through
# String.fromEnvironment, which is resolved at COMPILE time — leave the flag
# off and empty strings are baked into the binary permanently. Reinstalling
# does not help; only rebuilding does.
#
# It is a footgun with no upside, so the flag lives here instead of in
# somebody's memory.
#
#   .\tool\build_apk.ps1              # dev config
#   .\tool\build_apk.ps1 -Env prod    # once env/prod.json exists

param(
    [string]$Env = 'dev'
)

$ErrorActionPreference = 'Stop'
$configFile = "env/$Env.json"

if (-not (Test-Path $configFile)) {
    Write-Error @"
$configFile not found.

It is gitignored on purpose — it holds the project URL and the anon key.
Copy the template and fill it in:

    cp env/dev.json.example $configFile
"@
}

# A quick sanity check on the contents, because an empty value fails exactly
# the same way a missing file does, just later and less obviously.
$config = Get-Content $configFile -Raw | ConvertFrom-Json
foreach ($key in @('SUPABASE_URL', 'SUPABASE_ANON_KEY')) {
    if ([string]::IsNullOrWhiteSpace($config.$key)) {
        Write-Error "$key is empty in $configFile."
    }
}

Write-Host "Building with $configFile ..." -ForegroundColor Cyan

flutter build apk --release --dart-define-from-file=$configFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$apk = 'build/app/outputs/flutter-apk/app-release.apk'
Write-Host ""
Write-Host "Done: $apk" -ForegroundColor Green
Write-Host "Install over USB with: adb install -r $apk"
