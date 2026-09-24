# ============================================================================
#  Core.ps1  -  Api Model Tester 纯函数层
#  职责：URL 规范化、密钥遮挡、错误分类、响应解析、报告/CSV 生成、配置读写
#  约束：不含任何 UI 代码，不发网络请求；可被单元测试直接点源加载
#  Author: Api Model Tester v1.0
# ============================================================================

# ---------------------------------------------------------------- 常量
$Script:AMT_TEST_PROMPT          = 'Reply with exactly: OK'
$Script:AMT_ANTHROPIC_VERSION    = '2023-06-01'
$Script:AMT_USER_AGENT           = 'ApiModelTester/1.0'
$Script:AMT_APP_NAME             = 'Api Model Tester'
$Script:AMT_PROTOCOLS            = @(
    'Auto Detect'
    'OpenAI Chat Completions'
    'OpenAI Responses'
    'Anthropic Messages'
    'OpenAI Compatible'
)

# ---------------------------------------------------------------- 程序集加载
# 说明：本工具刻意不编译任何运行时代码，改用反射加载框架自带程序集。
function Import-NetAssemblies {
    param([string[]]$Name = @(
        'System.Net.Http'
        'System.Net.Http.WebRequest'
        'System.Drawing'
        'System.Windows.Forms'
    ))

    $result = [ordered]@{}
    foreach ($n in $Name) {
        $asm = $null
        # 策略 1：按强名/简单名从当前加载上下文解析（PowerShell 7 / .NET Core 首选）
        try {
            $an = New-Object System.Reflection.AssemblyName($n)
            $asm = [System.Reflection.Assembly]::Load($an)
        } catch { $asm = $null }

        # 策略 2：partial name（.NET Framework / Windows PowerShell 5.1 首选）
        if ($null -eq $asm) {
            try { $asm = [System.Reflection.Assembly]::LoadWithPartialName($n) } catch { $asm = $null }
        }

        # 策略 3：从已知目录按文件加载
        if ($null -eq $asm) {
            $dirs = @()
            if ($PSHOME) { $dirs += $PSHOME }
            $rt = ''
            try { $rt = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory() } catch { }
            if ($rt) { $dirs += $rt }
            $windir = $env:WINDIR
            if (-not $windir) { $windir = 'C:\Windows' }
            foreach ($gac in @("GAC_MSIL", "GAC_32", "GAC_64")) {
                $g = Join-Path $windir ("Microsoft.NET\assembly\$gac\$n")
                if (Test-Path $g) { $dirs += $g }
            }
            foreach ($d in $dirs) {
                if (-not (Test-Path $d)) { continue }
                $hit = $null
                try {
                    $hit = Get-ChildItem -Path $d -Filter "$n.dll" -Recurse -ErrorAction SilentlyContinue |
                           Select-Object -First 1
                } catch { $hit = $null }
                if ($hit) {
                    try { $asm = [System.Reflection.Assembly]::LoadFrom($hit.FullName) } catch { $asm = $null }
                    if ($asm) { break }
                }
            }
        }
        $result[$n] = $asm
    }
    return $result
}

# ---------------------------------------------------------------- 通用小工具
function Get-JsonPath {
    <#
      安全地按点号路径取值：Get-JsonPath $obj 'usage.completion_tokens_details.reasoning_tokens'
      取不到返回 $null（不会抛异常）
    #>
    param($Obj, [string]$Path)
    if ($null -eq $Obj) { return $null }
    if ([string]::IsNullOrEmpty($Path)) { return $Obj }
    $cur = $Obj
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($seg)) { return $null }
            $cur = $cur[$seg]
            continue
        }
        if ($cur -is [string] -or $cur -is [ValueType]) { return $null }
        $prop = $null
        try { $prop = $cur.PSObject.Properties[$seg] } catch { $prop = $null }
        if ($null -eq $prop) { return $null }
        $cur = $prop.Value
    }
    return $cur
}

function Get-JsonIndex {
    param($Arr, [int]$Index)
    if ($null -eq $Arr) { return $null }
    $list = @($Arr)
    if ($Index -lt 0 -or $Index -ge $list.Count) { return $null }
    return $list[$Index]
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t.Length -gt 0 -and [int]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Get-MaskedToken {
    <#  把一段疑似密钥的字符串改写成 sk-abc...xyz 形态  #>
    param([string]$Token)
    if ([string]::IsNullOrEmpty($Token)) { return $Token }
    if ($Token.Length -le 10) {
        return ($Token.Substring(0, [Math]::Min(3, $Token.Length)) + '***')
    }
    return ($Token.Substring(0, 6) + '...' + $Token.Substring($Token.Length - 3))
}

function Mask-Secret {
    <#
      统一出口遮挡：任何要写进日志 / 报告 / CSV / 界面的文本都必须先过这里。
      - 精确替换用户填写的真实 key
      - 兜底替换 sk-xxx / Bearer xxx / api_key: xxx 形态
    #>
    param([string]$Text, [string]$Secret)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $r = $Text

    if (-not [string]::IsNullOrEmpty($Secret) -and $Secret.Length -ge 6) {
        $r = $r.Replace($Secret, (Get-MaskedToken $Secret))
    }
    $r = [regex]::Replace($r, '\bsk-[A-Za-z0-9_\-]{6,}', {
            param($m) Get-MaskedToken $m.Value
        })
    $r = [regex]::Replace($r, '(?i)(bearer\s+)([A-Za-z0-9_\-\.]{12,})', {
            param($m) $m.Groups[1].Value + (Get-MaskedToken $m.Groups[2].Value)
        })
    $r = [regex]::Replace($r, '(?i)("?(?:x-api-key|api[-_]?key|access[-_]?token|authorization|apikey)"?"?\s*[:=]\s*"?)([A-Za-z0-9_\-\.]{12,})', {
            param($m) $m.Groups[1].Value + (Get-MaskedToken $m.Groups[2].Value)
        })
    return $r
}

function Get-DisplayWidth {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Pad-Display {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    $cur = Get-DisplayWidth $Text
    if ($cur -ge $Width) { return $Text }
    return ($Text + (' ' * ($Width - $cur)))
}

function Get-OneLine {
    param([string]$Text, [int]$Max = 0)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = ($Text -replace '[\r\n\t]+', ' ')
    $t = ($t -replace '\s{2,}', ' ')
    $t = $t.Trim()
    if ($Max -gt 0 -and $t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '...' }
    return $t
}

function Write-Utf8File {
    <#
      确定性的 UTF-8 写文件（不依赖编码对象是否带 BOM 的隐式行为）。
      -WithBom 用于 CSV（Excel 友好）；其余一律无 BOM。
    #>
    param(
        [string]$Path,
        [string]$Text,
        [switch]$WithBom
    )

    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    if ($WithBom) {
        $bom = [byte[]]@(0xEF, 0xBB, 0xBF)
        $out = New-Object byte[] ($bytes.Length + 3)
        [System.Array]::Copy($bom, 0, $out, 0, 3)
        [System.Array]::Copy($bytes, 0, $out, 3, $bytes.Length)
        [System.IO.File]::WriteAllBytes($Path, $out)
    } else {
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }
    return $true
}

# ---------------------------------------------------------------- URL 规范化
function Test-UrlHasScheme {
    param([string]$Text)
    return [bool]($Text -match '^[a-zA-Z][a-zA-Z0-9+.\-]*://')
}

function Expand-BaseUrl {
    <#
      把用户随便填的 Base URL 收敨成规范根地址：
        example.com                     -> https://example.com
        https://abc.com/                -> https://abc.com
        https://abc.com/v1/             -> https://abc.com/v1
        https://abc.com/v1/models       -> https://abc.com            (剥掉粘贴进来的端点)
        https://abc.com/openai/v1/chat/completions -> https://abc.com/openai
        https://abc.com?x=1#y           -> https://abc.com            (去掉 query / fragment)
    #>
    param([string]$BaseUrl)

    $b = ''
    if ($null -ne $BaseUrl) { $b = $BaseUrl.Trim() }
    if ($b -eq '') { return '' }
    if (-not (Test-UrlHasScheme $b)) { $b = 'https://' + $b }

    $i = $b.IndexOf('?'); if ($i -ge 0) { $b = $b.Substring(0, $i) }
    $i = $b.IndexOf('#'); if ($i -ge 0) { $b = $b.Substring(0, $i) }
    while ($b.EndsWith('/')) { $b = $b.Substring(0, $b.Length - 1) }

    # 剥掉误粘贴的完整端点（最多带一层版本段，如 /v1/models）
    $m = [regex]::Match($b, '(?i)/(?:[a-z0-9._\-]+/)?(?:chat/completions|responses|messages|models|completions)$')
    if ($m.Success -and $m.Index -gt 0) {
        $cand = $b.Substring(0, $m.Index).TrimEnd('/')
        if ($cand -match '://[^/]+' -and $cand.Length -gt ($cand.IndexOf('://') + 3)) { $b = $cand }
    }
    return $b
}

function Resolve-ApiUrl {
    <#
      安全拼路径：Normalize 打开时保证不会出现 /v1/v1/...
      BaseUrl=https://abc.com/v1  Path=/v1/models  ->  https://abc.com/v1/models
      BaseUrl=https://abc.com     Path=/v1/models  ->  https://abc.com/v1/models
    #>
    param(
        [string]$BaseUrl,
        [string]$Path,
        [switch]$Normalize
    )

    $b = Expand-BaseUrl $BaseUrl
    if ($b -eq '') { return '' }

    $p = '/' + $Path.Trim()
    while ($p.StartsWith('//')) { $p = $p.Substring(1) }
    if (-not $p.StartsWith('/')) { $p = '/' + $p }

    if ($Normalize) {
        $guard = 0
        while ($guard -lt 8) {
            $guard++
            $si = $p.IndexOf('/', 1)
            if ($si -lt 0) { break }
            $seg = $p.Substring(1, $si - 1)
            $lastSlash = $b.LastIndexOf('/')
            $bseg = ''
            if ($lastSlash -ge 0) { $bseg = $b.Substring($lastSlash + 1) }
            if ($bseg -ne '' -and $seg -ne '' -and ($bseg -ieq $seg)) {
                $p = $p.Substring($si)
            } else {
                break
            }
        }
    }
    return ($b + $p)
}

function Get-ApiCandidates {
    <#
      按协议种类给出候选端点（顺序 = 探测优先级），已去重
    #>
    param(
        [string]$BaseUrl,
        [ValidateSet('Models', 'Chat', 'Responses', 'Messages')]
        [string]$Kind,
        [switch]$Normalize
    )

    $paths = @()
    switch ($Kind) {
        'Models'    { $paths = @('/v1/models', '/models') }
        'Chat'      { $paths = @('/v1/chat/completions', '/chat/completions') }
        'Responses' { $paths = @('/v1/responses', '/responses') }
        'Messages'  { $paths = @('/v1/messages', '/messages') }
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $paths) {
        $u = Resolve-ApiUrl -BaseUrl $BaseUrl -Path $p -Normalize:$Normalize
        if ($u -ne '' -and -not $out.Contains($u)) { $out.Add($u) }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------- 请求构造
function Get-ProtocolKind {
    param([string]$Protocol)
    switch ($Protocol) {
        'OpenAI Chat Completions' { return 'Chat' }
        'OpenAI Responses'        { return 'Responses' }
        'Anthropic Messages'      { return 'Messages' }
        'OpenAI Compatible'       { return 'Compatible' }
        default                   { return 'Auto' }
    }
}

function Get-ProtocolDisplayName {
    param([string]$Kind)
    switch ($Kind) {
        'Chat'       { return 'Chat' }
        'Compatible' { return 'Compatible' }
        'Responses'  { return 'Responses' }
        'Messages'   { return 'Anthropic' }
        default      { return [string]$Kind }
    }
}

function New-TestBody {
    param(
        [string]$Kind,
        [string]$Model,
        [switch]$UseMaxCompletionTokens,
        [switch]$AnthropicBearer
    )

    $m = $Model
    switch ($Kind) {
        'Chat' {
            $field = 'max_tokens'
            if ($UseMaxCompletionTokens) { $field = 'max_completion_tokens' }
            return ('{"model":' + (ConvertTo-JsonString $m) +
                    ',"messages":[{"role":"user","content":' + (ConvertTo-JsonString $Script:AMT_TEST_PROMPT) + '}]' +
                    ',"' + $field + '":8}')
        }
        'Compatible' {
            return ('{"model":' + (ConvertTo-JsonString $m) +
                    ',"messages":[{"role":"user","content":' + (ConvertTo-JsonString $Script:AMT_TEST_PROMPT) + '}],' +
                    '"max_tokens":8}')
        }
        'Responses' {
            return ('{"model":' + (ConvertTo-JsonString $m) +
                    ',"input":' + (ConvertTo-JsonString $Script:AMT_TEST_PROMPT) + '}')
        }
        'Messages' {
            return ('{"model":' + (ConvertTo-JsonString $m) +
                    ',"max_tokens":8,"messages":[{"role":"user","content":' +
                    (ConvertTo-JsonString $Script:AMT_TEST_PROMPT) + '}]}')
        }
        default { return '' }
    }
}

function ConvertTo-JsonString {
    param([string]$Text)
    if ($null -eq $Text) { return '""' }
    $s = $Text
    $s = $s.Replace('\', '\\')
    $s = $s.Replace('"', '\"')
    $s = $s.Replace("`r", '\r')
    $s = $s.Replace("`n", '\n')
    $s = $s.Replace("`t", '\t')
    return ('"' + $s + '"')
}

function Get-RequestHeaders {
    <#
      返回 @( @{ Name='...'; Value='...' }, ... )
      Anthropic 用 x-api-key，其余用 Authorization: Bearer
      -AnthropicCompat：额外附上 x-api-key / anthropic-version。
      只用于「还不知道对端是什么协议」的取模型列表请求；多带一个头对
      OpenAI 兼容站是无害的，但能让只认 x-api-key 的站点也能列出模型。
    #>
    param(
        [string]$Kind,
        [string]$ApiKey,
        [switch]$AnthropicBearer,
        [switch]$AnthropicCompat
    )

    $h = New-Object System.Collections.Generic.List[hashtable]
    if ($Kind -eq 'Messages') {
        $h.Add(@{ Name = 'x-api-key';           Value = $ApiKey })
        $h.Add(@{ Name = 'anthropic-version';   Value = $Script:AMT_ANTHROPIC_VERSION })
        $h.Add(@{ Name = 'content-type';        Value = 'application/json' })
        $h.Add(@{ Name = 'accept';              Value = 'application/json' })
        if ($AnthropicBearer) { $h.Add(@{ Name = 'authorization'; Value = 'Bearer ' + $ApiKey }) }
    } else {
        $h.Add(@{ Name = 'authorization'; Value = 'Bearer ' + $ApiKey })
        $h.Add(@{ Name = 'content-type';  Value = 'application/json' })
        $h.Add(@{ Name = 'accept';        Value = 'application/json' })
        if ($AnthropicCompat) {
            $h.Add(@{ Name = 'x-api-key';         Value = $ApiKey })
            $h.Add(@{ Name = 'anthropic-version'; Value = $Script:AMT_ANTHROPIC_VERSION })
        }
    }
    return $h.ToArray()
}

# ---------------------------------------------------------------- 错误分类
function Get-ExceptionChain {
    param($Exception)
    $out = New-Object System.Collections.Generic.List[object]
    $e = $Exception
    $guard = 0
    while ($null -ne $e -and $guard -lt 10) {
        $guard++
        $out.Add($e)
        $e = $e.InnerException
    }
    return $out.ToArray()
}

function Get-UnwrappedException {
    <# PowerShell 会把异常包进 MethodInvocationException / RuntimeException，取到最内层真实异常 #>
    param($Exception)
    $chain = Get-ExceptionChain $Exception
    $best = $chain[0]
    foreach ($e in $chain) {
        $n = $e.GetType().Name
        if ($n -eq 'NullReferenceException' -or $n -eq 'MethodInvocationException' -or
            $n -eq 'RuntimeException' -or $n -eq 'CmdletInvocationException') { continue }
        $best = $e
    }
    return $best
}

function Classify-NetworkError {
    <#
      返回 @{ Type='Timeout'|'DNS'|'TLS'|'Network'|'Cancelled'|'Error'; Message='人类可读原因' }
    #>
    param($Exception)

    $chain = Get-ExceptionChain $Exception
    $msg = ''
    foreach ($e in $chain) { if ($e.Message) { $msg = $e.Message } }

    foreach ($e in $chain) {
        $tn = $e.GetType().Name
        if ($tn -eq 'TaskCanceledException' -or $tn -eq 'OperationCanceledException') {
            # 交给上层用 reason 判定，这里给兜底
            continue
        }
        if ($tn -eq 'SocketException') {
            $code = ''
            try { $code = [string]$e.SocketErrorCode } catch { $code = '' }
            if ($code -match 'HostNotFound|NoData|TryAgain|NoRecovery') {
                return @{ Type = 'DNS'; Message = ('DNS 解析失败: ' + $e.Message) }
            }
            return @{ Type = 'Network'; Message = ($code + ' ' + $e.Message).Trim() }
        }
        if ($tn -eq 'AuthenticationException') {
            return @{ Type = 'TLS'; Message = ('TLS/证书错误: ' + $e.Message) }
        }
        if ($tn -eq 'WebException') {
            $st = ''
            try { $st = [string]$e.Status } catch { $st = '' }
            switch -Regex ($st) {
                'NameResolutionFailure|ProxyNameResolutionFailure' { return @{ Type = 'DNS'; Message = ('DNS 解析失败: ' + $e.Message) } }
                'TrustFailure'                                     { return @{ Type = 'TLS'; Message = ('TLS/证书错误: ' + $e.Message) } }
                'Timeout'                                          { return @{ Type = 'Timeout'; Message = '本地超时' } }
                'ConnectFailure'                                   { return @{ Type = 'Network'; Message = ('连接失败: ' + $e.Message) } }
            }
        }
    }

    foreach ($e in $chain) {
        $tn = $e.GetType().Name
        $m = [string]$e.Message
        if ($tn -eq 'HttpRequestException') {
            if ($m -match '(?i)name or service not known|could not resolve|nodename|host|no such host') {
                return @{ Type = 'DNS'; Message = ('DNS 解析失败: ' + $m) }
            }
            if ($m -match '(?i)ssl|tls|certificate|authentication') {
                return @{ Type = 'TLS'; Message = ('TLS/证书错误: ' + $m) }
            }
            if ($m -match '(?i)timed out|timeout') {
                return @{ Type = 'Timeout'; Message = '本地超时' }
            }
            return @{ Type = 'Network'; Message = $m }
        }
    }

    return @{ Type = 'Error'; Message = $msg }
}

function Get-StatusFromHttpCode {
    param([int]$Http)

    $map = @{
        400 = @{ Status = 'Bad Request / protocol compatibility'; Short = 'BadRequest';   Rank = 30 }
        401 = @{ Status = 'Authentication Failed';                 Short = 'AuthFail';    Rank = 31 }
        402 = @{ Status = 'Payment Required / quota';              Short = 'Payment';     Rank = 32 }
        403 = @{ Status = 'Forbidden / permission or protocol issue'; Short = 'Forbidden'; Rank = 33 }
        404 = @{ Status = 'Endpoint or model not found';           Short = 'NotFound';    Rank = 34 }
        405 = @{ Status = 'Method Not Allowed';                    Short = 'MethodNA';    Rank = 35 }
        406 = @{ Status = 'Not Acceptable';                        Short = 'NotAccept';   Rank = 36 }
        408 = @{ Status = 'Request Timeout';                       Short = 'Timeout';     Rank = 37 }
        409 = @{ Status = 'Conflict';                              Short = 'Conflict';    Rank = 38 }
        413 = @{ Status = 'Payload Too Large';                     Short = 'TooLarge';    Rank = 39 }
        415 = @{ Status = 'Unsupported Media Type';                Short = 'MediaType';   Rank = 40 }
        422 = @{ Status = 'Unprocessable Entity / protocol compatibility'; Short = 'Unprocessable'; Rank = 41 }
        429 = @{ Status = 'Rate Limited / quota exhausted';        Short = 'RateLimit';   Rank = 50 }
        500 = @{ Status = 'Server Error';                          Short = 'ServerErr';   Rank = 60 }
        501 = @{ Status = 'Not Implemented';                       Short = 'NotImpl';     Rank = 61 }
        502 = @{ Status = 'Bad Gateway';                           Short = 'BadGateway';  Rank = 62 }
        503 = @{ Status = 'Service Unavailable';                   Short = 'Unavailable'; Rank = 63 }
        504 = @{ Status = 'Gateway Timeout';                       Short = 'GWTimeout';   Rank = 64 }
        520 = @{ Status = 'Cloudflare Unknown Error';              Short = 'CF520';       Rank = 65 }
        522 = @{ Status = 'Connection Timed Out (edge)';           Short = 'CF522';       Rank = 66 }
        524 = @{ Status = 'Upstream Timeout';                      Short = 'UpstreamTO';  Rank = 67 }
    }

    if ($map.ContainsKey($Http)) {
        $v = $map[$Http]
        return @{ Status = $v.Status; Short = $v.Short; Rank = $v.Rank; Class = 'http' }
    }
    if ($Http -ge 500) { return @{ Status = ('Server Error (HTTP ' + $Http + ')'); Short = ('HTTP' + $Http); Rank = 68; Class = 'http' } }
    if ($Http -ge 400) { return @{ Status = ('Client Error (HTTP ' + $Http + ')'); Short = ('HTTP' + $Http); Rank = 45; Class = 'http' } }
    return @{ Status = ('Unexpected HTTP ' + $Http); Short = ('HTTP' + $Http); Rank = 69; Class = 'http' }
}

function Get-RemoteErrorText {
    <#  尽量把服务器返回的 error.message 原样抠出来，不吞掉  #>
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
    $t = $Body.Trim()
    if ($t.StartsWith('{') -or $t.StartsWith('[')) {
        $o = ConvertFrom-JsonSafe $t
        if ($null -ne $o -and -not ($o -is [string])) {
            foreach ($p in @('error.message', 'error.detail', 'error.msg', 'error_description',
                             'error', 'message', 'detail', 'msg', 'reason')) {
                $v = Get-JsonPath $o $p
                if ($v -is [string] -and $v.Trim() -ne '') { return $v.Trim() }
                if ($null -ne $v -and -not ($v -is [string])) {
                    $s = (Get-JsonPath $v 'message')
                    if ($s -is [string] -and $s.Trim() -ne '') { return $s.Trim() }
                }
            }
        }
    }
    return (Get-OneLine $t 300)
}

# ---------------------------------------------------------------- 响应解析
function New-TestResult {
    return [ordered]@{
        Content         = ''
        ReasoningText   = ''
        ReturnedModel   = ''
        FinishReason    = ''
        ReasoningTokens = $null
        PromptTokens    = $null
        CompletionTokens = $null
        TotalTokens     = $null
        HasError        = $false
        RemoteError     = ''
        Streaming       = $false
        SseDeltas       = 0
        SseDone         = $false
        Schema          = 'ok'
        Notes           = @()
    }
}

function Test-IsSse {
    param([string]$Body, [string]$ContentType)
    if ($ContentType -and $ContentType -match '(?i)text/event-stream') { return $true }
    if ([string]::IsNullOrEmpty($Body)) { return $false }
    $t = $Body.TrimStart()
    return [bool]($t.StartsWith('data:') -or $t.StartsWith('event:'))
}

function Get-SseSummary {
    <#  兜底解析流式响应：兼容 OpenAI delta / Anthropic delta / Responses 事件  #>
    param([string]$Body)

    $text = New-Object System.Text.StringBuilder
    $reason = New-Object System.Text.StringBuilder
    $deltas = 0; $done = $false; $bad = 0; $finish = ''

    foreach ($line in ($Body -split "`r?`n")) {
        $l = $line.Trim()
        if ($l.Length -eq 0 -or -not $l.StartsWith('data:')) { continue }
        $payload = $l.Substring(5).Trim()
        if ($payload -eq '[DONE]') { $done = $true; continue }
        $o = ConvertFrom-JsonSafe $payload
        if ($null -eq $o -or -not ($o -is [System.Management.Automation.PSCustomObject])) { $bad++; continue }
        $deltas++
        $t = $null; $rt = $null

        $choices = Get-JsonPath $o 'choices'
        if ($null -ne $choices) {
            $c0 = Get-JsonIndex $choices 0
            if ($null -ne $c0) {
                $dl = Get-JsonPath $c0 'delta'
                if ($null -ne $dl) {
                    $t = Get-JsonPath $dl 'content'
                    $rt = Get-JsonPath $dl 'reasoning_content'
                    if ($null -eq $rt) { $rt = Get-JsonPath $dl 'reasoning' }
                }
                if ($null -eq $t) { $t = Get-JsonPath $c0 'message.content' }
                $fr = Get-JsonPath $c0 'finish_reason'
                if ($fr) { $finish = [string]$fr }
            }
        } else {
            $ty = [string](Get-JsonPath $o 'type')
            $dl = Get-JsonPath $o 'delta'
            switch ($ty) {
                'content_block_delta' { if ($dl) { $t = Get-JsonPath $dl 'text'; if ($null -eq $t) { $t = Get-JsonPath $dl 'thinking' } } }
                'response.output_text.delta' { if ($null -ne $dl) { $t = $dl } }
                'response.reasoning_summary_text.delta' { if ($null -ne $dl) { $rt = $dl } }
                default {
                    if ($dl) {
                        if ($dl -is [string]) { $t = $dl }
                        else {
                            $t = Get-JsonPath $dl 'text'
                            if ($null -eq $t) { $t = Get-JsonPath $dl 'content' }
                        }
                    }
                }
            }
        }
        if ($t -is [string] -and $t -ne '') { [void]$text.Append($t) }
        if ($rt -is [string] -and $rt -ne '') { [void]$reason.Append($rt) }
    }

    return @{
        Text      = $text.ToString()
        Reasoning = $reason.ToString()
        Deltas    = $deltas
        Done      = $done
        BadLines  = $bad
        Finish    = $finish
    }
}

function Read-ChatResult {
    param([string]$Body, [string]$ContentType, [switch]$Loose)

    $r = New-TestResult
    if (Test-IsSse $Body $ContentType) {
        $s = Get-SseSummary $Body
        $r.Streaming = $true
        $r.SseDeltas = $s.Deltas
        $r.SseDone = $s.Done
        $r.FinishReason = $s.Finish
        $r.Content = $s.Text
        $r.ReasoningText = $s.Reasoning
        if ($s.BadLines -gt 0) { $r.Notes += ('SSE 中有 ' + $s.BadLines + ' 行无法解析') }
        if (-not $s.Text -and -not $s.Reasoning) {
            $r.Schema = 'sse-empty'
            $r.Notes += 'SSE 响应未包含任何文本'
        }
        return $r
    }

    $o = ConvertFrom-JsonSafe $Body
    if ($null -eq $o -or -not ($o -is [System.Management.Automation.PSCustomObject])) {
        $r.Schema = 'unparsable'
        $r.Notes += '响应不是合法 JSON'
        return $r
    }

    $err = Get-JsonPath $o 'error'
    if ($null -ne $err) {
        $r.HasError = $true
        $r.RemoteError = (Get-RemoteErrorText $Body)
        $r.Schema = 'error'
    }

    $r.ReturnedModel = [string](Get-JsonPath $o 'model')

    $choices = Get-JsonPath $o 'choices'
    if ($null -eq $choices) {
        $r.Schema = 'no-choices'
        $r.Notes += '响应缺少 choices 字段'
        $direct = Get-JsonPath $o 'content'
        if ($direct -is [string]) { $r.Content = $direct }
    } else {
        $c0 = Get-JsonIndex $choices 0
        if ($null -eq $c0) {
            $r.Schema = 'no-choices'
            $r.Notes += 'choices 为空'
        } else {
            $r.FinishReason = [string](Get-JsonPath $c0 'finish_reason')
            $content = Get-JsonPath $c0 'message.content'
            if ($null -eq $content) { $content = Get-JsonPath $c0 'text' }
            if ($content -is [string]) {
                $r.Content = $content
            } elseif ($null -ne $content) {
                foreach ($part in @($content)) {
                    $tx = Get-JsonPath $part 'text'
                    if ($null -eq $tx) { $tx = $part }
                    if ($tx -is [string]) { $r.Content += $tx }
                }
            }
            $rc = Get-JsonPath $c0 'message.reasoning_content'
            if ($null -eq $rc) { $rc = Get-JsonPath $c0 'message.reasoning' }
            if ($null -eq $rc) { $rc = Get-JsonPath $c0 'message.thinking' }
            if ($rc -is [string]) { $r.ReasoningText = $rc }
        }
    }

    $u = Get-JsonPath $o 'usage'
    if ($null -ne $u) {
        $r.PromptTokens = Get-JsonPath $u 'prompt_tokens'
        $r.CompletionTokens = Get-JsonPath $u 'completion_tokens'
        $r.TotalTokens = Get-JsonPath $u 'total_tokens'
        $rt = Get-JsonPath $u 'completion_tokens_details.reasoning_tokens'
        if ($null -eq $rt) { $rt = Get-JsonPath $u 'output_tokens_details.reasoning_tokens' }
        if ($null -eq $rt) { $rt = Get-JsonPath $u 'reasoning_tokens' }
        if ($null -ne $rt) {
            try { $r.ReasoningTokens = [int]$rt } catch { $r.ReasoningTokens = $null }
        }
    }
    return $r
}

function Read-ResponsesResult {
    param([string]$Body, [string]$ContentType)

    $r = New-TestResult
    if (Test-IsSse $Body $ContentType) {
        $s = Get-SseSummary $Body
        $r.Streaming = $true
        $r.SseDeltas = $s.Deltas
        $r.SseDone = $s.Done
        $r.Content = $s.Text
        $r.ReasoningText = $s.Reasoning
        if (-not $s.Text -and -not $s.Reasoning) {
            $r.Schema = 'sse-empty'
            $r.Notes += 'SSE 响应未包含任何文本'
        }
        return $r
    }

    $o = ConvertFrom-JsonSafe $Body
    if ($null -eq $o -or -not ($o -is [System.Management.Automation.PSCustomObject])) {
        $r.Schema = 'unparsable'
        $r.Notes += '响应不是合法 JSON'
        return $r
    }

    if ($null -ne (Get-JsonPath $o 'error')) {
        $r.HasError = $true
        $r.RemoteError = (Get-RemoteErrorText $Body)
        $r.Schema = 'error'
    }

    $r.ReturnedModel = [string](Get-JsonPath $o 'model')
    $status = [string](Get-JsonPath $o 'status')
    $incomplete = [string](Get-JsonPath $o 'incomplete_details.reason')
    $r.FinishReason = $status
    if ($incomplete) { $r.FinishReason = $status + '/' + $incomplete }

    $ot = Get-JsonPath $o 'output_text'
    if ($ot -is [string]) { $r.Content = $ot }

    $items = Get-JsonPath $o 'output'
    if ($null -ne $items) {
        foreach ($item in @($items)) {
            $ty = [string](Get-JsonPath $item 'type')
            if ($ty -eq 'message' -or $ty -eq 'output_text') {
                $parts = Get-JsonPath $item 'content'
                if ($null -eq $parts -and $ty -eq 'output_text') {
                    $tx = Get-JsonPath $item 'text'
                    if ($tx -is [string]) { $r.Content += $tx }
                } else {
                    foreach ($p in @($parts)) {
                        $pty = [string](Get-JsonPath $p 'type')
                        if ($pty -eq 'output_text' -or $pty -eq 'text' -or $pty -eq '') {
                            $tx = Get-JsonPath $p 'text'
                            if ($tx -is [string]) { $r.Content += $tx }
                        }
                    }
                }
            } elseif ($ty -eq 'reasoning') {
                $parts = Get-JsonPath $item 'content'
                foreach ($p in @($parts)) {
                    $tx = Get-JsonPath $p 'text'
                    if ($tx -is [string]) { $r.ReasoningText += $tx }
                }
                $sm = Get-JsonPath $item 'summary'
                foreach ($p in @($sm)) {
                    $tx = Get-JsonPath $p 'text'
                    if ($tx -is [string]) { $r.ReasoningText += $tx }
                }
            }
        }
    }
    if ($null -eq $items -and -not $r.Content) {
        $r.Schema = 'no-output'
        $r.Notes += '响应缺少 output 字段'
    }

    $u = Get-JsonPath $o 'usage'
    if ($null -ne $u) {
        $r.PromptTokens = Get-JsonPath $u 'input_tokens'
        $r.CompletionTokens = Get-JsonPath $u 'output_tokens'
        $r.TotalTokens = Get-JsonPath $u 'total_tokens'
        $rt = Get-JsonPath $u 'output_tokens_details.reasoning_tokens'
        if ($null -eq $rt) { $rt = Get-JsonPath $u 'completion_tokens_details.reasoning_tokens' }
        if ($null -ne $rt) {
            try { $r.ReasoningTokens = [int]$rt } catch { $r.ReasoningTokens = $null }
        }
    }
    return $r
}

function Read-AnthropicResult {
    param([string]$Body, [string]$ContentType)

    $r = New-TestResult
    if (Test-IsSse $Body $ContentType) {
        $s = Get-SseSummary $Body
        $r.Streaming = $true
        $r.SseDeltas = $s.Deltas
        $r.SseDone = $s.Done
        $r.FinishReason = $s.Finish
        $r.Content = $s.Text
        $r.ReasoningText = $s.Reasoning
        if (-not $s.Text -and -not $s.Reasoning) {
            $r.Schema = 'sse-empty'
            $r.Notes += 'SSE 响应未包含任何文本'
        }
        return $r
    }

    $o = ConvertFrom-JsonSafe $Body
    if ($null -eq $o -or -not ($o -is [System.Management.Automation.PSCustomObject])) {
        $r.Schema = 'unparsable'
        $r.Notes += '响应不是合法 JSON'
        return $r
    }

    $ty = [string](Get-JsonPath $o 'type')
    $err = Get-JsonPath $o 'error'
    if ($null -ne $err -or $ty -eq 'error') {
        $r.HasError = $true
        $r.RemoteError = (Get-RemoteErrorText $Body)
        $r.Schema = 'error'
    }

    $r.ReturnedModel = [string](Get-JsonPath $o 'model')
    $r.FinishReason = [string](Get-JsonPath $o 'stop_reason')
    if ([string]::IsNullOrEmpty($r.FinishReason)) { $r.FinishReason = [string](Get-JsonPath $o 'stop_sequence') }

    $blocks = Get-JsonPath $o 'content'
    if ($blocks -is [string]) {
        $r.Content = $blocks
    } elseif ($null -ne $blocks) {
        foreach ($b in @($blocks)) {
            $bty = [string](Get-JsonPath $b 'type')
            if ($bty -eq 'text') {
                $tx = Get-JsonPath $b 'text'
                if ($tx -is [string]) { $r.Content += $tx }
            } elseif ($bty -eq 'thinking') {
                $tx = Get-JsonPath $b 'thinking'
                if ($tx -is [string]) { $r.ReasoningText += $tx }
            } elseif ($bty -eq 'redacted_thinking') {
                $r.Notes += '返回 redacted_thinking 块（无明文内容）'
            } elseif ($bty -eq 'tool_use') {
                $r.Notes += '返回 tool_use 块，无文本输出'
            }
        }
    } else {
        $r.Schema = 'no-content'
        $r.Notes += '响应缺少 content 字段'
    }

    $u = Get-JsonPath $o 'usage'
    if ($null -ne $u) {
        $r.PromptTokens = Get-JsonPath $u 'input_tokens'
        $r.CompletionTokens = Get-JsonPath $u 'output_tokens'
        $r.TotalTokens = Get-JsonPath $u 'total_tokens'
        $rt = Get-JsonPath $u 'output_tokens_details.reasoning_tokens'
        if ($null -ne $rt) {
            try { $r.ReasoningTokens = [int]$rt } catch { $r.ReasoningTokens = $null }
        }
    }
    return $r
}

function Read-ApiResult {
    param([string]$Kind, [string]$Body, [string]$ContentType)
    switch ($Kind) {
        'Messages'   { return (Read-AnthropicResult -Body $Body -ContentType $ContentType) }
        'Responses'  { return (Read-ResponsesResult -Body $Body -ContentType $ContentType) }
        'Compatible' { return (Read-ChatResult -Body $Body -ContentType $ContentType -Loose) }
        default      { return (Read-ChatResult -Body $Body -ContentType $ContentType) }
    }
}

function Get-TestVerdict {
    <#
      HTTP 200 / Compatibility Warning / 各类错误 的人类可读判定
      返回 @{ Status; Short; Rank; Class; Detail }
    #>
    param(
        $Result,
        [int]$Http,
        [string]$ErrorType = '',
        [string]$ErrorMessage = '',
        [string]$Kind = 'Chat',
        [switch]$Loose
    )

    if ($Http -le 0) {
        switch ($ErrorType) {
            'Timeout'   { return @{ Status = 'Timeout';       Short = 'Timeout';   Rank = 80; Class = 'timeout'; Detail = '本地超时（未在 Timeout 内完成）' } }
            'Cancelled' { return @{ Status = 'Cancelled';     Short = 'Cancelled'; Rank = 95; Class = 'cancelled'; Detail = '用户中止' } }
            'DNS'       { return @{ Status = 'DNS Error';     Short = 'DNS';       Rank = 90; Class = 'net'; Detail = $ErrorMessage } }
            'TLS'       { return @{ Status = 'TLS Error';     Short = 'TLS';       Rank = 91; Class = 'net'; Detail = $ErrorMessage } }
            'Network'   { return @{ Status = 'Network Error'; Short = 'Network';   Rank = 92; Class = 'net'; Detail = $ErrorMessage } }
            default     { return @{ Status = 'Request Error'; Short = 'Error';     Rank = 93; Class = 'net'; Detail = $ErrorMessage } }
        }
    }

    if ($Http -ne 200) {
        $s = Get-StatusFromHttpCode $Http
        $detail = ''
        if ($null -ne $Result) { $detail = $Result.RemoteError }
        if ([string]::IsNullOrEmpty($detail)) { $detail = $ErrorMessage }
        return @{ Status = $s.Status; Short = $s.Short; Rank = $s.Rank; Class = $s.Class; Detail = $detail }
    }

    # ---- HTTP 200：还要看内容是否真的可用 ----
    if ($null -eq $Result) {
        return @{ Status = 'Compatibility Warning'; Short = 'Warn'; Rank = 10; Class = 'warn'; Detail = 'HTTP 200 但无解析结果' }
    }
    if ($Result.HasError) {
        return @{ Status = 'Compatibility Warning'; Short = 'Warn'; Rank = 10; Class = 'warn'; Detail = ('HTTP 200 但返回 error 对象: ' + $Result.RemoteError) }
    }

    $hasContent = -not [string]::IsNullOrWhiteSpace($Result.Content)
    $hasReason = -not [string]::IsNullOrWhiteSpace($Result.ReasoningText)

    if (-not $hasContent -and -not $hasReason) {
        $d = 'HTTP 200 但 content 为空'
        if ($Result.Notes.Count -gt 0) { $d += ' (' + ($Result.Notes -join '; ') + ')' }
        return @{ Status = 'Compatibility Warning'; Short = 'Warn'; Rank = 10; Class = 'warn'; Detail = $d }
    }
    if (-not $hasContent -and $hasReason) {
        return @{ Status = 'Compatibility Warning'; Short = 'Warn'; Rank = 11; Class = 'warn'; Detail = '只有 reasoning / thinking 内容，没有最终 content' }
    }
    if ($Result.Schema -ne 'ok' -and -not $Loose) {
        return @{ Status = 'Compatibility Warning'; Short = 'Warn'; Rank = 12; Class = 'warn'; Detail = ('响应结构异常: ' + $Result.Schema + ' (' + ($Result.Notes -join '; ') + ')') }
    }
    if ($Result.Streaming -and -not $Result.SseDone -and $Kind -ne 'Messages') {
        return @{ Status = 'OK (stream incomplete)'; Short = 'OK'; Rank = 9; Class = 'warn'; Detail = 'SSE 流没有 [DONE] 结束标记' }
    }
    return @{ Status = 'OK'; Short = 'OK'; Rank = 0; Class = 'ok'; Detail = '' }
}

# ---------------------------------------------------------------- 模型列表解析
function Read-ModelList {
    <#
      解析各种 /models 返回形态
      返回 @{ Ok; Models=@(); Count; Format; Error }
    #>
    param([string]$Body)

    $res = @{ Ok = $false; Models = @(); Count = 0; Format = ''; Error = '' }
    $o = ConvertFrom-JsonSafe $Body
    if ($null -eq $o) {
        $res.Error = '响应不是合法 JSON'
        return $res
    }

    $ids = New-Object System.Collections.Generic.List[string]
    $format = ''

    if ($o -is [System.Management.Automation.PSCustomObject]) {
        if ($null -ne (Get-JsonPath $o 'error')) {
            $res.Error = (Get-RemoteErrorText $Body)
            return $res
        }
        $arr = Get-JsonPath $o 'data'
        if ($null -eq $arr) { $arr = Get-JsonPath $o 'models' }
        if ($null -eq $arr) { $arr = Get-JsonPath $o 'result' }
        if ($null -ne $arr) {
            $format = 'list-object'
            foreach ($it in @($arr)) {
                if ($it -is [string]) { if ($it.Trim()) { $ids.Add($it.Trim()) }; continue }
                $id = Get-JsonPath $it 'id'
                if ($null -eq $id) { $id = Get-JsonPath $it 'name' }
                if ($null -eq $id) { $id = Get-JsonPath $it 'model' }
                if ($null -eq $id) { $id = Get-JsonPath $it 'slug' }
                if ($id -is [string] -and $id.Trim() -ne '') { $ids.Add($id.Trim()) }
            }
        }
    } elseif ($o -is [System.Array] -or $o -is [System.Collections.IEnumerable]) {
        $format = 'bare-array'
        foreach ($it in @($o)) {
            if ($it -is [string]) { if ($it.Trim()) { $ids.Add($it.Trim()) }; continue }
            $id = Get-JsonPath $it 'id'
            if ($null -eq $id) { $id = Get-JsonPath $it 'name' }
            if ($id -is [string] -and $id.Trim() -ne '') { $ids.Add($id.Trim()) }
        }
    }

    if ($ids.Count -eq 0) {
        if ($format -eq '') { $res.Error = '响应里找不到模型列表字段 (data/models)' }
        else { $res.Error = '模型列表为空' }
        return $res
    }

    $uniq = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($id in $ids) {
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $uniq.Add($id) }
    }
    $sorted = $uniq.ToArray()
    [System.Array]::Sort($sorted, [System.StringComparer]::OrdinalIgnoreCase)

    $res.Ok = $true
    $res.Models = $sorted
    $res.Count = $sorted.Count
    $res.Format = $format
    return $res
}

# ---------------------------------------------------------------- 重试判定
function Test-ShouldRetryWithMaxCompletionTokens {
    <#  供应商不认 max_tokens 时是否值得换 max_completion_tokens 重试  #>
    param([int]$Http, [string]$Body)

    if ($Http -ne 400 -and $Http -ne 422 -and $Http -ne 500) { return $false }
    if ([string]::IsNullOrEmpty($Body)) { return $false }
    return [bool]($Body -match '(?i)max_tokens|max_completion_tokens|unsupported parameter|unknown (parameter|field)|unrecognized|invalid_request_error')
}

function Test-ShouldRetryAnthropicBearer {
    param([int]$Http, [string]$Body)
    if ($Http -ne 401 -and $Http -ne 403) { return $false }
    if ([string]::IsNullOrEmpty($Body)) { return $true }
    return [bool]($Body -match '(?i)x-api-key|api[-_ ]?key|authorization|bearer|authenticat')
}

function Test-ShouldRetryAlternateEndpoint {
    param([int]$Http)
    return ($Http -eq 404 -or $Http -eq 405)
}

# ---------------------------------------------------------------- 结果显示
function Format-ReasoningTokens {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [string]$Value
}

function Format-ContentPreview {
    param([string]$Text, [int]$Max = 80)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return (Get-OneLine $Text $Max)
}

function Format-Latency {
    param($Ms)
    if ($null -eq $Ms) { return '' }
    try { $v = [double]$Ms } catch { return '' }
    if ($v -le 0) { return '' }
    if ($v -lt 1000) { return ('{0:N0}ms' -f $v) }
    return ('{0:N2}s' -f ($v / 1000.0))
}

function Get-RowResult {
    <#  把内部行对象整理成界面/CSV/报告共用的扁平结果  #>
    param($Row)

    return [ordered]@{
        Model           = [string]$Row.Model
        RequestedModel  = [string]$Row.Model
        ReturnedModel   = [string]$Row.ReturnedModel
        Protocol        = [string]$Row.Protocol
        Endpoint        = [string]$Row.Endpoint
        Http            = $Row.Http
        Status          = [string]$Row.Status
        StatusShort     = [string]$Row.StatusShort
        LatencyMs       = $Row.LatencyMs
        TtfbMs          = $Row.TtfbMs
        FinishReason    = [string]$Row.FinishReason
        ReasoningTokens = $Row.ReasoningTokens
        ContentPresent  = [bool]$Row.ContentPresent
        ContentPreview  = [string]$Row.ContentPreview
        Error           = [string]$Row.Error
        Rank            = $Row.Rank
        Notes           = [string]$Row.Notes
    }
}

# ---------------------------------------------------------------- 报告 / CSV
function Format-ReportTable {
    param(
        [object[]]$Rows,
        [string]$BaseUrl = '',
        [string]$Protocol = '',
        [string]$Secret = ''
    )

    $sb = New-Object System.Text.StringBuilder
    $nl = "`r`n"

    [void]$sb.Append('API Model Tester report' + $nl)
    [void]$sb.Append(('Generated : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + $nl))
    if ($BaseUrl) { [void]$sb.Append(('Base URL  : ' + (Mask-Secret $BaseUrl $Secret) + $nl)) }
    if ($Protocol) { [void]$sb.Append(('Protocol  : ' + $Protocol + $nl)) }
    [void]$sb.Append(('Models    : ' + @($Rows).Count + $nl))
    [void]$sb.Append($nl)

    $wModel = 26; $wRet = 24; $wHttp = 5; $wSt = 14; $wLat = 9; $wTtfb = 9
    $hdr = (Pad-Display 'Model' $wModel) + (Pad-Display 'ReturnedModel' ($wRet + 1)) +
           (Pad-Display 'HTTP' $wHttp) + (Pad-Display 'Status' ($wSt + 1)) +
           (Pad-Display 'Latency' ($wLat + 1)) + (Pad-Display 'TTFB' $wTtfb)
    [void]$sb.Append($hdr.TrimEnd() + $nl)
    [void]$sb.Append(('-' * (Get-DisplayWidth $hdr)) + $nl)

    foreach ($r in @($Rows)) {
        $http = ''
        if ($null -ne $r.Http -and [int]$r.Http -gt 0) { $http = [string]$r.Http }
        $st = [string]$r.StatusShort
        if ([string]::IsNullOrEmpty($st)) { $st = [string]$r.Status }
        $line = (Pad-Display ([string]$r.Model) $wModel) +
                (Pad-Display ([string]$r.ReturnedModel) ($wRet + 1)) +
                (Pad-Display $http $wHttp) +
                (Pad-Display $st ($wSt + 1)) +
                (Pad-Display (Format-Latency $r.LatencyMs) ($wLat + 1)) +
                (Pad-Display (Format-Latency $r.TtfbMs) $wTtfb)
        [void]$sb.Append($line.TrimEnd() + $nl)
        if (-not [string]::IsNullOrWhiteSpace([string]$r.Error)) {
            [void]$sb.Append(('    ! ' + (Get-OneLine ([string]$r.Error) 160) + $nl))
        }
    }

    $ok = 0; $warn = 0; $err = 0; $cancelled = 0
    foreach ($r in @($Rows)) {
        switch ([string]$r.StatusShort) {
            'OK'        { $ok++ }
            'Warn'      { $warn++ }
            'Cancelled' { $cancelled++ }
            default     { $err++ }
        }
    }
    [void]$sb.Append($nl)
    [void]$sb.Append(('Summary   : OK ' + $ok + ' | Warning ' + $warn + ' | Failed ' + $err + ' | Cancelled ' + $cancelled + $nl))
    return $sb.ToString()
}

function Get-CsvText {
    param([object[]]$Rows)

    $cols = @('Model', 'ReturnedModel', 'Protocol', 'Endpoint', 'HTTP', 'Status', 'Latency',
              'TTFB', 'FinishReason', 'ReasoningTokens', 'ContentPresent', 'ContentPreview', 'Error')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(($cols -join ',') + "`r`n")

    foreach ($r in @($Rows)) {
        $vals = @(
            [string]$r.Model,
            [string]$r.ReturnedModel,
            [string]$r.Protocol,
            [string]$r.Endpoint,
            $(if ($null -ne $r.Http) { [string]$r.Http } else { '' }),
            [string]$r.Status,
            (Format-Latency $r.LatencyMs),
            (Format-Latency $r.TtfbMs),
            [string]$r.FinishReason,
            (Format-ReasoningTokens $r.ReasoningTokens),
            $(if ($r.ContentPresent) { 'yes' } else { 'no' }),
            [string]$r.ContentPreview,
            [string]$r.Error
        )
        $cells = @()
        foreach ($v in $vals) {
            $s = [string]$v
            if ($s -match '[",\r\n]') { $s = '"' + ($s.Replace('"', '""')) + '"' }
            $cells += $s
        }
        [void]$sb.Append(($cells -join ',') + "`r`n")
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------- 配置
function Get-SettingsPath {
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrEmpty($base)) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'ApiModelTester') 'settings.json')
}

function New-DefaultSettings {
    return [ordered]@{
        version             = 1
        baseUrl             = ''
        protocol            = 'Auto Detect'
        timeoutSec          = 30
        concurrency         = 3
        normalizeV1         = $true
        autoTestAfterFetch  = $false
        window              = [ordered]@{ width = 1180; height = 780; x = -1; y = -1 }
        columnWidths        = @{}
    }
}

function Read-AppSettings {
    <#  只读回非敏感项；key 永不落盘  #>
    $cfg = New-DefaultSettings
    $p = Get-SettingsPath
    if (-not (Test-Path $p)) { return $cfg }
    try {
        $raw = Get-Content -Path $p -Raw -Encoding UTF8
        $obj = ConvertFrom-JsonSafe $raw
        if ($null -eq $obj) { return $cfg }

        $map = @{
            baseUrl            = 'baseUrl'
            protocol           = 'protocol'
            timeoutSec         = 'timeoutSec'
            concurrency        = 'concurrency'
            normalizeV1        = 'normalizeV1'
            autoTestAfterFetch = 'autoTestAfterFetch'
        }
        foreach ($k in $map.Keys) {
            $v = Get-JsonPath $obj $map[$k]
            if ($null -ne $v) { $cfg[$k] = $v }
        }
        $w = Get-JsonPath $obj 'window'
        if ($null -ne $w) {
            foreach ($wk in @('width', 'height', 'x', 'y')) {
                $v = Get-JsonPath $w $wk
                if ($null -ne $v) { $cfg.window[$wk] = $v }
            }
        }
        $cw = Get-JsonPath $obj 'columnWidths'
        if ($null -ne $cw -and $cw -is [System.Management.Automation.PSCustomObject]) {
            $d = [ordered]@{}
            foreach ($p2 in $cw.PSObject.Properties) {
                $n = 0
                try { $n = [int]$p2.Value } catch { $n = 0 }
                if ($n -ge 30 -and $n -le 2000) { $d[$p2.Name] = $n }
            }
            $cfg.columnWidths = $d
        }
    } catch { }
    return $cfg
}

function Save-AppSettings {
    <#
      白名单式写入：只允许列在这里的字段落盘，API Key 不存在于任何白名单中。
      返回 $true/$false
    #>
    param($Settings)

    try {
        $out = New-DefaultSettings
        foreach ($k in @('baseUrl', 'protocol', 'timeoutSec', 'concurrency', 'normalizeV1', 'autoTestAfterFetch')) {
            if ($Settings.Contains($k) -and $null -ne $Settings[$k]) { $out[$k] = $Settings[$k] }
        }
        if ($Settings.Contains('window') -and $null -ne $Settings['window']) {
            foreach ($wk in @('width', 'height', 'x', 'y')) {
                if ($Settings['window'].Contains($wk)) { $out.window[$wk] = $Settings['window'][$wk] }
            }
        }
        if ($Settings.Contains('columnWidths') -and $null -ne $Settings['columnWidths']) {
            $d = [ordered]@{}
            foreach ($k in $Settings['columnWidths'].Keys) {
                $d[[string]$k] = [int]$Settings['columnWidths'][$k]
            }
            $out.columnWidths = $d
        }
        # 最后一道保险：整个序列化结果里不允许出现常见密钥字段名
        $json = $out | ConvertTo-Json -Depth 6
        if ($json -match '(?i)"(api[-_]?key|apikey|authorization|token|secret)"\s*:') {
            return $false
        }
        [void](Write-Utf8File -Path (Get-SettingsPath) -Text $json)
        return $true
    } catch {
        return $false
    }
}
