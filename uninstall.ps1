# Bleep Box uninstaller

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

while (Get-Process obs64 -ErrorAction SilentlyContinue) {
    Write-Host 'OBS is open. Close OBS, then push Enter.' -ForegroundColor Red
    Read-Host | Out-Null
}
Get-Process BleepBox -ErrorAction SilentlyContinue | Stop-Process -Force

$paths = @(
    (Join-Path $env:ProgramData 'obs-studio\plugins\bleep-box'),
    (Join-Path $env:ProgramFiles 'Bleep Box'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Bleep Box.lnk'),
    (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Bleep Box.lnk')
)
foreach ($p in $paths) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Host "Removed $p" }
}
Write-Host ''
Write-Host 'To remove the Stream Deck plugin: Stream Deck -> Preferences -> Plugins -> Bleep Box -> Uninstall.'
Write-Host 'Push Enter to close.'
Read-Host | Out-Null
