# ============================================================================
#  ApiModelTester.ps1  -  API Model Tester 主程序（Windows / WinForms）
#
#  用法：
#     桌面快捷方式 -> Launch.vbs -> powershell -STA -File ApiModelTester.ps1
#     手动： powershell -NoProfile -STA -ExecutionPolicy Bypass -File ApiModelTester.ps1
#
#  架构：
#     主线程只做两件事：渲染 + 每 20ms 推进一步状态机（Invoke-Tick）。
#     所有网络 I/O 都由 .NET 异步 API 抛出，主线程从不阻塞等待；
#     并发上限由「在飞任务数 <= Concurrency」的补位算法保证。
#
#  安全：
#     API Key 只存在于内存中的控件里，不写日志/CSV/报告/配置文件，也不进命令行参数。
#     所有出文本的地方统一过 Mask-Secret。
# ============================================================================

#Requires -Version 5.1

param(
    [switch]$NoRelaunch,
    [switch]$Diagnose,
    [string]$AutoDemo = '',
    [switch]$ForceShow
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 目录 / 依赖
$Script:ScriptFile = $MyInvocation.MyCommand.Path
$Script:Root = $PSScriptRoot
if ([string]::IsNullOrEmpty($Script:Root)) {
    $Script:Root = Split-Path -Parent $Script:ScriptFile
}
if ([string]::IsNullOrEmpty($Script:ScriptFile)) {
    $Script:ScriptFile = Join-Path $Script:Root 'ApiModelTester.ps1'
}
$Script:IconPath = Join-Path $Script:Root 'assets\icon.ico'
$Script:DiagnoseMode = [bool]$Diagnose
$Script:AutoDemoUrl = [string]$AutoDemo
$Script:ForceShow = [bool]$ForceShow
$Script:Booted = $false
$Script:TraceLines = New-Object System.Collections.ArrayList

. (Join-Path $Script:Root 'lib\Core.ps1')
. (Join-Path $Script:Root 'lib\HttpEngine.ps1')
. (Join-Path $Script:Root 'lib\Detect.ps1')

# ---------------------------------------------------------------- 启动追踪
# 每次启动重写 startup.log。GUI 进程是由 Launch.vbs 以隐藏窗口方式拉起的，
# 一旦启动阶段出错，控制台输出看不见 —— 这个日志是唯一的现场（不含任何密钥）。
$Script:TracePath = Join-Path (Split-Path -Parent (Get-SettingsPath)) 'startup.log'

function Write-Trace {
    param([string]$Text)
    $line = (Get-Date -Format 'HH:mm:ss.fff') + '  ' + $Text
    $line = Mask-Secret $line $Script:KeyMask
    try { [void]$Script:TraceLines.Add($line) } catch { }
    try {
        $p = $Script:TracePath
        $d = [System.IO.Path]::GetDirectoryName($p)
        if ($d -and -not (Test-Path $d)) { [void](New-Item -ItemType Directory -Force -Path $d) }
        if ((Test-Path $p) -and $Script:TraceLines.Count -le 1) { [System.IO.File]::Delete($p) }
        [System.IO.File]::AppendAllText($p, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Show-FatalMessage {
    param([string]$Text)
    try {
        $null = [System.Windows.Forms.MessageBox]
        [void][System.Windows.Forms.MessageBox]::Show($Text, 'API Model Tester', 'OK', 'Error')
    } catch { }
}

# 兜底：任何未捕获的终止错误都写进 startup.log；启动阶段出错则弹窗告知
trap {
    $em = ''
    try { $em = [string]$_.Exception.Message } catch { }
    $st = ''
    try { $st = [string]$_.ScriptStackTrace } catch { }
    Write-Trace ('FATAL: ' + $em)
    if ($st) { Write-Trace ('STACK: ' + ($st -replace "`r?`n", ' << ')) }
    if (-not $Script:Booted) {
        Show-FatalMessage ("启动失败：" + $em + "`r`n`r`n诊断日志：" + $Script:TracePath +
                           "`r`n`r`n可以把 startup.log 发给开发者定位问题。")
        exit 1
    }
    continue
}

Write-Trace '=== boot ==='
Write-Trace ('exe=' + [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
Write-Trace ('ps=' + $PSVersionTable.PSVersion.ToString() + ' edition=' + $PSVersionTable.PSEdition +
             ' apartment=' + [System.Threading.Thread]::CurrentThread.GetApartmentState())
Write-Trace ('root=' + $Script:Root + ' diagnose=' + $Script:DiagnoseMode)

$Script:Asm = Import-NetAssemblies -Name @(
    'System.Net.Http', 'System.Net.Http.WebRequest', 'System.Drawing', 'System.Windows.Forms'
)
foreach ($k in $Script:Asm.Keys) {
    Write-Trace ('asm ' + $k + ' = ' + $(if ($Script:Asm[$k]) { 'ok' } else { 'MISSING' }))
}

function Test-WinFormsAvailable {
    try {
        $null = [System.Windows.Forms.Form]
        $null = [System.Drawing.Bitmap]
        return $true
    } catch {
        return $false
    }
}

function Restart-SelfForGui {
    <#
      WinForms 需要 STA；PowerShell 7 默认 MTA。
      若当前解释器缺少 Windows 桌面程序集，则回退到系统自带的 Windows PowerShell 5.1。
    #>
    param([string]$Reason)

    if ($NoRelaunch) { return $false }

    $cur = ''
    try { $cur = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $cur = '' }
    $exe = ''
    if ($Reason -eq 'sta') {
        if ([string]::IsNullOrEmpty($cur)) { return $false }
        $exe = $cur
    } else {
        $cand = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $cand)) { return $false }
        if ($cur -ieq $cand) { return $false }
        $exe = $cand
    }

    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script:ScriptFile + '"'), '-NoRelaunch')
    try {
        [System.Diagnostics.Process]::Start($exe, ($argList -join ' ')) | Out-Null
        return $true
    } catch {
        return $false
    }
}

$apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
Write-Trace ('apartment check: ' + $apartment)
if ($apartment -ne [System.Threading.ApartmentState]::STA) {
    Write-Trace 'not STA -> relaunch with -STA'
    if (Restart-SelfForGui -Reason 'sta') { exit 0 }
    Write-Trace 'relaunch(-STA) refused, continue anyway'
}

$wfOk = Test-WinFormsAvailable
Write-Trace ('winforms available: ' + $wfOk)
if (-not $wfOk) {
    if (Restart-SelfForGui -Reason 'winforms') {
        Write-Trace 'relaunch with Windows PowerShell 5.1'
        exit 0
    }
    Write-Trace 'winforms unavailable and no fallback interpreter'
    Show-FatalMessage ('无法加载 Windows 窗体程序集 (System.Windows.Forms)。' + "`r`n`r`n" +
                       '请确认在 Windows 上运行，或改用：' + "`r`n" +
                       '  powershell -STA -File "' + $Script:ScriptFile + '"')
    exit 1
}

[void][System.Windows.Forms.Application]::EnableVisualStyles()
Write-Trace 'EnableVisualStyles ok'

# ---------------------------------------------------------------- 运行态
$Script:Cfg          = Read-AppSettings
$Script:Phase        = 'Idle'          # Idle | Fetch | Detect | Test
$Script:Chain        = New-Object System.Collections.Queue
$Script:Engine       = $null
$Script:FetchRun     = $null
$Script:DetectRun    = $null
$Script:TestRun      = $null
$Script:GridRowByRun = @{}
$Script:ModelsUrl    = ''
$Script:DetectCache  = @{ Key = ''; Kind = ''; Url = ''; Score = 0; Valid = $false }
$Script:ProtocolKind = 'Chat'
$Script:ResolvedUrl  = ''
$Script:DetectModels = @()
$Script:DetectProbeIndex = 0
$Script:Busy         = $false
$Script:InTick       = $false
$Script:KeyMask      = ''
$Script:LastReport   = ''

# ============================================================================
#  界面构件
# ============================================================================
function New-Lbl {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 70, [int]$H = 18)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    # 注意：ContentAlignment 属于 System.Drawing，不是 System.Windows.Forms
    $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $l
}

function New-Btn {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 90, [int]$H = 27)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.UseVisualStyleBackColor = $true
    return $b
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'API Model Tester'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)
$w = 1180; $h = 780
try { $w = [int]$Script:Cfg['window']['width'] } catch { }
try { $h = [int]$Script:Cfg['window']['height'] } catch { }
if ($w -lt 980) { $w = 1180 }
if ($h -lt 640) { $h = 780 }
$form.ClientSize = New-Object System.Drawing.Size($w, $h)
try {
    $px = [int]$Script:Cfg['window']['x']
    $py = [int]$Script:Cfg['window']['y']
    if ($px -ge 0 -and $py -ge 0) {
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Location = New-Object System.Drawing.Point($px, $py)
    }
} catch { }
try { if (Test-Path $Script:IconPath) { $form.Icon = New-Object System.Drawing.Icon($Script:IconPath) } } catch { }
Write-Trace 'form created'

# ---- 主体容器先加（Fill 需要最后参与布局） ----
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = [System.Windows.Forms.DockStyle]::Fill
$split.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$split.SplitterWidth = 6
$form.Controls.Add($split)

# ---- 顶部设置区 ----
$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlTop.Height = 146
$form.Controls.Add($pnlTop)

$pnlTop.Controls.Add((New-Lbl 'Base URL' 12 12 62))
$txtBase = New-Object System.Windows.Forms.TextBox
$txtBase.Location = New-Object System.Drawing.Point(78, 9)
$txtBase.Size = New-Object System.Drawing.Size(640, 24)
$txtBase.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
try { $txtBase.Text = [string]$Script:Cfg['baseUrl'] } catch { }
$pnlTop.Controls.Add($txtBase)

$pnlTop.Controls.Add((New-Lbl 'Protocol' 736 12 56))
$cmbProtocol = New-Object System.Windows.Forms.ComboBox
$cmbProtocol.Location = New-Object System.Drawing.Point(796, 9)
$cmbProtocol.Size = New-Object System.Drawing.Size(250, 24)
$cmbProtocol.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbProtocol.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
foreach ($p in $Script:AMT_PROTOCOLS) { [void]$cmbProtocol.Items.Add($p) }
$idx = 0
try { $idx = $cmbProtocol.Items.IndexOf([string]$Script:Cfg['protocol']) } catch { $idx = 0 }
if ($idx -lt 0) { $idx = 0 }
$cmbProtocol.SelectedIndex = $idx
$pnlTop.Controls.Add($cmbProtocol)

$pnlTop.Controls.Add((New-Lbl 'API Key' 12 44 62))
$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = New-Object System.Drawing.Point(78, 41)
$txtKey.Size = New-Object System.Drawing.Size(560, 24)
$txtKey.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$txtKey.UseSystemPasswordChar = $true
$pnlTop.Controls.Add($txtKey)

$btnShowKey = New-Btn '显示' 646 40 62 25
$pnlTop.Controls.Add($btnShowKey)

$pnlTop.Controls.Add((New-Lbl 'Timeout (s)' 720 44 72))
$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Location = New-Object System.Drawing.Point(796, 41)
$numTimeout.Size = New-Object System.Drawing.Size(64, 24)
$numTimeout.Minimum = 3
$numTimeout.Maximum = 600
$t = 30
try { $t = [int]$Script:Cfg['timeoutSec'] } catch { }
if ($t -lt 3 -or $t -gt 600) { $t = 30 }
$numTimeout.Value = $t
$pnlTop.Controls.Add($numTimeout)

$pnlTop.Controls.Add((New-Lbl 'Concurrency' 874 44 76))
$numConc = New-Object System.Windows.Forms.NumericUpDown
$numConc.Location = New-Object System.Drawing.Point(954, 41)
$numConc.Size = New-Object System.Drawing.Size(64, 24)
$numConc.Minimum = 1
$numConc.Maximum = 32
$c0 = 3
try { $c0 = [int]$Script:Cfg['concurrency'] } catch { }
if ($c0 -lt 1 -or $c0 -gt 32) { $c0 = 3 }
$numConc.Value = $c0
$pnlTop.Controls.Add($numConc)

$chkNormalize = New-Object System.Windows.Forms.CheckBox
$chkNormalize.Text = 'Normalize /v1 automatically'
$chkNormalize.Location = New-Object System.Drawing.Point(78, 72)
$chkNormalize.Size = New-Object System.Drawing.Size(220, 22)
$chkNormalize.Checked = $true
try { $chkNormalize.Checked = [bool]$Script:Cfg['normalizeV1'] } catch { }
$pnlTop.Controls.Add($chkNormalize)

$chkAutoTest = New-Object System.Windows.Forms.CheckBox
$chkAutoTest.Text = 'Auto test after fetching models'
$chkAutoTest.Location = New-Object System.Drawing.Point(310, 72)
$chkAutoTest.Size = New-Object System.Drawing.Size(240, 22)
$chkAutoTest.Checked = $false
try { $chkAutoTest.Checked = [bool]$Script:Cfg['autoTestAfterFetch'] } catch { }
$pnlTop.Controls.Add($chkAutoTest)

$btnFetch = New-Btn 'Fetch Models' 78 104 112
$pnlTop.Controls.Add($btnFetch)
$btnTestSel = New-Btn 'Test Selected' 196 104 112
$pnlTop.Controls.Add($btnTestSel)
$btnTestAll = New-Btn 'Test All' 314 104 90
$pnlTop.Controls.Add($btnTestAll)
$btnStop = New-Btn 'Stop' 410 104 72
$btnStop.Enabled = $false
$pnlTop.Controls.Add($btnStop)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(494, 107)
$bar.Size = New-Object System.Drawing.Size(320, 20)
$bar.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$pnlTop.Controls.Add($bar)

$lblStatus = New-Lbl '就绪' 830 104 320 22
$lblStatus.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$pnlTop.Controls.Add($lblStatus)

# ---- 底部工具栏 ----
$pnlBottom = New-Object System.Windows.Forms.Panel
$pnlBottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlBottom.Height = 46
$form.Controls.Add($pnlBottom)

$btnCopyModels = New-Btn 'Copy Available Models' 12 9 168
$pnlBottom.Controls.Add($btnCopyModels)
$btnExportCsv = New-Btn 'Export CSV' 186 9 100
$pnlBottom.Controls.Add($btnExportCsv)
$btnCopyReport = New-Btn 'Copy Test Report' 292 9 138
$pnlBottom.Controls.Add($btnCopyReport)
$btnClear = New-Btn 'Clear' 436 9 80
$pnlBottom.Controls.Add($btnClear)
$lblHint = New-Lbl 'API Key 仅存内存：不写入日志 / CSV / 报告 / 配置文件，也不进命令行参数' 526 11 620 20
$lblHint.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$lblHint.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
$pnlBottom.Controls.Add($lblHint)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = [System.Windows.Forms.DockStyle]::Fill
$grid.AllowUserToAddRows = $true
$grid.AllowUserToDeleteRows = $true
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersWidth = 26
$grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.MultiSelect = $true
$grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.GridColor = [System.Drawing.Color]::FromArgb(228, 228, 228)
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)
$split.Panel1.Controls.Add($grid)

$log = New-Object System.Windows.Forms.TextBox
$log.Dock = [System.Windows.Forms.DockStyle]::Fill
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$log.WordWrap = $false
$log.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 250)
$log.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$split.Panel2.Controls.Add($log)

function Add-GridCol {
    param($G, [string]$Name, [string]$Header, [int]$Width, [string]$Align = 'Left', [bool]$ReadOnly = $true)
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Name
    $col.HeaderText = $Header
    $col.Width = $Width
    $col.ReadOnly = $ReadOnly
    if ($Align -eq 'Right') {
        $col.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
    }
    [void]$G.Columns.Add($col)
    if ($Script:Cfg['columnWidths'].Contains($Name)) {
        $cw = [int]$Script:Cfg['columnWidths'][$Name]
        if ($cw -ge 30) { $col.Width = $cw }
    }
    return $col
}

$colSel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSel.Name = 'Selected'
$colSel.HeaderText = ''
$colSel.Width = 34
$colSel.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
$colSel.Resizable = [System.Windows.Forms.DataGridViewTriState]::False
[void]$grid.Columns.Add($colSel)

[void](Add-GridCol $grid 'Model'           'Model'            190 'Left'  $false)
[void](Add-GridCol $grid 'ReturnedModel'   'Returned Model'   150)
[void](Add-GridCol $grid 'Protocol'        'Protocol'          82)
[void](Add-GridCol $grid 'Endpoint'        'Endpoint'         250)
[void](Add-GridCol $grid 'Http'            'HTTP'              50 'Right')
[void](Add-GridCol $grid 'Status'          'Status'           190)
[void](Add-GridCol $grid 'Latency'         'Latency'           74 'Right')
[void](Add-GridCol $grid 'Ttfb'            'TTFB'              74 'Right')
[void](Add-GridCol $grid 'FinishReason'    'Finish Reason'    104)
[void](Add-GridCol $grid 'ReasoningTokens' 'Reasoning Tokens'  92 'Right')
[void](Add-GridCol $grid 'Content'         'Content'          190)
[void](Add-GridCol $grid 'Error'           'Error'            260)
Write-Trace ('grid columns created: ' + $grid.Columns.Count)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20
Write-Trace 'timer created'

# ============================================================================
#  日志 / 状态
# ============================================================================
function Write-Log {
    param([string]$Text, [string]$Level = 'info')
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text
    $line = Mask-Secret $line $Script:KeyMask
    if ($Level -eq 'err') { $line = '!! ' + $line }
    elseif ($Level -eq 'warn') { $line = '*  ' + $line }
    try {
        $log.AppendText($line + "`r`n")
        if ($log.Lines.Count -gt 600) {
            $keep = $log.Lines[($log.Lines.Count - 400)..($log.Lines.Count - 1)]
            $log.Text = ($keep -join "`r`n")
        }
        $log.SelectionStart = $log.Text.Length
        $log.ScrollToCaret()
    } catch { }
}

function Set-Status {
    param([string]$Text)
    try { $lblStatus.Text = (Mask-Secret $Text $Script:KeyMask) } catch { }
}

function Set-Busy {
    param([bool]$Busy, [string]$Hint = '')
    $Script:Busy = $Busy
    $btnFetch.Enabled = -not $Busy
    $btnTestSel.Enabled = -not $Busy
    $btnTestAll.Enabled = -not $Busy
    $btnStop.Enabled = $Busy
    if ($Busy) {
        $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    } else {
        $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $bar.Value = 0
        if ($Hint -eq '') { $Hint = '就绪' }
    }
    if ($Hint -ne '') { Set-Status $Hint }
}

function Reset-ToIdle {
    $Script:Phase = 'Idle'
    $Script:Chain.Clear()
    if ($null -ne $Script:Engine) { Remove-HttpEngine -Engine $Script:Engine }
    $Script:Engine = $null
    $Script:FetchRun = $null
    $Script:DetectRun = $null
    $Script:TestRun = $null
    Set-Busy $false
}

function Get-ApiKeyRaw {
    return [string]$txtKey.Text
}

# ============================================================================
#  网格
# ============================================================================
function Get-StatusColor {
    param([string]$Class)
    switch ($Class) {
        'ok'        { return [System.Drawing.Color]::FromArgb(20, 120, 60) }
        'warn'      { return [System.Drawing.Color]::FromArgb(176, 112, 0) }
        'cancelled' { return [System.Drawing.Color]::FromArgb(128, 128, 128) }
        default     { return [System.Drawing.Color]::FromArgb(178, 34, 34) }
    }
}

function Reset-GridRowStyle {
    param($Row)
    foreach ($n in @('ReturnedModel', 'Protocol', 'Endpoint', 'Http', 'Status', 'Latency', 'Ttfb',
                     'FinishReason', 'ReasoningTokens', 'Content', 'Error')) {
        $Row.Cells[$n].Value = ''
    }
    $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $Row.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
}

function Add-ModelRow {
    param([string]$Model, [bool]$Checked = $false)
    $i = $grid.Rows.Add()
    $r = $grid.Rows[$i]
    $r.Cells['Selected'].Value = $Checked
    $r.Cells['Model'].Value = $Model
    Reset-GridRowStyle -Row $r
    return $r
}

function Set-GridModels {
    param([string[]]$Models)
    $grid.SuspendLayout()
    $old = $grid.AllowUserToAddRows
    $grid.AllowUserToAddRows = $false
    try { $grid.Rows.Clear() } catch { }
    $grid.AllowUserToAddRows = $old
    foreach ($m in @($Models)) { [void](Add-ModelRow -Model $m) }
    $grid.ResumeLayout()
}

function Get-GridModels {
    param([string]$Selection)
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $grid.Rows) {
        if ($r.IsNewRow) { continue }
        $m = [string]$r.Cells['Model'].Value
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        if ($Selection -eq 'Selected') {
            $chk = $r.Cells['Selected'].Value
            if ($null -eq $chk -or -not [bool]$chk) { continue }
        }
        [void]$out.Add($m.Trim())
    }
    return $out.ToArray()
}

function Update-GridRow {
    param($Row, $R)
    if ($null -eq $Row) { return }
    $Row.Cells['ReturnedModel'].Value = [string]$R.ReturnedModel
    $Row.Cells['Protocol'].Value = [string]$R.Protocol
    $Row.Cells['Endpoint'].Value = Mask-Secret ([string]$R.Endpoint) $Script:KeyMask
    if ($null -ne $R.Http -and [int]$R.Http -gt 0) { $Row.Cells['Http'].Value = [string]$R.Http }
    else { $Row.Cells['Http'].Value = '' }
    $Row.Cells['Status'].Value = Mask-Secret ([string]$R.Status) $Script:KeyMask
    $Row.Cells['Latency'].Value = Format-Latency $R.LatencyMs
    $Row.Cells['Ttfb'].Value = Format-Latency $R.TtfbMs
    $Row.Cells['FinishReason'].Value = [string]$R.FinishReason
    $Row.Cells['ReasoningTokens'].Value = Format-ReasoningTokens $R.ReasoningTokens
    $Row.Cells['Content'].Value = Mask-Secret ([string]$R.ContentPreview) $Script:KeyMask
    $err = [string]$R.Error
    if ($err.Length -gt 400) { $err = $err.Substring(0, 400) + '...' }
    $Row.Cells['Error'].Value = Mask-Secret $err $Script:KeyMask
    $col = Get-StatusColor ([string]$R.Class)
    $Row.DefaultCellStyle.ForeColor = $col
    $Row.DefaultCellStyle.SelectionForeColor = $col
}

function ConvertTo-SortNumber {
    param($Value, [string]$Col)
    if ($null -eq $Value) { return -1.0 }
    $s = ([string]$Value).Trim()
    if ($s -eq '') { return -1.0 }
    if ($Col -eq 'Latency' -or $Col -eq 'Ttfb') {
        if ($s.EndsWith('ms')) { $s = $s.Substring(0, $s.Length - 2) }
        elseif ($s.EndsWith('s')) {
            $n = 0.0
            if ([double]::TryParse($s.Substring(0, $s.Length - 1), [ref]$n)) { return ($n * 1000.0) }
            return -1.0
        }
        $n2 = 0.0
        if ([double]::TryParse($s, [ref]$n2)) { return $n2 }
        return -1.0
    }
    $n3 = 0
    if ([int]::TryParse($s, [ref]$n3)) { return [double]$n3 }
    return -1.0
}

function Get-StatusRankOfRow {
    param($Row)
    $st = [string]$Row.Cells['Status'].Value
    if ($st -like 'OK*') { return 0 }
    if ($st -like 'Compatibility*') { return 10 }
    if ($st -like 'Cancelled*') { return 95 }
    if ($st -like 'Timeout*') { return 80 }
    $h = 0
    if ([int]::TryParse([string]$Row.Cells['Http'].Value, [ref]$h) -and $h -gt 0) { return $h }
    if ($st -eq '') { return -1 }
    return 90
}

# ============================================================================
#  链式步骤：Fetch -> Detect -> Test
# ============================================================================
function Get-EffectiveBaseUrl {
    return (Expand-BaseUrl $txtBase.Text)
}

function Invalidate-Caches {
    $Script:DetectCache = @{ Key = ''; Kind = ''; Url = ''; Score = 0; Valid = $false }
    $Script:ModelsUrl = ''
    $Script:DetectModels = @()
    $Script:DetectProbeIndex = 0
}

function Get-DetectCacheKey {
    return ((Get-EffectiveBaseUrl) + '|auto|' + [string]$numTimeout.Value + '|' + [string]$chkNormalize.Checked)
}

function Set-Chain {
    param([string[]]$Steps)
    $q = New-Object System.Collections.Queue
    foreach ($s in @($Steps)) { $q.Enqueue($s) }
    $Script:Chain = $q
    # 新的一轮任务：探测样本从第一个模型重新开始
    $Script:DetectModels = @()
    $Script:DetectProbeIndex = 0
}

function Start-FetchModels {
    $base = Get-EffectiveBaseUrl
    if ($base -eq '') {
        Write-Log 'Base URL 为空，无法获取模型列表。' 'err'
        Set-Busy $false
        Reset-ToIdle
        return $false
    }
    if ((Get-ApiKeyRaw) -eq '') {
        Write-Log 'API Key 为空：仍会带空 Bearer 头发送，鉴权站点会返回 401。' 'warn'
    }
    $urls = @($Script:ModelsUrl)
    if ($urls.Count -eq 0 -or [string]::IsNullOrEmpty($urls[0])) {
        $urls = @(Get-ModelListCandidates -BaseUrl $base -Normalize:$chkNormalize.Checked)
    }
    # 同时带 Bearer 与 x-api-key，兼容只认 Anthropic 头的站点
    $headers = Get-RequestHeaders -Kind 'Chat' -ApiKey (Get-ApiKeyRaw) -AnthropicCompat

    $Script:Engine = New-HttpEngine
    $Script:Engine.Secret = (Get-ApiKeyRaw)
    $Script:FetchRun = New-FetchModelsRun -Engine $Script:Engine -Urls $urls `
        -TimeoutSec ([int]$numTimeout.Value) -Headers $headers
    $Script:Phase = 'Fetch'
    Write-Log ('获取模型列表: ' + (Mask-Secret ($urls -join '  |  ') $Script:KeyMask))
    return $true
}

function Start-Detect {
    $models = @(Get-GridModels -Selection 'All')
    if ($Script:DetectModels.Count -eq 0) { $Script:DetectModels = $models }
    if ($Script:DetectModels.Count -eq 0) {
        Write-Log 'Auto Detect 需要一个模型名作为探测样本，但表格里没有模型。' 'err'
        Reset-ToIdle
        return $false
    }
    $idx = $Script:DetectProbeIndex
    if ($idx -ge $Script:DetectModels.Count) { $idx = $Script:DetectModels.Count - 1 }
    if ($idx -lt 0) { $idx = 0 }
    $probeModel = [string]$Script:DetectModels[$idx]

    $plan = @(New-DetectPlan -BaseUrl (Get-EffectiveBaseUrl) -Model $probeModel -ApiKey (Get-ApiKeyRaw) `
        -TimeoutSec ([int]$numTimeout.Value) -Normalize:$chkNormalize.Checked)

    $Script:Engine = New-HttpEngine
    $Script:Engine.Secret = (Get-ApiKeyRaw)
    $Script:DetectRun = New-DetectRun -Engine $Script:Engine -Plan $plan -Concurrency 2
    $Script:Phase = 'Detect'
    Write-Log ('Auto Detect 开始探测：最多 ' + $plan.Count + ' 个候选，命中即停止（样本模型 ' + $probeModel + '）')
    return $true
}

function Start-Test {
    param([string]$Selection)

    $models = @(Get-GridModels -Selection $Selection)
    if ($models.Count -eq 0) {
        Write-Log '没有可测试的模型（表格为空或未勾选）。' 'err'
        Reset-ToIdle
        return $false
    }

    $url = $Script:ResolvedUrl
    if ([string]::IsNullOrEmpty($url)) {
        $url = Get-ApiUrlForAttempt -BaseUrl (Get-EffectiveBaseUrl) -Kind $Script:ProtocolKind -Normalize:$chkNormalize.Checked
    }
    if ([string]::IsNullOrEmpty($url)) {
        Write-Log '无法构造请求端点，请检查 Base URL。' 'err'
        Reset-ToIdle
        return $false
    }

    $Script:Engine = New-HttpEngine
    $Script:Engine.Secret = (Get-ApiKeyRaw)
    $Script:TestRun = New-ApiTestRun -Engine $Script:Engine -Models $models -Kind $Script:ProtocolKind `
        -ApiKey (Get-ApiKeyRaw) -EndpointUrl $url -Concurrency ([int]$numConc.Value) `
        -TimeoutSec ([int]$numTimeout.Value) -AllowRetry `
        -MetaBase @{ BaseUrl = (Get-EffectiveBaseUrl); Normalize = [bool]$chkNormalize.Checked }
    $Script:Phase = 'Test'

    # run 行号 -> 网格行对象（用对象而不是索引，排序后依然定位正确）
    $Script:GridRowByRun = @{}
    $i = 0
    foreach ($r in $grid.Rows) {
        if ($r.IsNewRow) { continue }
        $m = [string]$r.Cells['Model'].Value
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        if ($Selection -eq 'Selected') {
            $chk = $r.Cells['Selected'].Value
            if ($null -eq $chk -or -not [bool]$chk) { continue }
        }
        if ($i -lt $models.Count) {
            Reset-GridRowStyle -Row $r
            $r.Cells['Model'].Value = $models[$i]
            $Script:GridRowByRun[$i] = $r
            $i++
        }
    }

    Write-Log ('开始测试 ' + $models.Count + ' 个模型 | 协议=' + (Get-ProtocolDisplayName $Script:ProtocolKind) +
               ' | 端点=' + (Mask-Secret $url $Script:KeyMask) +
               ' | 并发=' + [string]$numConc.Value + ' | 超时=' + [string]$numTimeout.Value + 's')
    return $true
}

function Invoke-NextStep {
    if ($Script:Chain.Count -eq 0) { return }

    $step = [string]$Script:Chain.Dequeue()
    switch -Regex ($step) {
        '^Fetch$' {
            if (-not (Start-FetchModels)) { return }
        }
        '^Detect$' {
            if (-not (Start-Detect)) { return }
        }
        '^Test:(All|Selected)$' {
            $sel = 'All'
            if ($step -eq 'Test:Selected') { $sel = 'Selected' }

            $models = @(Get-GridModels -Selection $sel)
            if ($models.Count -eq 0) {
                Write-Log '表格里没有模型，先自动获取模型列表，然后再继续测试。'
                Set-Chain @('Fetch', $step)
                return
            }

            $kind = Get-ProtocolKind ([string]$cmbProtocol.SelectedItem)
            if ($kind -eq 'Auto') {
                $key = Get-DetectCacheKey
                if ($Script:DetectCache['Key'] -eq $key -and $Script:DetectCache['Valid']) {
                    $Script:ProtocolKind = [string]$Script:DetectCache['Kind']
                    $Script:ResolvedUrl = [string]$Script:DetectCache['Url']
                    if ($Script:ResolvedUrl -ne '') {
                        Write-Log ('复用会话内已探测到的端点: ' + (Get-ProtocolDisplayName $Script:ProtocolKind) + ' ' +
                                   (Mask-Secret $Script:ResolvedUrl $Script:KeyMask))
                    }
                } else {
                    Set-Chain @('Detect', $step)
                    return
                }
            } else {
                $Script:ProtocolKind = $kind
                $Script:ResolvedUrl = Get-ApiUrlForAttempt -BaseUrl (Get-EffectiveBaseUrl) -Kind $kind -Normalize:$chkNormalize.Checked
            }

            if (-not (Start-Test -Selection $sel)) { return }
        }
        default { }
    }
}

# ============================================================================
#  状态机
# ============================================================================
function Finish-TestPhase {
    param($r)
    # 未产生结果的行统一标记 Cancelled，避免出现空白行
    foreach ($row in @($Script:TestRun.Rows)) {
        if (-not $row.Done) {
            $row.Done = $true
            $row.Status = 'Cancelled'
            $row.StatusShort = 'Cancelled'
            $row.Class = 'cancelled'
            $row.Rank = 95
            if ([string]::IsNullOrEmpty([string]$row.Error)) { $row.Error = '未执行（已中止）' }
            Update-GridRow -Row $Script:GridRowByRun[$row.Index] -R $row
        }
    }
    $ok = 0; $warn = 0; $err = 0; $cancel = 0
    foreach ($row in @($Script:TestRun.Rows)) {
        switch ([string]$row.StatusShort) {
            'OK'        { $ok++ }
            'Warn'      { $warn++ }
            'Cancelled' { $cancel++ }
            default     { $err++ }
        }
    }
    Write-Log ('测试结束：OK ' + $ok + ' | Compatibility Warning ' + $warn + ' | 失败 ' + $err +
               ' | 取消 ' + $cancel + ' | 并发峰值 ' + $r.Peak + ' | 兼容性重试 ' + $r.Retried)
    if ($err -gt 0 -or $warn -gt 0) {
        Write-Log '提示：HTTP 200 但内容异常的模型记为 Compatibility Warning；下方日志与 Error 列保留了服务器原始 error.message。'
    }
    Set-Status ('完成：OK ' + $ok + ' / Warning ' + $warn + ' / 失败 ' + $err + ' / 取消 ' + $cancel)
}

function Invoke-FetchPhase {
    $r = Update-FetchModelsRun -Run $Script:FetchRun
    if (-not $r.Finished) {
        Set-Status ('正在获取模型列表… 在飞 ' + [string]$r.InFlight)
        return
    }
    $Script:Phase = 'Idle'
    if ($null -ne $Script:Engine) { Remove-HttpEngine -Engine $Script:Engine; $Script:Engine = $null }
    $ok = $r.Ok
    if ($ok) {
        $Script:ModelsUrl = [string]$r.Url
        Set-GridModels -Models @($r.Models)
        Write-Log ('获取到 ' + @($r.Models).Count + ' 个模型（端点 ' + (Mask-Secret $Script:ModelsUrl $Script:KeyMask) + '）')
        Set-Status ('已获取 ' + @($r.Models).Count + ' 个模型')
        if ($chkAutoTest.Checked) { Set-Chain @('Test:All') }
    } else {
        Write-Log ('获取模型列表失败：' + $r.Error) 'err'
        Write-Log '提示：可以在表格 Model 列手动输入模型名，再点 Test All。'
        Set-Status '获取模型失败'
    }
}

function Invoke-DetectPhase {
    $r = Update-DetectRun -Run $Script:DetectRun
    if (-not $r.Finished) {
        Set-Status ('Auto Detect 探测中… 已完成 ' + @($Script:DetectRun.Outcomes).Count + ' 个候选')
        return
    }
    $Script:Phase = 'Idle'
    if ($null -ne $Script:Engine) { Remove-HttpEngine -Engine $Script:Engine; $Script:Engine = $null }

    $best = $r.Best
    if ($null -ne $best) {
        Write-Log ('Auto Detect 命中：' + (Get-ProtocolDisplayName $best.Kind) + ' ' +
                   (Mask-Secret $best.Url $Script:KeyMask) + '（HTTP ' + $best.Http + '，评分 ' + $best.Score + '）')
        if ($best.Score -lt 100) {
            Write-Log ('该候选并非 200 成功响应（' + (Mask-Secret ([string]$best.Verdict.Status) $Script:KeyMask) +
                       '），继续用它测试并记录真实错误。') 'warn'
        }
        $Script:DetectCache = @{ Key = (Get-DetectCacheKey); Kind = $best.Kind; Url = $best.Url; Score = $best.Score; Valid = $true }
    } else {
        # 全部候选都不通：很可能只是「第一个模型名已经失效」，换样本模型再试（最多 3 个，有界）
        $maxTry = [Math]::Min(3, $Script:DetectModels.Count)
        if (($Script:DetectProbeIndex + 1) -lt $maxTry) {
            $Script:DetectProbeIndex++
            Write-Log ('样本模型 ' + $Script:DetectModels[$Script:DetectProbeIndex - 1] +
                       ' 上所有候选都不通，换样本模型 ' + $Script:DetectModels[$Script:DetectProbeIndex] + ' 再探测一轮。') 'warn'
            if (Start-Detect) { return }
        }
        Write-Log 'Auto Detect 没有找到可识别的端点（候选全部 404/不可达）。' 'warn'
        Write-Log '回退到 OpenAI Chat Completions 端点继续，以便看到每个模型的真实错误。' 'warn'
        $Script:DetectCache = @{ Key = (Get-DetectCacheKey); Kind = 'Chat'; Url = ''; Score = 0; Valid = $true }
    }
    Set-Status ('探测完成：' + (Get-ProtocolDisplayName ([string]$Script:DetectCache['Kind'])))
}

function Invoke-TestPhase {
    $r = Update-ApiTestRun -Run $Script:TestRun
    foreach ($row in @($r.UpdatedRows)) {
        Update-GridRow -Row $Script:GridRowByRun[$row.Index] -R $row
    }
    $pct = 0
    if ($r.Total -gt 0) { $pct = [int](100.0 * $r.CompletedCount / $r.Total) }
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $bar.Value = $pct
    Set-Status ('测试中 ' + $r.CompletedCount + '/' + $r.Total + '  在飞 ' + $r.InFlight +
                '  排队 ' + $r.Pending + '  并发峰值 ' + $r.Peak)
    if (-not $r.Finished) { return }
    $Script:Phase = 'Idle'
    if ($null -ne $Script:Engine) { Remove-HttpEngine -Engine $Script:Engine; $Script:Engine = $null }
    Finish-TestPhase -r $r
}

function Invoke-Tick {
    if ($Script:InTick) { return }
    $Script:InTick = $true
    try {
        if ($Script:Phase -eq 'Idle') {
            if ($Script:Chain.Count -gt 0) { Invoke-NextStep; return }
            $timer.Stop()
            if ($Script:Busy) { Set-Busy $false }
            return
        }
        switch ($Script:Phase) {
            'Fetch'  { Invoke-FetchPhase }
            'Detect' { Invoke-DetectPhase }
            'Test'   { Invoke-TestPhase }
            default  { $Script:Phase = 'Idle' }
        }
    } catch {
        Write-Log ('内部错误：' + (Mask-Secret $_.Exception.Message $Script:KeyMask)) 'err'
        Reset-ToIdle
    } finally {
        $Script:InTick = $false
    }
}

# ============================================================================
#  结果收集 / 导出
# ============================================================================
function Get-CurrentResults {
    $out = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($r in $grid.Rows) {
        if ($r.IsNewRow) { continue }
        $m = [string]$r.Cells['Model'].Value
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        $http = 0
        [void][int]::TryParse([string]$r.Cells['Http'].Value, [ref]$http)
        $lat = ConvertTo-SortNumber $r.Cells['Latency'].Value 'Latency'
        $ttfb = ConvertTo-SortNumber $r.Cells['Ttfb'].Value 'Ttfb'
        $rt = ConvertTo-SortNumber $r.Cells['ReasoningTokens'].Value 'ReasoningTokens'
        $status = [string]$r.Cells['Status'].Value
        $short = $status
        if ($status -like 'OK*') { $short = 'OK' }
        elseif ($status -like 'Compatibility*') { $short = 'Warn' }
        elseif ($status -like 'Cancelled*') { $short = 'Cancelled' }
        elseif ($status -like 'Timeout*') { $short = 'Timeout' }
        $obj = [ordered]@{
            Index           = $i
            Model           = $m
            RequestedModel  = $m
            ReturnedModel   = [string]$r.Cells['ReturnedModel'].Value
            Protocol        = [string]$r.Cells['Protocol'].Value
            Endpoint        = [string]$r.Cells['Endpoint'].Value
            Http            = $http
            Status          = $status
            StatusShort     = $short
            LatencyMs       = $(if ($lat -ge 0) { $lat } else { $null })
            TtfbMs          = $(if ($ttfb -ge 0) { $ttfb } else { $null })
            FinishReason    = [string]$r.Cells['FinishReason'].Value
            ReasoningTokens = $(if ($rt -ge 0) { $rt } else { $null })
            ContentPresent  = -not [string]::IsNullOrWhiteSpace([string]$r.Cells['Content'].Value)
            ContentPreview  = [string]$r.Cells['Content'].Value
            Error           = [string]$r.Cells['Error'].Value
            Rank            = (Get-StatusRankOfRow $r)
            Notes           = ''
        }
        [void]$out.Add($obj)
        $i++
    }
    return $out.ToArray()
}

function Set-ClipboardSafe {
    param([string]$Text, [string]$What)
    $t2 = Mask-Secret $Text $Script:KeyMask
    try {
        [System.Windows.Forms.Clipboard]::SetText($t2)
        Write-Log ('已复制' + $What + '到剪贴板（' + $t2.Length + ' 字符）')
        return $true
    } catch {
        Write-Log ('复制到剪贴板失败：' + $_.Exception.Message) 'err'
        return $false
    }
}

# ============================================================================
#  事件
# ============================================================================
$txtKey.Add_TextChanged({
        $Script:KeyMask = [string]$txtKey.Text
    })

$btnShowKey.Add_Click({
        if ($txtKey.UseSystemPasswordChar) {
            $txtKey.UseSystemPasswordChar = $false
            $btnShowKey.Text = '隐藏'
        } else {
            $txtKey.UseSystemPasswordChar = $true
            $btnShowKey.Text = '显示'
        }
    })

$txtBase.Add_TextChanged({ Invalidate-Caches })

$cmbProtocol.Add_SelectedIndexChanged({
        Invalidate-Caches
        Write-Log ('协议切换为：' + [string]$cmbProtocol.SelectedItem)
    })

$chkNormalize.Add_CheckedChanged({ Invalidate-Caches })

$btnFetch.Add_Click({
        if ($Script:Busy) { return }
        Set-Busy $true '正在获取模型列表…'
        Invalidate-Caches
        Set-Chain @('Fetch')
        $timer.Start()
    })

$btnTestAll.Add_Click({
        if ($Script:Busy) { return }
        Set-Busy $true '准备测试…'
        Set-Chain @('Test:All')
        $timer.Start()
    })

$btnTestSel.Add_Click({
        if ($Script:Busy) { return }
        Set-Busy $true '准备测试…'
        Set-Chain @('Test:Selected')
        $timer.Start()
    })

$btnStop.Add_Click({
        Write-Log '收到 Stop 请求。'
        Set-Chain @()
        try {
            if ($Script:Phase -eq 'Test' -and $null -ne $Script:TestRun) {
                Stop-ApiTestRun -Run $Script:TestRun
            } elseif ($Script:Phase -eq 'Fetch' -and $null -ne $Script:FetchRun) {
                $Script:FetchRun.Stopped = $true
                if ($null -ne $Script:FetchRun.Batch) { [void](Stop-HttpBatch -Batch $Script:FetchRun.Batch) }
            } elseif ($Script:Phase -eq 'Detect' -and $null -ne $Script:DetectRun) {
                [void](Stop-HttpBatch -Batch $Script:DetectRun.Batch)
                $Script:DetectRun.EarlyStopped = $true
            }
        } catch {
            Write-Log ('停止时出错：' + $_.Exception.Message) 'err'
        }
        Set-Status '正在停止…'
    })

$btnCopyModels.Add_Click({
        $rows = @(Get-CurrentResults)
        $ok = @($rows | Where-Object { $_.StatusShort -eq 'OK' })
        $list = @()
        if ($ok.Count -gt 0) {
            $list = @($ok | ForEach-Object { $_.Model })
        } else {
            $list = @($rows | ForEach-Object { $_.Model })
            if ($list.Count -gt 0) { Write-Log '尚无可用的测试结果，改为复制全部模型名。' 'warn' }
        }
        if ($list.Count -eq 0) { Write-Log '没有模型可复制。' 'warn'; return }
        [void](Set-ClipboardSafe -Text ($list -join "`r`n") -What (' ' + $list.Count + ' 个模型'))
    })

$btnCopyReport.Add_Click({
        $rows = @(Get-CurrentResults)
        if ($rows.Count -eq 0) { Write-Log '没有结果可生成报告。' 'warn'; return }
        $rep = Format-ReportTable -Rows $rows -BaseUrl (Get-EffectiveBaseUrl) `
            -Protocol ([string]$cmbProtocol.SelectedItem) -Secret $Script:KeyMask
        $Script:LastReport = $rep
        [void](Set-ClipboardSafe -Text $rep -What '测试报告')
    })

$btnExportCsv.Add_Click({
        $rows = @(Get-CurrentResults)
        if ($rows.Count -eq 0) { Write-Log '没有结果可导出。' 'warn'; return }
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'CSV (*.csv)|*.csv|All files (*.*)|*.*'
        $dlg.FileName = 'api-model-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv'
        $dlg.Title = '导出测试结果（不含 API Key）'
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        try {
            $csv = Get-CsvText -Rows $rows
            [void](Write-Utf8File -Path $dlg.FileName -Text $csv -WithBom)
            Write-Log ('已导出 CSV：' + $dlg.FileName + '（' + $rows.Count + ' 行，不含 API Key）')
        } catch {
            Write-Log ('导出 CSV 失败：' + $_.Exception.Message) 'err'
        }
    })

$btnClear.Add_Click({
        if ($Script:Busy) { Write-Log '测试进行中，请先 Stop。' 'warn'; return }
        if ($grid.IsCurrentCellInEditMode) { [void]$grid.EndEdit() }
        $old = $grid.AllowUserToAddRows
        $grid.AllowUserToAddRows = $false
        try { $grid.Rows.Clear() } catch { }
        $grid.AllowUserToAddRows = $old
        $log.Clear()
        $Script:GridRowByRun = @{}
        $Script:LastReport = ''
        Set-Status '已清空'
        Write-Log '已清空表格与日志。'
    })

$grid.Add_CellContentClick({
        param($s, $e)
        if ($e.ColumnIndex -eq $grid.Columns['Selected'].Index -and -not $grid.Rows[$e.RowIndex].IsNewRow) {
            [void]$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

$grid.Add_CellEndEdit({
        param($s, $e)
        if ($e.ColumnIndex -eq $grid.Columns['Model'].Index) {
            $r = $grid.Rows[$e.RowIndex]
            if (-not $r.IsNewRow) { Reset-GridRowStyle -Row $r }
        }
    })

$grid.Add_SortCompare({
        param($s, $e)
        $name = [string]$grid.Columns[$e.ColumnIndex].Name
        if ($name -eq 'Latency' -or $name -eq 'Ttfb' -or $name -eq 'Http' -or $name -eq 'ReasoningTokens') {
            $a = ConvertTo-SortNumber $grid.Rows[$e.RowIndex1].Cells[$name].Value $name
            $b = ConvertTo-SortNumber $grid.Rows[$e.RowIndex2].Cells[$name].Value $name
            $e.SortResult = 0
            if ($a -lt $b) { $e.SortResult = -1 } elseif ($a -gt $b) { $e.SortResult = 1 }
            $e.Handled = $true
        } elseif ($name -eq 'Status') {
            $a = Get-StatusRankOfRow $grid.Rows[$e.RowIndex1]
            $b = Get-StatusRankOfRow $grid.Rows[$e.RowIndex2]
            $e.SortResult = 0
            if ($a -lt $b) { $e.SortResult = -1 } elseif ($a -gt $b) { $e.SortResult = 1 }
            $e.Handled = $true
        }
    })

$timer.Add_Tick({ Invoke-Tick })
Write-Trace 'handlers wired'

$form.Add_Shown({
        # 被「隐藏窗口」方式拉起时（Launch.vbs 用 WScript.Shell.Run(cmd, 0) 启动，
        # 子进程的 STARTUPINFO.wShowWindow = SW_HIDE），WinForms 主窗口也会被一起藏起来：
        # 进程活着、form shown 也执行了，但窗口看不到（实测 hwnd=0）。
        # 对策：显式做一次 Visible 抖动，强制 ShowWindow。已实测有效。
        if ($Script:ForceShow) {
            try {
                Write-Trace 'ForceShow: toggling form visibility'
                $form.Visible = $false
                Start-Sleep -Milliseconds 60
                $form.Visible = $true
                $form.Activate()
                $form.BringToFront()
                Write-Trace ('ForceShow: done, Visible=' + [string]$form.Visible)
            } catch {
                Write-Trace ('ForceShow failed: ' + [string]$_.Exception.Message)
            }
        }

        try { $split.SplitterDistance = [Math]::Max(240, [int]($split.Height * 0.62)) } catch { }
        Write-Log ('API Model Tester 已启动。解释器：' + $PSVersionTable.PSVersion.ToString() + ' / ' + $PSVersionTable.PSEdition)
        Write-Log ('配置目录：' + (Get-SettingsPath))
        Write-Log '安全说明：API Key 只保存在内存中，不写日志、CSV、报告、配置，也不出现在命令行参数里。'
        Write-Log '默认并发 3 / 超时 30s。先填 Base URL 与 API Key，再点 Fetch Models。'
        if ([string]$txtBase.Text -ne '') { Write-Log '已恢复上次的 Base URL（不含 Key）。' }
        Write-Trace 'form shown'

        # 自检模式：指向本地假服务器（tests\MiniMock.ps1）跑一遍完整流程，
        # 用来验证界面与引擎端到端可用，不涉及任何真实 key。
        if ($Script:AutoDemoUrl -ne '') {
            $txtBase.Text = $Script:AutoDemoUrl
            if ((Get-ApiKeyRaw) -eq '') { $txtKey.Text = 'sk-demo-local-only-not-a-real-key' }
            $cmbProtocol.SelectedIndex = 0
            Write-Log ('自检模式：目标 ' + $Script:AutoDemoUrl + '（本地假服务器），开始 Fetch Models + Test All')
            Set-Busy $true '自检模式运行中…'
            Set-Chain @('Fetch', 'Test:All')
            $timer.Start()
        }
    })

$form.Add_FormClosing({
        try {
            $timer.Stop()
            if ($null -ne $Script:Engine) { Remove-HttpEngine -Engine $Script:Engine }
            $cw = [ordered]@{}
            foreach ($col in $grid.Columns) { $cw[[string]$col.Name] = [int]$col.Width }
            $sx = $form.Location.X
            $sy = $form.Location.Y
            $sw2 = $form.ClientSize.Width
            $sh2 = $form.ClientSize.Height
            if ($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Normal) { $sx = -1; $sy = -1 }
            $out = [ordered]@{
                baseUrl            = [string]$txtBase.Text
                protocol           = [string]$cmbProtocol.SelectedItem
                timeoutSec         = [int]$numTimeout.Value
                concurrency        = [int]$numConc.Value
                normalizeV1        = [bool]$chkNormalize.Checked
                autoTestAfterFetch = [bool]$chkAutoTest.Checked
                window             = [ordered]@{ width = $sw2; height = $sh2; x = $sx; y = $sy }
                columnWidths       = $cw
            }
            [void](Save-AppSettings -Settings $out)
        } catch { }
    })

# ============================================================================
#  启动
# ============================================================================
# headless 自检：把界面构造完整跑一遍但不显示，用于排查「双击没反应」类问题
if ($Script:DiagnoseMode) {
    Write-Trace 'DIAGNOSE: building ui done, dumping state'
    Write-Trace ('DIAGNOSE: form.ClientSize=' + $form.ClientSize.Width + 'x' + $form.ClientSize.Height)
    Write-Trace ('DIAGNOSE: form.Controls=' + $form.Controls.Count + ' grid.Columns=' + $grid.Columns.Count)
    Write-Trace ('DIAGNOSE: protocol items=' + $cmbProtocol.Items.Count + ' selected=' + [string]$cmbProtocol.SelectedItem)
    Write-Trace ('DIAGNOSE: baseUrl restored=' + $(if ([string]$txtBase.Text -ne '') { 'yes' } else { 'no' }))
    Write-Trace ('DIAGNOSE: settings path=' + (Get-SettingsPath))
    Write-Trace ('DIAGNOSE: can save settings=' + (Save-AppSettings -Settings @{ baseUrl = [string]$txtBase.Text }))
    Write-Trace 'DIAGNOSE: OK'
    $form.Dispose()
    return
}

# UI 线程上的未处理异常：写日志 + 友好提示，而不是让 .NET 弹一个看不懂的框
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }
try {
    [System.Windows.Forms.Application]::add_ThreadException({
            param($sender, $e)
            $m = 'unknown'
            try { $m = [string]$e.Exception.Message } catch { }
            Write-Trace ('UI-THREAD-EXCEPTION: ' + $m)
            try { Write-Trace ('UI-THREAD-STACK: ' + ([string]$e.Exception.StackTrace -replace "`r?`n", ' << ')) } catch { }
            try {
                Show-FatalMessage ('界面线程发生未处理异常：' + $m + "`r`n`r`n程序会继续运行，详细信息见：" + $Script:TracePath)
            } catch { }
        })
} catch { }
try {
    [System.AppDomain]::CurrentDomain.add_UnhandledException({
            param($sender, $e)
            $m = 'unknown'
            try { $m = [string]$e.ExceptionObject.GetType().Name + ': ' + [string]$e.ExceptionObject.Message } catch { }
            Write-Trace ('DOMAIN-EXCEPTION: ' + $m)
        })
} catch { }

Write-Trace 'entering message loop'
$Script:Booted = $true
try {
    Set-Busy $false
    Write-Log '正在初始化…'
    [System.Windows.Forms.Application]::Run($form)
    Write-Trace 'message loop exited normally'
} catch {
    $msg = $_.Exception.Message
    Write-Trace ('FATAL(Application.Run): ' + $msg)
    try {
        $dir = Split-Path -Parent (Get-SettingsPath)
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
        [System.IO.File]::WriteAllText((Join-Path $dir 'error.log'),
            ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + $msg + "`r`n" + $_.ScriptStackTrace),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    Show-FatalMessage ('运行失败：' + $msg + "`r`n`r`n诊断日志：" + $Script:TracePath)
}
