@echo off
setlocal
set "THEME_TOGGLE_SCRIPT=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:THEME_TOGGLE_SCRIPT); $p=$s.Split([string[]]@('###PSCODE###'),[StringSplitOptions]::None)[-1]; Invoke-Expression $p"
if errorlevel 1 (
  echo.
  echo Theme switching failed. Check the error above.
  pause
)
exit /b
###PSCODE###
$ErrorActionPreference = 'Stop'
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$desktopReg = 'HKCU:\Control Panel\Desktop'
$folder = Join-Path $env:LOCALAPPDATA 'TAZ8ThemeToggle'
$backupFile = Join-Path $folder 'original-wallpaper.json'
$darkFile = Join-Path $folder 'dark-wallpaper.bmp'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
New-Item -Path $reg -Force | Out-Null

Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ThemeNative {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SystemParametersInfo(int action, int param, string value, int flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wp, string lp, uint flags, uint timeout, out UIntPtr result);
}
'@

function Set-Wallpaper([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (-not [ThemeNative]::SystemParametersInfo(20, 0, $path, 3)) {
        throw 'Windows could not apply the wallpaper.'
    }
}

function Notify-Theme {
    $result = [UIntPtr]::Zero
    [void][ThemeNative]::SendMessageTimeout([IntPtr]65535, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 3000, [ref]$result)
    [void][ThemeNative]::SendMessageTimeout([IntPtr]65535, 0x1A, [UIntPtr]::Zero, 'WindowsThemeElement', 2, 3000, [ref]$result)
}

function Get-RegistryText([string]$path, [string]$name, [string]$fallback) {
    $v = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $v) { return $fallback }
    return [string]$v
}

$existing = Get-RegistryText $reg 'AppsUseLightTheme' '1'
$toDark = ($existing -ne '0')

if ($toDark) {
    # Save the real original wallpaper before replacing it.
    $saved = [ordered]@{
        wallpaper = Get-RegistryText $desktopReg 'WallPaper' ''
        style = Get-RegistryText $desktopReg 'WallpaperStyle' '10'
        tile = Get-RegistryText $desktopReg 'TileWallpaper' '0'
    }
    $saved | ConvertTo-Json | Set-Content -LiteralPath $backupFile -Encoding UTF8

    # Build a local dark wallpaper: no downloads, no external dependencies.
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap(1920, 1080)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, 1920, 1080)
        $top = [System.Drawing.Color]::FromArgb(9, 14, 27)
        $bottom = [System.Drawing.Color]::FromArgb(22, 30, 48)
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $top, $bottom, 90)
        try { $gfx.FillRectangle($brush, $rect) } finally { $brush.Dispose() }
        $bmp.Save($darkFile, [System.Drawing.Imaging.ImageFormat]::Bmp)
    } finally { $gfx.Dispose(); $bmp.Dispose() }

    Set-ItemProperty -Path $desktopReg -Name WallpaperStyle -Value '10'
    Set-ItemProperty -Path $desktopReg -Name TileWallpaper -Value '0'
    Set-Wallpaper $darkFile
    $mode = 0
    Write-Host 'DARK MODE ON' -ForegroundColor Cyan
} else {
    $mode = 1
    if (Test-Path -LiteralPath $backupFile) {
        $saved = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
        if ($saved.wallpaper -and (Test-Path -LiteralPath $saved.wallpaper)) {
            Set-ItemProperty -Path $desktopReg -Name WallpaperStyle -Value ([string]$saved.style)
            Set-ItemProperty -Path $desktopReg -Name TileWallpaper -Value ([string]$saved.tile)
            Set-Wallpaper ([string]$saved.wallpaper)
        } else {
            Write-Warning 'Original wallpaper file no longer exists; leaving current wallpaper unchanged.'
        }
        Remove-Item -LiteralPath $backupFile -Force
    }
    Write-Host 'LIGHT MODE ON' -ForegroundColor Yellow
}

# Update both app surfaces and Windows shell surfaces.
New-ItemProperty -Path $reg -Name AppsUseLightTheme -Value $mode -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $reg -Name SystemUsesLightTheme -Value $mode -PropertyType DWord -Force | Out-Null
Notify-Theme

# Some Windows 11 Explorer builds cache the old theme until shell restart.
# This may briefly hide the taskbar and close open Explorer windows.
$explorers = @(Get-Process explorer -ErrorAction SilentlyContinue)
if ($explorers.Count -gt 0) {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 650
    Start-Process explorer.exe
}
Write-Host 'Explorer refreshed. Done.' -ForegroundColor Green
