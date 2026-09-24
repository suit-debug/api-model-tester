# ============================================================================
#  uninstall.ps1  -  Api Model Tester 卸载脚本
#
#  安全设计：
#    1. 默认「演练模式」——只列出会删什么，不动任何文件；真删必须显式 -Force。
#    2. 只动三个已知位置：桌面快捷方式、本程序安装目录、%LOCALAPPDATA%\ApiModelTester
#    3. 不递归扫描、不匹配通配符、不碰任何其他目录。
#
#  用法：
#     powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1            # 演练
#     powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Force     # 真删
#     powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Force -KeepSettings
# ============================================================================

param(
    [switch]$Force,
    [switch]$KeepSettings
)

$ErrorActionPreference = 'Continue'

$installDir = $PSScriptRoot
$settingsDir = Join-Path $env:LOCALAPPDATA 'ApiModelTester'
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcut = Join-Path $desktop 'API Model Tester.lnk'

Write-Host ''
Write-Host '=== API Model Tester 卸载 ==='
Write-Host ''
Write-Host ('安装目录      : ' + $installDir)
Write-Host ('桌面快捷方式  : ' + $shortcut + '   [' + $(if (Test-Path $shortcut) { '存在' } else { '不存在' }) + ']')
if ($KeepSettings) {
    Write-Host ('配置目录      : ' + $settingsDir + '   [保留]')
} else {
    Write-Host ('配置目录      : ' + $settingsDir + '   [' + $(if (Test-Path $settingsDir) { '存在' } else { '不存在' }) + ']')
}
Write-Host ''

if (-not $Force) {
    Write-Host '当前是演练模式，没有删除任何东西。'
    Write-Host '确认要卸载请加 -Force 再运行一次：'
    Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installDir 'uninstall.ps1') + '" -Force')
    Write-Host ''
    Write-Host '注：本程序没有服务、没有注册表项、没有计划任务，删除文件即彻底卸载。'
    return
}

# ---- 1. 桌面快捷方式 ----
if (Test-Path $shortcut) {
    try {
        [System.IO.File]::Delete($shortcut)
        Write-Host '[OK]   已删除桌面快捷方式'
    } catch {
        Write-Host ('[FAIL] 删除快捷方式失败: ' + $_.Exception.Message)
    }
} else {
    Write-Host '[SKIP] 桌面快捷方式不存在'
}

# ---- 2. 配置目录 ----
if ($KeepSettings) {
    Write-Host '[SKIP] 按 -KeepSettings 保留配置目录'
} elseif (Test-Path $settingsDir) {
    try {
        [System.IO.Directory]::Delete($settingsDir, $true)
        Write-Host '[OK]   已删除配置目录'
    } catch {
        Write-Host ('[FAIL] 删除配置目录失败: ' + $_.Exception.Message)
    }
} else {
    Write-Host '[SKIP] 配置目录不存在'
}

# ---- 3. 安装目录（最后删，且允许失败后手工删除） ----
Write-Host ''
Write-Host '正在删除安装目录…'
$selfName = [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
$failed = New-Object System.Collections.ArrayList

if (Test-Path $installDir) {
    foreach ($f in @(Get-ChildItem -Path $installDir -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.FullName -ieq $MyInvocation.MyCommand.Path) { continue }   # 自己最后处理
        try { [System.IO.File]::Delete($f.FullName) }
        catch { [void]$failed.Add($f.FullName) }
    }
    foreach ($d in @(Get-ChildItem -Path $installDir -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
        try { [System.IO.Directory]::Delete($d.FullName, $false) } catch { }
    }
    Write-Host ('[OK]   已清空安装目录内容（' + $failed.Count + ' 个文件未能删除）')
    if ($failed.Count -gt 0) {
        Write-Host '       以下文件被占用，请关闭本程序后手动删除：'
        foreach ($f in $failed) { Write-Host ('         ' + $f) }
    }
    Write-Host ''
    Write-Host '最后一步：本脚本自身所在的文件夹可能无法自删，'
    Write-Host ('请手动删除整个目录： ' + $installDir)
}

Write-Host ''
Write-Host '卸载流程结束。'
