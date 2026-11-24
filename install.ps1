# Bleep Box installer
# Installs: OBS plugin, Bleep Box app (with Start menu + desktop shortcut), Stream Deck plugin.

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$here = Split-Path -Parent $PSCommandPath
Write-Host ''
Write-Host '=== Bleep Box installer ===' -ForegroundColor Yellow

# 0. All files must be here
$need = @('obs-plugin\bleep-box\bin\64bit\bleep-box.dll', 'app\BleepBox.exe')
$missing = $need | Where-Object { -not (Test-Path (Join-Path $here $_)) }
if ($missing) {
    Write-Host 'This folder is not complete. These files are missing:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host 'Ask the person who sent you Bleep Box for the complete folder.'
    Write-Host 'Push Enter to close.'
    Read-Host | Out-Null
    exit 1
}

# 1. OBS must be closed
while (Get-Process obs64 -ErrorAction SilentlyContinue) {
    Write-Host 'OBS is open. Close OBS, then push Enter.' -ForegroundColor Red
    Read-Host | Out-Null
}

# 2. OBS plugin
$pluginRoot = Join-Path $env:ProgramData 'obs-studio\plugins'
$pluginDst = Join-Path $pluginRoot 'bleep-box'
New-Item -ItemType Directory -Force $pluginRoot | Out-Null
if (Test-Path $pluginDst) { Remove-Item $pluginDst -Recurse -Force }
Copy-Item (Join-Path $here 'obs-plugin\bleep-box') $pluginDst -Recurse -Force
Write-Host "OBS plugin installed: $pluginDst" -ForegroundColor Green

# 3. App
$appDir = Join-Path $env:ProgramFiles 'Bleep Box'
New-Item -ItemType Directory -Force $appDir | Out-Null
Get-Process BleepBox -ErrorAction SilentlyContinue | Stop-Process -Force
Copy-Item (Join-Path $here 'app\BleepBox.exe') $appDir -Force
$exe = Join-Path $appDir 'BleepBox.exe'

$shell = New-Object -ComObject WScript.Shell
$links = @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Bleep Box.lnk'),
    (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Bleep Box.lnk')
)
foreach ($l in $links) {
    $sc = $shell.CreateShortcut($l)
    $sc.TargetPath = $exe
    $sc.WorkingDirectory = $appDir
    $sc.IconLocation = "$exe,0"
    $sc.Save()
}
Write-Host "App installed: $exe" -ForegroundColor Green

# 4. Stream Deck plugin (opened through Explorer so Stream Deck does not start as admin)
$sd = Join-Path $here 'streamdeck\com.frankievalletech.bleepbox.streamDeckPlugin'
if (Test-Path $sd) {
    Start-Process explorer.exe "`"$sd`""
    Write-Host 'Stream Deck plugin: push "Install" in the Stream Deck window.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host ' 1. Open OBS. Sources -> + -> Bleep Box Mic. Pick your microphone.'
Write-Host ' 2. Remove or mute your old mic source in OBS, so the mic is not heard two times.'
Write-Host ' 3. Open the Bleep Box app.'
Write-Host ' 4. In Stream Deck, drag "Bleep" (Bleep Box category) onto a key.'
Write-Host ''
Write-Host 'Push Enter to close.'
Read-Host | Out-Null
