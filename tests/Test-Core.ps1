# ============================================================================
#  Test-Core.ps1  -  Api Model Tester 自检
#
#  覆盖：
#    A 语法检查（全部 .ps1）
#    B URL 规范化 / 不会产生 /v1/v1
#    C 密钥遮挡
#    D HTTP 状态 -> 人类可读状态映射
#    E 响应解析（OpenAI / Responses / Anthropic / SSE / 各种畸形）
#    F 真实网络往返（打本地假服务器）：200 / 警告 / 各类错误 / 超时 / 重试
#    G Auto Detect 探测（有界请求 + 提前停止）
#    H 并发上限（SemaphoreSlim 等效语义）
#    I Stop 立即生效
#    J 密钥不落盘（安装目录 / 配置目录 / 报告文件）
#    K 报告与 CSV 生成
#
#  用法：
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Core.ps1
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Core.ps1 -OutFile C:\tmp\r.txt
# ============================================================================

param(
    [string]$OutFile = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

$Script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Script:Root 'lib\Core.ps1')
. (Join-Path $Script:Root 'lib\HttpEngine.ps1')
. (Join-Path $Script:Root 'lib\Detect.ps1')
. (Join-Path $PSScriptRoot 'MockServer.ps1')

Import-NetAssemblies -Name @('System.Net.Http', 'System.Net.Http.WebRequest') | Out-Null

# ---------------------------------------------------------------- 断言框架
# 注意：PowerShell 变量名大小写不敏感，这里的累加器刻意取名 OutLines，
#       避免和局部变量 $report / $reportText 互相覆盖（曾因此丢失整份报告）。
$Script:OutLines = New-Object System.Collections.ArrayList
$Script:Pass = 0
$Script:Fail = 0

function Write-Line {
    param([string]$Text)
    [void]$Script:OutLines.Add($Text)
    if (-not $Quiet) { Write-Host $Text }
}

function Assert-True {
    param([string]$Name, $Condition, [string]$Detail = '')
    if ($Condition) {
        $Script:Pass++
        Write-Line ("  PASS  " + $Name)
    } else {
        $Script:Fail++
        Write-Line ("  FAIL  " + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' }))
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = $false
    if ($null -eq $Expected -and $null -eq $Actual) { $ok = $true }
    elseif ($null -ne $Expected -and $null -ne $Actual) { $ok = ([string]$Expected -eq [string]$Actual) }
    Assert-True -Name $Name -Condition $ok -Detail ('expected=[' + [string]$Expected + '] actual=[' + [string]$Actual + ']')
}

function Assert-Contains {
    param([string]$Name, [string]$Haystack, [string]$Needle)
    $ok = ($null -ne $Haystack) -and ($Haystack.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0)
    Assert-True -Name $Name -Condition $ok -Detail ('looking for [' + $Needle + ']')
}

function Assert-NotContains {
    param([string]$Name, [string]$Haystack, [string]$Needle)
    $ok = ($null -eq $Haystack) -or ($Haystack.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0)
    Assert-True -Name $Name -Condition $ok -Detail 'needle was found (must not be present)'
}

function Section {
    param([string]$Title)
    Write-Line ''
    Write-Line ('== ' + $Title)
}

# ---------------------------------------------------------------- 驱动辅助
function Complete-BatchWithMock {
    param($Server, $Batch, [int]$TimeoutMs = 60000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Update-MockServer -Server $Server
        $r = Update-HttpBatch -Batch $Batch
        if ($r.Finished) { break }
        if ($sw.Elapsed.TotalMilliseconds -gt $TimeoutMs) { break }
        Start-Sleep -Milliseconds 3
    }
    return $sw.Elapsed.TotalMilliseconds
}

function Complete-RunWithMock {
    param($Server, $Run, [int]$TimeoutMs = 60000, [scriptblock]$OnTick = $null)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Update-MockServer -Server $Server
        $r = Update-ApiTestRun -Run $Run
        if ($OnTick) { & $OnTick $r }
        if ($r.Finished) { break }
        if ($sw.Elapsed.TotalMilliseconds -gt $TimeoutMs) { break }
        Start-Sleep -Milliseconds 3
    }
    return $sw.Elapsed.TotalMilliseconds
}

function Complete-DetectWithMock {
    param($Server, $Run, [int]$TimeoutMs = 60000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Update-MockServer -Server $Server
        $r = Update-DetectRun -Run $Run
        if ($r.Finished) { break }
        if ($sw.Elapsed.TotalMilliseconds -gt $TimeoutMs) { break }
        Start-Sleep -Milliseconds 3
    }
    return $sw.Elapsed.TotalMilliseconds
}

function Complete-FetchWithMock {
    param($Server, $Run, [int]$TimeoutMs = 60000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Update-MockServer -Server $Server
        $r = Update-FetchModelsRun -Run $Run
        if ($r.Finished) { break }
        if ($sw.Elapsed.TotalMilliseconds -gt $TimeoutMs) { break }
        Start-Sleep -Milliseconds 3
    }
    return $sw.Elapsed.TotalMilliseconds
}

# ---------------------------------------------------------------- 假服务器应答
function Get-ChatOkJson {
    param([string]$Model, [string]$Content = 'OK')
    return ('{"id":"chatcmpl-1","object":"chat.completion","model":"' + $Model + '","choices":[{"index":0,' +
            '"message":{"role":"assistant","content":"' + $Content + '"},"finish_reason":"stop"}],' +
            '"usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9,' +
            '"completion_tokens_details":{"reasoning_tokens":0}}}')
}

function Get-MockChatSpec {
    <#  按请求体里的 model 决定返回什么 —— 一个路由覆盖所有解析场景  #>
    param($req)

    $m = ''
    try { $m = [string]((ConvertFrom-Json $req.Body).model) } catch { $m = '' }
    $body = [string]$req.Body
    $isMessages = ($req.Path -match 'messages')
    $isResponses = ($req.Path -match 'responses')

    switch -Regex ($m) {
        '^m-maxtok$' {
            if ($body -match 'max_completion_tokens') { return @{ Status = 200; Json = (Get-ChatOkJson $m) } }
            return @{ Status = 400; Json = ('{"error":{"message":"Unsupported parameter: max_tokens is not supported with this model. Use max_completion_tokens instead.","type":"invalid_request_error","param":"max_tokens"}}') }
        }
        '^m-alt$' {
            if ($isMessages -or $isResponses) { return @{ Status = 404; Json = '{"error":{"message":"no such route"}}' } }
            if ($req.Path -eq '/chat/completions') { return @{ Status = 200; Json = (Get-ChatOkJson $m) } }
            return @{ Status = 404; Json = '{"error":{"message":"no such route: ' + $req.Path + '"}}' }
        }
        '^m-empty$'  { return @{ Status = 200; Json = ('{"object":"chat.completion","model":"' + $m + '","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}') } }
        '^m-reasoning$' {
            return @{ Status = 200; Json = ('{"object":"chat.completion","model":"' + $m + '","choices":[{"index":0,' +
                     '"message":{"role":"assistant","content":"","reasoning_content":"step by step ..."},"finish_reason":"stop"}],' +
                     '"usage":{"completion_tokens":12,"completion_tokens_details":{"reasoning_tokens":12}}}') }
        }
        '^m-badjson$' { return @{ Status = 200; Body = '<html>gateway says hi</html>'; ContentType = 'text/html' } }
        '^m-nochoices$' { return @{ Status = 200; Json = ('{"object":"chat.completion","model":"' + $m + '","usage":{"total_tokens":3}}') } }
        '^m-error200$' { return @{ Status = 200; Json = '{"error":{"message":"upstream model unavailable","code":"upstream_error"}}' } }
        '^m-sse$' {
            $sse = "data: {`"choices`":[{`"delta`":{`"content`":`"O`"},`"finish_reason`":null}]}`n`n" +
                   "data: {`"choices`":[{`"delta`":{`"content`":`"K`"},`"finish_reason`":null}]}`n`n" +
                   "data: {`"choices`":[{`"delta`":{},`"finish_reason`":`"stop`"}]}`n`n" +
                   "data: [DONE]`n`n"
            return @{ Status = 200; Body = $sse; ContentType = 'text/event-stream' }
        }
        '^m-sse-broken$' {
            $sse = "data: not-json-at-all`n`n" + "data: {`"choices`":[{`"delta`":{`"content`":`"OK`"}}]}`n`n"
            return @{ Status = 200; Body = $sse; ContentType = 'text/event-stream' }
        }
        '^m-401$' { return @{ Status = 401; Json = '{"error":{"message":"Invalid API key provided","type":"authentication_error"}}' } }
        '^m-403$' { return @{ Status = 403; Json = '{"error":{"message":"permission denied for this model","type":"permission_error"}}' } }
        '^m-404$' { return @{ Status = 404; Json = '{"error":{"message":"The model `m-404` does not exist","type":"invalid_request_error"}}' } }
        '^m-408$' { return @{ Status = 408; Json = '{"error":{"message":"request timeout"}}' } }
        '^m-429$' { return @{ Status = 429; Json = '{"error":{"message":"Rate limit reached for requests","type":"rate_limit_error"}}' } }
        '^m-500$' { return @{ Status = 500; Json = '{"error":{"message":"internal server error"}}' } }
        '^m-502$' { return @{ Status = 502; Json = '{"error":{"message":"bad gateway"}}' } }
        '^m-503$' { return @{ Status = 503; Json = '{"error":{"message":"service unavailable"}}' } }
        '^m-524$' { return @{ Status = 524; Json = '{"error":{"message":"a timeout occurred"}}' } }
        '^m-slow$' { return @{ Status = 200; Json = (Get-ChatOkJson $m); DelayMs = 3000 } }
        '^m-multi$' { return @{ Status = 200; Json = (Get-ChatOkJson $m); DelayMs = 120 } }
        '^m-stop$' { return @{ Status = 200; Json = (Get-ChatOkJson $m); DelayMs = 800 } }
        '^m-claude.*$' {
            if ($isMessages -or $req.Path -match 'messages') {
                return @{ Status = 200; Json = ('{"id":"msg_1","type":"message","role":"assistant","model":"' + $m + '",' +
                         '"content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn",' +
                         '"usage":{"input_tokens":8,"output_tokens":3}}') }
            }
            return @{ Status = 200; Json = (Get-ChatOkJson $m) }
        }
    }

    # 默认：按路径给出正确形态的成功响应
    if ($isMessages) {
        return @{ Status = 200; Json = ('{"id":"msg_1","type":"message","role":"assistant","model":"' + $m + '",' +
                 '"content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":8,"output_tokens":3}}') }
    }
    if ($isResponses) {
        return @{ Status = 200; Json = ('{"id":"resp_1","object":"response","status":"completed","model":"' + $m + '",' +
                 '"output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"brief"}]},' +
                 '{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}],' +
                 '"usage":{"input_tokens":6,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":3}}}') }
    }
    return @{ Status = 200; Json = (Get-ChatOkJson $m) }
}

function New-MainMockServer {
    $routes = @{}
    $routes['GET /v1/models'] = @{
        Status = 200
        Json   = '{"object":"list","data":[{"id":"m-ok","object":"model"},{"id":"m-401","object":"model"},{"id":"m-empty"},{"id":"m-reasoning"},{"id":"m-claude-1"}]}'
    }
    foreach ($p in @('/v1/chat/completions', '/chat/completions', '/v1/responses', '/responses', '/v1/messages', '/messages')) {
        $routes['POST ' + $p] = @{ Script = { param($req) Get-MockChatSpec $req } }
    }
    # 恶意双 /v1 路径：显式登记为 404，一旦被请求就会在 Requests 里留下证据
    $routes['POST /v1/v1/chat/completions'] = @{ Status = 404; Json = '{"error":{"message":"double v1"}}' }
    $routes['GET /v1/v1/models'] = @{ Status = 404; Json = '{"error":{"message":"double v1"}}' }
    return New-MockServer -Routes $routes
}

# ============================================================================
#  开始
# ============================================================================
Write-Line 'API Model Tester - self test'
Write-Line ('Time       : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Line ('Host       : ' + $PSVersionTable.PSVersion.ToString() + ' / ' + $PSVersionTable.PSEdition)
Write-Line ('InstallDir : ' + $Script:Root)

# 每次运行生成一把独一无二的假 key：
# 这样「安装目录里不能出现 key 明文」才是真正有意义的断言（不会撞上测试源码里的固定字面量）
$fakeKey = 'sk-amtselftest-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 20) + '-ZZZ'
$fakeKeyMasked = Get-MaskedToken $fakeKey

# ---------------------------------------------------------------- A 语法
Section 'A. 语法检查'
$parseErrors = 0
$parsedFiles = 0
$allPs1 = @(Get-ChildItem -Path $Script:Root -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
foreach ($f in $allPs1) {
    $tokens = $null
    $errors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    } catch {
        $errors = @($_)
    }
    $parsedFiles++
    if ($errors -and @($errors).Count -gt 0) {
        $parseErrors++
        foreach ($e in @($errors)) {
            Write-Line ('  FAIL  ' + $f.Name + ' : ' + $e.Message)
        }
    }
}
Assert-True -Name ('全部 ' + $parsedFiles + ' 个 .ps1 解析通过') -Condition ($parseErrors -eq 0) -Detail ($parseErrors.ToString() + ' 个文件有语法错误')

# ---------------------------------------------------------------- B URL
Section 'B. URL 规范化'
Assert-Equal 'B1 补 scheme'            'https://example.com'                    (Expand-BaseUrl 'example.com')
Assert-Equal 'B2 去尾斜杠'             'https://abc.com'                        (Expand-BaseUrl 'https://abc.com/')
Assert-Equal 'B3 保留 /v1'             'https://abc.com/v1'                     (Expand-BaseUrl 'https://abc.com/v1/')
Assert-Equal 'B4 剥掉误粘的端点'        'https://abc.com'                        (Expand-BaseUrl 'https://abc.com/v1/models')
Assert-Equal 'B5 剥掉多段端点'          'https://abc.com/openai'                 (Expand-BaseUrl 'https://abc.com/openai/v1/chat/completions')
Assert-Equal 'B6 去 query'             'https://abc.com'                        (Expand-BaseUrl 'https://abc.com?a=1#b')

Assert-Equal 'B7 裸域名不产生 /v1/v1'   'https://abc.com/v1/models'              (Resolve-ApiUrl 'https://abc.com' '/v1/models' -Normalize)
Assert-Equal 'B8 带 /v1 不产生 /v1/v1'  'https://abc.com/v1/models'              (Resolve-ApiUrl 'https://abc.com/v1' '/v1/models' -Normalize)
Assert-Equal 'B9 带 /v1/ 不产生重复'    'https://abc.com/v1/models'              (Resolve-ApiUrl 'https://abc.com/v1/' '/v1/models' -Normalize)
Assert-Equal 'B10 子路径保留'           'https://abc.com/openai/v1/models'       (Resolve-ApiUrl 'https://abc.com/openai/v1' '/v1/models' -Normalize)
Assert-Equal 'B11 chat 不重复'          'https://abc.com/v1/chat/completions'    (Resolve-ApiUrl 'https://abc.com/v1' '/v1/chat/completions' -Normalize)
Assert-Equal 'B12 关闭规范化则原样拼'   'https://abc.com/v1/v1/models'           (Resolve-ApiUrl 'https://abc.com/v1' '/v1/models')

$c1 = @(Get-ApiCandidates 'https://abc.com' -Kind 'Models' -Normalize)
$c2 = @(Get-ApiCandidates 'https://abc.com/v1' -Kind 'Models' -Normalize)
Assert-Equal 'B13 裸域名两个候选'       2 $c1.Count
Assert-True  'B14 带 /v1 时候选塌缩为 1' ($c2.Count -eq 1) ('count=' + $c2.Count)
Assert-Equal 'B15 候选去重后地址'       'https://abc.com/v1/models' $c2[0]

$altUrl = Get-ApiUrlForAttempt -BaseUrl 'https://abc.com/v1' -Kind 'Chat' -Normalize -Alternate
Assert-Equal 'B16 备用形态不再 /v1'     'https://abc.com/chat/completions' $altUrl

# ---------------------------------------------------------------- C 遮挡
Section 'C. 密钥遮挡'
$m1 = Mask-Secret ('Authorization: Bearer ' + $fakeKey) $fakeKey
Assert-NotContains 'C1 精确替换真实 key' $m1 $fakeKey
Assert-Contains    'C2 保留 sk- 前缀与掩码形态' $m1 'sk-amt...'

$m2 = Mask-Secret 'oops: sk-abcdefghijklmnop1234567890 leaked' ''
Assert-NotContains 'C3 兜底规则遮挡 sk-' $m2 'sk-abcdefghijklmnop1234567890'
Assert-Contains    'C4 兜底遮挡形态正确' $m2 'sk-abc...890'

$m3 = Mask-Secret '{"api_key":"abcdefghijklmnopqrstuvwxyz"}' ''
Assert-NotContains 'C5 JSON 字段遮挡' $m3 'abcdefghijklmnopqrstuvwxyz'

$m4 = Mask-Secret 'x-api-key: 1234567890abcdefghij' ''
Assert-NotContains 'C6 x-api-key 头遮挡' $m4 '1234567890abcdefghij'

Assert-Equal 'C7 空 key 不炸' 'plain text' (Mask-Secret 'plain text' '')

# ---------------------------------------------------------------- D 状态映射
Section 'D. HTTP 状态映射'
$expectStatus = @{
    400 = 'BadRequest'; 401 = 'AuthFail'; 403 = 'Forbidden'; 404 = 'NotFound'; 408 = 'Timeout'
    429 = 'RateLimit'; 500 = 'ServerErr'; 502 = 'BadGateway'; 503 = 'Unavailable'; 524 = 'UpstreamTO'
}
foreach ($code in $expectStatus.Keys) {
    $s = Get-StatusFromHttpCode $code
    Assert-Equal ('D' + $code + ' -> ' + $expectStatus[$code]) $expectStatus[$code] $s.Short
}
Assert-Equal 'D-999 未知码兜底' 'HTTP999' (Get-StatusFromHttpCode 999).Short

# ---------------------------------------------------------------- E 解析
Section 'E. 响应解析（离线 payload）'
$chatOk = Get-ChatOkJson 'gpt-x'
$r = Read-ChatResult -Body $chatOk -ContentType 'application/json'
Assert-Equal 'E1 chat content'        'OK'      $r.Content
Assert-Equal 'E2 chat returned model' 'gpt-x'   $r.ReturnedModel
Assert-Equal 'E3 chat finish_reason'  'stop'    $r.FinishReason
Assert-Equal 'E4 chat reasoning tok'  '0'       $r.ReasoningTokens
$v = Get-TestVerdict -Result $r -Http 200 -Kind 'Chat'
Assert-Equal 'E5 chat verdict OK'     'OK'      $v.Status

$r = Read-ChatResult -Body '{"model":"m","choices":[{"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}' -ContentType ''
$v = Get-TestVerdict -Result $r -Http 200 -Kind 'Chat'
Assert-Equal 'E6 空 content -> Warning' 'Compatibility Warning' $v.Status

$r = Read-ChatResult -Body '{"model":"m","choices":[{"message":{"content":"","reasoning_content":"think"},"finish_reason":"stop"}],"usage":{"completion_tokens_details":{"reasoning_tokens":12}}}' -ContentType ''
Assert-Equal 'E7 reasoning 计数' '12' $r.ReasoningTokens
$v = Get-TestVerdict -Result $r -Http 200 -Kind 'Chat'
Assert-Equal 'E8 只有 reasoning -> Warning' 'Compatibility Warning' $v.Status
Assert-Contains 'E9 warning 说明是 reasoning' $v.Detail 'reasoning'

$r = Read-ChatResult -Body '<html>nope</html>' -ContentType 'text/html'
$v = Get-TestVerdict -Result $r -Http 200 -Kind 'Chat'
Assert-Equal 'E10 非 JSON -> Warning' 'Compatibility Warning' $v.Status

$r = Read-ChatResult -Body '{"model":"m","usage":{"total_tokens":3}}' -ContentType ''
$v = Get-TestVerdict -Result $r -Http 200 -Kind 'Chat'
Assert-Equal 'E11 缺 choices -> Warning' 'Compatibility Warning' $v.Status
Assert-Contains 'E12 warning 提到 choices' $v.Detail 'choices'

$r = Read-ChatResult -Body '{"error":{"message":"upstream model unavailable"}}' -ContentType ''
$v = Get-TestVerdict -Result $r -Http 200 -Kind 'Chat'
Assert-Equal 'E13 200 里带 error -> Warning' 'Compatibility Warning' $v.Status
Assert-Contains 'E14 保留服务器 error.message' $v.Detail 'upstream model unavailable'

$sseBody = "data: {`"choices`":[{`"delta`":{`"content`":`"O`"}}]}`n`ndata: {`"choices`":[{`"delta`":{`"content`":`"K`"}}]}`n`ndata: [DONE]`n`n"
$r = Read-ChatResult -Body $sseBody -ContentType 'text/event-stream'
Assert-Equal 'E15 SSE 拼接 content' 'OK' $r.Content
Assert-True  'E16 SSE 标记 streaming' $r.Streaming
Assert-True  'E17 SSE 识别 [DONE]' $r.SseDone

$respBody = '{"object":"response","status":"completed","model":"gpt-5","output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"hmm"}]},{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":6,"output_tokens":9,"output_tokens_details":{"reasoning_tokens":4}}}'
$r = Read-ResponsesResult -Body $respBody -ContentType ''
Assert-Equal 'E18 responses content' 'OK' $r.Content
Assert-Equal 'E19 responses reasoning 文本' 'hmm' $r.ReasoningText
Assert-Equal 'E20 responses reasoning tokens' '4' $r.ReasoningTokens
Assert-Equal 'E21 responses finish' 'completed' $r.FinishReason

$antBody = '{"id":"msg_1","type":"message","model":"claude-x","content":[{"type":"thinking","thinking":"deep"},{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":8,"output_tokens":3}}'
$r = Read-AnthropicResult -Body $antBody -ContentType ''
Assert-Equal 'E22 anthropic content' 'OK' $r.Content
Assert-Equal 'E23 anthropic thinking' 'deep' $r.ReasoningText
Assert-Equal 'E24 anthropic stop_reason' 'end_turn' $r.FinishReason
Assert-Equal 'E25 anthropic returned model' 'claude-x' $r.ReturnedModel

$antErr = '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'
$r = Read-AnthropicResult -Body $antErr -ContentType ''
$v = Get-TestVerdict -Result $r -Http 200 -Kind 'Messages'
Assert-Equal 'E26 anthropic 200 带 error -> Warning' 'Compatibility Warning' $v.Status

$r = New-TestResult
$v = Get-TestVerdict -Result $r -Http 0 -ErrorType 'DNS' -ErrorMessage 'DNS 解析失败: host not found'
Assert-Equal 'E27 DNS 单独显示' 'DNS Error' $v.Status
$v = Get-TestVerdict -Result $r -Http 0 -ErrorType 'TLS' -ErrorMessage 'TLS/证书错误: x'
Assert-Equal 'E28 TLS 单独显示' 'TLS Error' $v.Status
$v = Get-TestVerdict -Result $r -Http 0 -ErrorType 'Timeout' -ErrorMessage '本地超时'
Assert-Equal 'E29 本地超时' 'Timeout' $v.Status

Section 'E+ 模型列表解析'
$ml = Read-ModelList '{"object":"list","data":[{"id":"b-model"},{"id":"a-model"},{"id":"b-model"}]}'
Assert-True  'E30 models 解析成功' $ml.Ok
Assert-Equal 'E31 models 去重' '2' $ml.Count
Assert-Equal 'E32 models 排序' 'a-model' $ml.Models[0]
$ml = Read-ModelList '["x1","x2"]'
Assert-Equal 'E33 裸数组支持' '2' $ml.Count
$ml = Read-ModelList '{"models":[{"name":"n1"}]}'
Assert-Equal 'E34 models 字段支持' 'n1' $ml.Models[0]
$ml = Read-ModelList '{"error":{"message":"no auth"}}'
Assert-True  'E35 错误响应不算模型列表' (-not $ml.Ok)
$ml = Read-ModelList 'not json'
Assert-True  'E36 非 JSON 不算模型列表' (-not $ml.Ok)

# ---------------------------------------------------------------- F 网络
Section 'F. 真实往返（本地假服务器）'
$mock = New-MainMockServer
Write-Line ('  mock server: ' + $mock.BaseUrl)

$engine = New-HttpEngine

# F1 取模型列表
$fetch = New-FetchModelsRun -Engine $engine -Urls (Get-ModelListCandidates $mock.BaseUrl -Normalize) -TimeoutSec 15 `
    -Headers (Get-RequestHeaders -Kind 'Chat' -ApiKey $fakeKey)
Complete-FetchWithMock -Server $mock -Run $fetch | Out-Null
Assert-True  'F1 Fetch Models 成功' $fetch.Ok ($fetch.Error)
Assert-Equal 'F2 模型数量' '5' @($fetch.Models).Count
$usedPath = ([System.Uri]$fetch.UsedUrl).AbsolutePath
Assert-Equal 'F3 使用的端点' '/v1/models' $usedPath

# F4 取模型列表失败时的候选回退
# 注意：PowerShell 在参数模式下不把 + 当运算符，这里必须先用变量算好 URL
$mockNoV1 = New-MockServer -Routes @{ 'GET /models' = @{ Status = 200; Json = '{"data":[{"id":"plain-1"}]}' } }
$nv1a = 'http://127.0.0.1:' + $mockNoV1.Port + '/v1/models'
$nv1b = 'http://127.0.0.1:' + $mockNoV1.Port + '/models'
$ef2 = New-HttpEngine
$fetch2 = New-FetchModelsRun -Engine $ef2 -Urls @($nv1a, $nv1b) -TimeoutSec 15
Complete-FetchWithMock -Server $mockNoV1 -Run $fetch2 | Out-Null
Assert-True  'F4 /v1/models 404 时回退到 /models' $fetch2.Ok ($fetch2.Error)
Assert-Equal 'F5 回退拿到模型' 'plain-1' @($fetch2.Models)[0]
Assert-Equal 'F5b 回退时试了 2 个候选' '2' @($fetch2.Attempts).Count
Stop-MockServer -Server $mockNoV1
Remove-HttpEngine -Engine $ef2

# F6 各类响应 -> 状态
function Invoke-OneApi {
    param($Server, [string]$Model, [string]$Endpoint, [string]$Kind = 'Chat', [int]$TimeoutSec = 15)
    $e = New-HttpEngine
    $job = New-ApiTestJob -Id 'j' -Model $Model -Kind $Kind -Url $Endpoint -ApiKey $fakeKey -TimeoutSec $TimeoutSec -RowIndex 0
    $b = New-HttpBatch -Engine $e -Jobs @($job) -Concurrency 1
    Complete-BatchWithMock -Server $Server -Batch $b | Out-Null
    Remove-HttpEngine -Engine $e
    return $job
}

$chatUrl = $mock.BaseUrl + '/v1/chat/completions'

$job = Invoke-OneApi -Server $mock -Model 'm-vanilla' -Endpoint $chatUrl
$rowVanilla = New-ResultRow -Index 0 -Model 'm-vanilla' -Protocol 'Chat'
Fill-ResultRow -Row $rowVanilla -Job $job -Kind 'Chat' -Secret $fakeKey
Assert-Equal 'F6 200 正常 -> OK' 'OK' $rowVanilla.StatusShort
Assert-True  'F7 TTFB 已采集' ($null -ne $job.TtfbMs -and [double]$job.TtfbMs -gt 0) ('ttfb=' + [string]$job.TtfbMs)
Assert-True  'F8 Latency >= TTFB' ([double]$job.LatencyMs -ge [double]$job.TtfbMs)
Assert-Equal 'F9 returned model 回显' 'm-vanilla' (Read-ChatResult -Body $job.RespBody -ContentType $job.ContentType).ReturnedModel
Assert-True  'F10 TTFB 单位是毫秒级' ([double]$job.TtfbMs -lt 5000) ('ttfb=' + [string]$job.TtfbMs)

$cases = @(
    @{ M = 'm-empty';     Short = 'Warn' },
    @{ M = 'm-reasoning'; Short = 'Warn' },
    @{ M = 'm-badjson';   Short = 'Warn' },
    @{ M = 'm-nochoices'; Short = 'Warn' },
    @{ M = 'm-error200';  Short = 'Warn' },
    @{ M = 'm-sse';       Short = 'OK' },
    @{ M = 'm-sse-broken'; Short = 'OK' },
    @{ M = 'm-401';       Short = 'AuthFail' },
    @{ M = 'm-403';       Short = 'Forbidden' },
    @{ M = 'm-404';       Short = 'NotFound' },
    @{ M = 'm-408';       Short = 'Timeout' },
    @{ M = 'm-429';       Short = 'RateLimit' },
    @{ M = 'm-500';       Short = 'ServerErr' },
    @{ M = 'm-502';       Short = 'BadGateway' },
    @{ M = 'm-503';       Short = 'Unavailable' },
    @{ M = 'm-524';       Short = 'UpstreamTO' }
)
foreach ($c in $cases) {
    $j = Invoke-OneApi -Server $mock -Model $c.M -Endpoint $chatUrl
    $row = New-ResultRow -Index 0 -Model $c.M -Protocol 'Chat'
    Fill-ResultRow -Row $row -Job $j -Kind 'Chat' -Secret $fakeKey
    Assert-Equal ('F11 ' + $c.M + ' -> ' + $c.Short) $c.Short $row.StatusShort
}
$j = Invoke-OneApi -Server $mock -Model 'm-401' -Endpoint $chatUrl
$row = New-ResultRow -Index 0 -Model 'm-401' -Protocol 'Chat'
Fill-ResultRow -Row $row -Job $j -Kind 'Chat' -Secret $fakeKey
Assert-Contains 'F12 不吞掉服务器 error.message' $row.Error 'Invalid API key provided'

# F13 200 但内容异常时 HTTP 仍然是 200
$j = Invoke-OneApi -Server $mock -Model 'm-empty' -Endpoint $chatUrl
Assert-Equal 'F13 警告行 HTTP 仍是 200' '200' $j.Http

# F14 max_tokens 兼容重试
$engine2 = New-HttpEngine
$run = New-ApiTestRun -Engine $engine2 -Models @('m-maxtok') -Kind 'Chat' -ApiKey $fakeKey -EndpointUrl $chatUrl -Concurrency 1 -TimeoutSec 15 -AllowRetry
Complete-RunWithMock -Server $mock -Run $run | Out-Null
$row = $run.Rows[0]
Assert-Equal 'F14 max_tokens 失败后重试成功' 'OK' $row.StatusShort ('status=' + $row.Status + ' err=' + $row.Error)
Assert-True  'F15 记录了兼容重试' ($row.RetryNotes.Count -gt 0)
Assert-True  'F16 假服务器确实收到 max_completion_tokens' `
    (@(Get-MockRequestSummary -Server $mock | Where-Object { $_.Body -match 'max_completion_tokens' }).Count -gt 0)
Remove-HttpEngine -Engine $engine2

# F17 备用路径形态重试
$engine3 = New-HttpEngine
$run = New-ApiTestRun -Engine $engine3 -Models @('m-alt') -Kind 'Chat' -ApiKey $fakeKey -EndpointUrl $chatUrl -Concurrency 1 -TimeoutSec 15 -AllowRetry -MetaBase @{ BaseUrl = $mock.BaseUrl; Normalize = $true }
Complete-RunWithMock -Server $mock -Run $run | Out-Null
$row = $run.Rows[0]
Assert-Equal 'F17 /v1 404 后换路径成功' 'OK' $row.StatusShort ('status=' + $row.Status + ' err=' + $row.Error)
Assert-True  'F18 备用端点已记录' ($row.Endpoint -match '/chat/completions$' -and $row.Endpoint -notmatch '/v1/chat') ('endpoint=' + $row.Endpoint)
Remove-HttpEngine -Engine $engine3

# F19 Anthropic 协议
$antUrl = $mock.BaseUrl + '/v1/messages'
$j = Invoke-OneApi -Server $mock -Model 'm-claude-1' -Endpoint $antUrl -Kind 'Messages'
$row = New-ResultRow -Index 0 -Model 'm-claude-1' -Protocol 'Anthropic'
Fill-ResultRow -Row $row -Job $j -Kind 'Messages' -Secret $fakeKey
Assert-Equal 'F19 Anthropic 正常 -> OK' 'OK' $row.StatusShort
Assert-True  'F20 发送了 x-api-key 头' (@(Get-MockRequestSummary -Server $mock | Where-Object { $_.Headers.ContainsKey('x-api-key') }).Count -gt 0)
Assert-True  'F21 发送了 anthropic-version 头' (@(Get-MockRequestSummary -Server $mock | Where-Object { $_.Headers.ContainsKey('anthropic-version') }).Count -gt 0)

# F22 Responses 协议
$respUrl = $mock.BaseUrl + '/v1/responses'
$j = Invoke-OneApi -Server $mock -Model 'm-vanilla' -Endpoint $respUrl -Kind 'Responses'
$row = New-ResultRow -Index 0 -Model 'm-vanilla' -Protocol 'Responses'
Fill-ResultRow -Row $row -Job $j -Kind 'Responses' -Secret $fakeKey
Assert-Equal 'F22 Responses 正常 -> OK' 'OK' $row.StatusShort
Assert-Equal 'F23 Responses 拿到 reasoning tokens' '3' $row.ReasoningTokens

# F24 本地超时
$j = Invoke-OneApi -Server $mock -Model 'm-slow' -Endpoint $chatUrl -TimeoutSec 1
$row = New-ResultRow -Index 0 -Model 'm-slow' -Protocol 'Chat'
Fill-ResultRow -Row $row -Job $j -Kind 'Chat' -Secret $fakeKey
Assert-Equal 'F24 本地超时 -> Timeout' 'Timeout' $row.StatusShort
Assert-True  'F25 超时耗时接近 1 秒' ([double]$j.LatencyMs -lt 2200 -and [double]$j.LatencyMs -ge 900) ('latency=' + [string]$j.LatencyMs)

# F26 绝不产生 /v1/v1
$doubleV1 = @(Get-MockRequestSummary -Server $mock | Where-Object { $_.Path -match '/v1/v1' })
Assert-Equal 'F26 假服务器从未收到 /v1/v1 请求' '0' $doubleV1.Count
$wrongScheme = @(Get-MockRequestSummary -Server $mock | Where-Object { $_.Path -notmatch '^/' })
Assert-Equal 'F27 所有请求路径合法' '0' $wrongScheme.Count

Remove-HttpEngine -Engine $engine

# ---------------------------------------------------------------- G Auto Detect
Section 'G. Auto Detect 探测'
$mockClaude = New-MockServer -Routes @{
    'POST /v1/messages' = @{
        Status = 200
        Json   = '{"id":"msg_1","type":"message","model":"claude-any","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":8,"output_tokens":3}}'
    }
}
$e = New-HttpEngine
$plan = New-DetectPlan -BaseUrl $mockClaude.BaseUrl -Model 'claude-any' -ApiKey $fakeKey -TimeoutSec 10 -Normalize
$d = New-DetectRun -Engine $e -Plan $plan -Concurrency 2
Complete-DetectWithMock -Server $mockClaude -Run $d | Out-Null
Assert-True  'G1 探测到 Anthropic' ($null -ne $d.Best -and $d.Best.Kind -eq 'Messages') ('best=' + $(if ($d.Best) { $d.Best.Kind } else { 'null' }))
Assert-True  'G2 探测请求数有界(<=6)' ($d.RequestCount -le 6) ('count=' + $d.RequestCount)
Assert-True  'G3 命中后提前停止' $d.EarlyStopped
Assert-True  'G4 未探测到双 /v1' (-not (Test-MockSawPath -Server $mockClaude -Path '/v1/v1/messages'))
Remove-HttpEngine -Engine $e
Stop-MockServer -Server $mockClaude

$mockChat = New-MockServer -Routes @{
    'POST /v1/chat/completions' = @{ Status = 200; Json = (Get-ChatOkJson 'x') }
}
$e = New-HttpEngine
$plan = New-DetectPlan -BaseUrl $mockChat.BaseUrl -Model 'x' -ApiKey $fakeKey -TimeoutSec 10 -Normalize
$d = New-DetectRun -Engine $e -Plan $plan -Concurrency 2
Complete-DetectWithMock -Server $mockChat -Run $d | Out-Null
Assert-True  'G5 探测到 OpenAI Chat' ($null -ne $d.Best -and $d.Best.Kind -eq 'Chat') ('best=' + $(if ($d.Best) { $d.Best.Kind } else { 'null' }))
Assert-True  'G6 首个候选即命中（请求数有界）' ($d.RequestCount -le 2) ('count=' + $d.RequestCount)
Assert-True  'G6b 命中后没有把 6 个候选全打完' (@($mockChat.Requests).Count -le 3) ('received=' + @($mockChat.Requests).Count)
Remove-HttpEngine -Engine $e
Stop-MockServer -Server $mockChat

$mockAuth = New-MockServer -Routes @{
    'POST /v1/chat/completions' = @{ Status = 401; Json = '{"error":{"message":"Invalid API key provided"}}' }
}
$e = New-HttpEngine
$plan = New-DetectPlan -BaseUrl $mockAuth.BaseUrl -Model 'x' -ApiKey $fakeKey -TimeoutSec 10 -Normalize
$d = New-DetectRun -Engine $e -Plan $plan -Concurrency 2
Complete-DetectWithMock -Server $mockAuth -Run $d | Out-Null
Assert-True  'G7 401 也能定位到路由' ($null -ne $d.Best -and $d.Best.Kind -eq 'Chat') ('best=' + $(if ($d.Best) { $d.Best.Kind } else { 'null' }))
Remove-HttpEngine -Engine $e
Stop-MockServer -Server $mockAuth

$e = New-HttpEngine
$plan = New-DetectPlan -BaseUrl $mock.BaseUrl -Model 'm-vanilla' -ApiKey $fakeKey -TimeoutSec 10 -Normalize
$d = New-DetectRun -Engine $e -Plan $plan -Concurrency 2
Complete-DetectWithMock -Server $mock -Run $d | Out-Null
Assert-True  'G8 主假服务器探测到 Chat' ($null -ne $d.Best -and $d.Best.Kind -eq 'Chat')
Remove-HttpEngine -Engine $e

# ---------------------------------------------------------------- H 并发
Section 'H. 并发上限'
# 用一台全新的假服务器：并发计数必须干净，不能受前面超时测试遗留请求的干扰
$mockH = New-MockServer -Routes @{
    'POST /v1/chat/completions' = @{ Status = 200; Json = (Get-ChatOkJson 'm-multi'); DelayMs = 120 }
}
$hUrl = $mockH.BaseUrl + '/v1/chat/completions'
$e = New-HttpEngine
$models = @()
for ($i = 1; $i -le 12; $i++) { $models += 'm-multi' }
$run = New-ApiTestRun -Engine $e -Models $models -Kind 'Chat' -ApiKey $fakeKey -EndpointUrl $hUrl -Concurrency 3 -TimeoutSec 30
$elapsed = Complete-RunWithMock -Server $mockH -Run $run -TimeoutMs 60000
Assert-Equal 'H1 12 个请求全部完成' '12' $run.CompletedCount
Assert-True  'H2 假服务器观测到的并发 <= 3' ($mockH.MaxConcurrent -le 3) ('max=' + $mockH.MaxConcurrent)
Assert-Equal 'H3 并发确实被用满' '3' $mockH.MaxConcurrent
Assert-True  'H4 引擎峰值 <= 3' ($e.PeakConcurrency -le 3) ('peak=' + $e.PeakConcurrency)
Assert-True  'H5 串行耗时明显长于并发' ($elapsed -lt 1200) ('elapsed=' + [int]$elapsed + 'ms (12 x 120ms 串行应 ≈1440ms)')
Remove-HttpEngine -Engine $e
Stop-MockServer -Server $mockH

# ---------------------------------------------------------------- I Stop
Section 'I. Stop'
$e = New-HttpEngine
$models = @()
for ($i = 1; $i -le 24; $i++) { $models += 'm-stop' }
$run = New-ApiTestRun -Engine $e -Models $models -Kind 'Chat' -ApiKey $fakeKey -EndpointUrl $chatUrl -Concurrency 3 -TimeoutSec 60
$swStop = [System.Diagnostics.Stopwatch]::StartNew()
$stoppedAt = $false
while ($true) {
    Update-MockServer -Server $mock
    $r = Update-ApiTestRun -Run $run
    if (-not $stoppedAt -and $swStop.Elapsed.TotalMilliseconds -ge 250) {
        Stop-ApiTestRun -Run $run
        $stoppedAt = $true
    }
    if ($stoppedAt -and $r.Finished) { break }
    if ($swStop.Elapsed.TotalMilliseconds -gt 8000) { break }
    Start-Sleep -Milliseconds 3
}
$elapsedStop = $swStop.Elapsed.TotalMilliseconds
$cancelCount = @($run.Rows | Where-Object { $_.StatusShort -eq 'Cancelled' }).Count
$doneCount = @($run.Rows | Where-Object { $_.Done }).Count
Assert-True  'I1 Stop 后剩余全部标记 Cancelled' ($doneCount -eq 24) ('done=' + $doneCount)
Assert-True  'I2 大量请求被取消' ($cancelCount -ge 18) ('cancelled=' + $cancelCount)
Assert-True  'I3 Stop 后立刻收尾(<2.5s)' ($elapsedStop -lt 2500) ('elapsed=' + [int]$elapsedStop + 'ms')
Assert-Equal 'I4 无任何未完成行' '0' @($run.Rows | Where-Object { -not $_.Done }).Count
Assert-True  'I5 在飞任务被真正中止' ($run.Batch.InFlight.Count -eq 0)
Remove-HttpEngine -Engine $e

# ---------------------------------------------------------------- J 不落盘
Section 'J. 密钥不落盘'
$settingsPath = Get-SettingsPath
$settingsBackup = $null
if (Test-Path $settingsPath) { $settingsBackup = [System.IO.File]::ReadAllText($settingsPath) }

$cfg = New-DefaultSettings
$cfg['baseUrl'] = 'https://example.invalid'
$cfg['concurrency'] = 7
$cfg['apiKey'] = $fakeKey          # 白名单外 -> 必须被丢弃
$cfg['token'] = $fakeKey
$saved = Save-AppSettings -Settings $cfg
Assert-True  'J1 配置保存成功' $saved
$raw = [System.IO.File]::ReadAllText($settingsPath)
Assert-NotContains 'J2 配置文件中没有 apiKey' $raw $fakeKey
Assert-NotContains 'J3 配置文件里没有 token 字段' $raw '"token"'
Assert-Contains    'J4 非敏感项确实写入了' $raw 'example.invalid'

$back = Read-AppSettings
Assert-Equal 'J5 配置回读 concurrency' '7' $back['concurrency']
Assert-Equal 'J6 配置回读 baseUrl' 'https://example.invalid' $back['baseUrl']

# 报告 / CSV 不含 key
$rows = @()
foreach ($m in @('m-vanilla', 'm-401', 'm-empty')) {
    $j = Invoke-OneApi -Server $mock -Model $m -Endpoint $chatUrl
    $row = New-ResultRow -Index 0 -Model $m -Protocol 'Chat'
    Fill-ResultRow -Row $row -Job $j -Kind 'Chat' -Secret $fakeKey
    $rows += (Get-RowResult -Row $row)
}
$repBig = Format-ReportTable -Rows $rows -BaseUrl ('https://abc.com?api_key=' + $fakeKey) -Protocol 'Auto Detect' -Secret $fakeKey
$csv = Get-CsvText -Rows $rows
Assert-NotContains 'J7 报告不含 key' $repBig $fakeKey
Assert-NotContains 'J8 CSV 不含 key' $csv $fakeKey
Assert-Contains    'J9 报告里 URL 中的 key 被遮挡' $repBig 'sk-amt...'
Assert-Contains    'J10 CSV 表头正确' $csv 'Model,ReturnedModel,Protocol,Endpoint,HTTP,Status'
Assert-Contains    'J11 报告含表格头' $repBig 'Latency'

# 报告文本本身也不允许出现 key（避免自检报告成为泄漏渠道）
$accumulated = ($Script:OutLines -join "`n")
Assert-NotContains 'J12 自检报告文本不含 key' $accumulated $fakeKey

# 全盘扫描
$scanParent = ''
if ($OutFile) { $scanParent = Split-Path -Parent $OutFile }
$scanDirs = @(
    $Script:Root
    (Join-Path $env:LOCALAPPDATA 'ApiModelTester')
    $scanParent
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

$hits = New-Object System.Collections.ArrayList
foreach ($d in $scanDirs) {
    foreach ($f in @(Get-ChildItem -Path $d -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.Length -gt (8 * 1024 * 1024)) { continue }
        try {
            $txt = [System.IO.File]::ReadAllText($f.FullName)
            if ($txt.IndexOf($fakeKey, [StringComparison]::Ordinal) -ge 0) { [void]$hits.Add($f.FullName) }
        } catch { }
    }
}
Assert-True 'J13 扫描目录中没有 key 明文' ($hits.Count -eq 0) (($scanDirs -join '; ') + ' -> ' + ($hits -join '; '))
if ($settingsBackup -ne $null) {
    [void](Write-Utf8File -Path $settingsPath -Text $settingsBackup)
} else {
    try { if (Test-Path $settingsPath) { [System.IO.File]::Delete($settingsPath) } } catch { }
}

# ---------------------------------------------------------------- K 报告
Section 'K. 报告与 CSV 结构'
$sample = @(
    (Get-RowResult -Row (New-ResultRow -Index 0 -Model 'gpt-5.6-sol' -Protocol 'Chat')),
    (Get-RowResult -Row (New-ResultRow -Index 1 -Model 'gpt-6-astra' -Protocol 'Chat'))
)
$sample[0].Status = 'OK'; $sample[0].StatusShort = 'OK'; $sample[0].Http = 200; $sample[0].LatencyMs = 2300; $sample[0].ReturnedModel = 'gpt-5.6-sol'
$sample[1].Status = 'Rate Limited / quota exhausted'; $sample[1].StatusShort = 'RateLimit'; $sample[1].Http = 429; $sample[1].LatencyMs = 1800; $sample[1].ReturnedModel = 'gpt-6-astra'
$rep = Format-ReportTable -Rows $sample -BaseUrl 'https://abc.com/v1' -Protocol 'Auto Detect'
Write-Line ''
foreach ($l in ($rep -split "`r`n")) { Write-Line ('    ' + $l) }
Assert-Contains 'K1 报告含 OK 行' $rep 'gpt-5.6-sol'
Assert-Contains 'K2 报告含 RateLimit 行' $rep 'RateLimit'
Assert-Contains 'K3 报告含 Summary' $rep 'Summary'
$csvSample = Get-CsvText -Rows $sample
Assert-NotContains 'K4 CSV 不含换行污染' $csvSample "`n`n"
Assert-True 'K5 CSV 行数正确' ((@($csvSample -split "`r`n" | Where-Object { $_ -ne '' })).Count -eq 3)

# ---------------------------------------------------------------- 收尾
Stop-MockServer -Server $mock

$total = $Script:Pass + $Script:Fail
Write-Line ''
Write-Line '=================================================='
Write-Line ('  TOTAL ' + $total + '   PASS ' + $Script:Pass + '   FAIL ' + $Script:Fail)
Write-Line '=================================================='

$finalText = ($Script:OutLines -join "`r`n")
if ($OutFile -and $OutFile -ne '') {
    [void](Write-Utf8File -Path $OutFile -Text $finalText)
}
$jsonPath = [System.IO.Path]::ChangeExtension($OutFile, '.json')
if ($OutFile -and $OutFile -ne '') {
    $summary = @{
        time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        psVersion = $PSVersionTable.PSVersion.ToString()
        edition = $PSVersionTable.PSEdition
        total = $total; pass = $Script:Pass; fail = $Script:Fail
        ok = ($Script:Fail -eq 0)
    } | ConvertTo-Json -Depth 3
    [void](Write-Utf8File -Path $jsonPath -Text $summary)
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host ('self-test finished: PASS=' + $Script:Pass + ' FAIL=' + $Script:Fail)
}
