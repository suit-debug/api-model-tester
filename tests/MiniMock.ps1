# ============================================================================
#  MiniMock.ps1  -  本地假 API 服务器（可以当练手靶子用）
#
#  用途：
#    1. 没有任何真实 key 时，也能把 Api Model Tester 的整套流程跑一遍看效果；
#    2. 排查「工具本身有没有问题」——假服务器的返回是确定的。
#
#  用法：
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests\MiniMock.ps1
#     它会在共享目录写一个 minimock.url，里面是 Base URL（例如 http://127.0.0.1:53xxx）
#     把这个地址填进界面的 Base URL，API Key 随便填，然后 Fetch Models -> Test All。
#
#  覆盖的返回形态：
#     demo-ok-*           200 + content "OK"
#     demo-sse            200 + text/event-stream
#     demo-warn-empty     200 但 content 为空        -> Compatibility Warning
#     demo-warn-reasoning 200 但只有 reasoning 内容  -> Compatibility Warning
#     demo-warn-nochoices 200 但缺 choices 字段      -> Compatibility Warning
#     demo-401/403/404/429/500/502/503/524 对应状态码
#     demo-slow           延迟 5 秒（用来看 Timeout 与 Stop）
#     demo-anthropic      /v1/messages 正常返回
# ============================================================================

param(
    [int]$Port = 0,
    [int]$RunSeconds = 0
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Core.ps1')
. (Join-Path $PSScriptRoot 'MockServer.ps1')
Import-NetAssemblies -Name @('System.Net.Http') | Out-Null

function Get-DemoChatBody {
    param([string]$Model, [string]$Content = 'OK')
    return ('{"id":"cmpl-demo","object":"chat.completion","model":"' + $Model + '","choices":[{' +
            '"index":0,"message":{"role":"assistant","content":"' + $Content + '"},"finish_reason":"stop"}],' +
            '"usage":{"prompt_tokens":9,"completion_tokens":3,"total_tokens":12,' +
            '"completion_tokens_details":{"reasoning_tokens":0}}}')
}

function Get-DemoSpec {
    param($req)

    $m = ''
    try { $m = [string]((ConvertFrom-Json $req.Body).model) } catch { $m = '' }
    $isMessages = ($req.Path -match 'messages')
    $isResponses = ($req.Path -match 'responses')

    if ($m -match '^demo-anthropic' -and -not $isMessages) { $isMessages = $true }

    if ($isMessages) {
        if ($m -match '^demo-401') { return @{ Status = 401; Json = '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key (demo)"}}' } }
        return @{ Status = 200; Json = ('{"id":"msg_demo","type":"message","role":"assistant","model":"' + $m + '",' +
                 '"content":[{"type":"thinking","thinking":"demo thinking"},{"type":"text","text":"OK"}],' +
                 '"stop_reason":"end_turn","usage":{"input_tokens":11,"output_tokens":5}}') }
    }
    if ($isResponses) {
        return @{ Status = 200; Json = ('{"id":"resp_demo","object":"response","status":"completed","model":"' + $m + '",' +
                 '"output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"demo reasoning"}]},' +
                 '{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}],' +
                 '"usage":{"input_tokens":8,"output_tokens":6,"output_tokens_details":{"reasoning_tokens":4}}}') }
    }

    switch -Regex ($m) {
        '^demo-401$'           { return @{ Status = 401; Json = '{"error":{"message":"Invalid API key provided (demo)","type":"authentication_error"}}' } }
        '^demo-403$'           { return @{ Status = 403; Json = '{"error":{"message":"permission denied for this model (demo)"}}' } }
        '^demo-404$'           { return @{ Status = 404; Json = ('{"error":{"message":"The model `' + $m + '` does not exist"}}') } }
        '^demo-429$'           { return @{ Status = 429; Json = '{"error":{"message":"Rate limit reached (demo)","type":"rate_limit_error"}}' } }
        '^demo-500$'           { return @{ Status = 500; Json = '{"error":{"message":"internal server error (demo)"}}' } }
        '^demo-502$'           { return @{ Status = 502; Json = '{"error":{"message":"bad gateway (demo)"}}' } }
        '^demo-503$'           { return @{ Status = 503; Json = '{"error":{"message":"service unavailable (demo)"}}' } }
        '^demo-524$'           { return @{ Status = 524; Json = '{"error":{"message":"upstream timeout (demo)"}}' } }
        '^demo-warn-empty$'    { return @{ Status = 200; Json = (Get-DemoChatBody $m '') } }
        '^demo-warn-reasoning$' {
            return @{ Status = 200; Json = ('{"object":"chat.completion","model":"' + $m + '","choices":[{"index":0,' +
                     '"message":{"role":"assistant","content":"","reasoning_content":"I thought about it for a while"},"finish_reason":"stop"}],' +
                     '"usage":{"completion_tokens":40,"completion_tokens_details":{"reasoning_tokens":40}}}') }
        }
        '^demo-warn-nochoices$' { return @{ Status = 200; Json = ('{"object":"chat.completion","model":"' + $m + '","usage":{"total_tokens":9}}') } }
        '^demo-sse$' {
            $sse = "data: {`"choices`":[{`"delta`":{`"content`":`"O`"}}]}`n`n" +
                   "data: {`"choices`":[{`"delta`":{`"content`":`"K`"}}]}`n`n" +
                   "data: {`"choices`":[{`"delta`":{},`"finish_reason`":`"stop`"}]}`n`n" +
                   "data: [DONE]`n`n"
            return @{ Status = 200; Body = $sse; ContentType = 'text/event-stream' }
        }
        '^demo-slow$'          { return @{ Status = 200; Json = (Get-DemoChatBody $m); DelayMs = 5000 } }
    }
    return @{ Status = 200; Json = (Get-DemoChatBody $m) }
}

$routes = @{}
$routes['GET /v1/models'] = @{
    Status = 200
    Json   = '{"object":"list","data":[' +
             '{"id":"demo-ok-alpha"},{"id":"demo-ok-beta"},{"id":"demo-sse"},' +
             '{"id":"demo-warn-empty"},{"id":"demo-warn-reasoning"},{"id":"demo-warn-nochoices"},' +
             '{"id":"demo-404"},{"id":"demo-429"},{"id":"demo-500"},{"id":"demo-slow"},{"id":"demo-anthropic-1"}]}'
}
foreach ($p in @('/v1/chat/completions', '/chat/completions', '/v1/responses', '/responses', '/v1/messages', '/messages')) {
    $routes['POST ' + $p] = @{ Script = { param($r) Get-DemoSpec $r } }
}

$mock = New-MockServer -Routes $routes
if ($Port -gt 0) {
    try {
        $mock.Listener.Stop()
        $mock.Listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $mock.Listener.Start()
        $mock.Port = $Port
        $mock.BaseUrl = 'http://127.0.0.1:' + $Port
        $mock.AcceptTask = $mock.Listener.AcceptTcpClientAsync()
    } catch {
        Write-Host ('端口 ' + $Port + ' 占用，改用随机端口')
    }
}

$readyFile = Join-Path $PSScriptRoot 'minimock.url'
[System.IO.File]::WriteAllText($readyFile, $mock.BaseUrl, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'MiniMock 已启动（本地假 API，无任何真实网络请求）'
Write-Host ('  Base URL : ' + $mock.BaseUrl)
Write-Host ('  提示文件 : ' + $readyFile)
Write-Host '  模型列表 : demo-ok-alpha / demo-ok-beta / demo-sse / demo-warn-* / demo-404 / demo-429 / demo-500 / demo-slow / demo-anthropic-1'
Write-Host '  在界面上把 Base URL 填成上面的地址，API Key 随便填，然后 Fetch Models -> Test All'
Write-Host '  按 Ctrl+C 结束'
Write-Host ''

$reqLog = Join-Path $PSScriptRoot 'minimock.requests.txt'
try { if (Test-Path $reqLog) { [System.IO.File]::Delete($reqLog) } } catch { }
$lastReqCount = 0

$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($true) {
    Update-MockServer -Server $mock

    # 把收到的请求落盘，方便事后核对界面到底发了什么
    if ($mock.Requests.Count -gt $lastReqCount) {
        $sb = New-Object System.Text.StringBuilder
        for ($i = $lastReqCount; $i -lt $mock.Requests.Count; $i++) {
            $rq = $mock.Requests[$i]
            $model = ''
            try { $model = [string]((ConvertFrom-Json $rq.Body).model) } catch { $model = '' }
            [void]$sb.Append(('{0,-6} {1,-28} model={2}  auth={3}  xapikey={4}' -f
                $rq.Method, $rq.Path, $model,
                $rq.Headers.ContainsKey('authorization'), $rq.Headers.ContainsKey('x-api-key')) + "`r`n")
        }
        $lastReqCount = $mock.Requests.Count
        try { [System.IO.File]::AppendAllText($reqLog, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }

    Start-Sleep -Milliseconds 3
    if ($RunSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -gt $RunSeconds) { break }
}
try { [System.IO.File]::Delete($readyFile) } catch { }
Stop-MockServer -Server $mock
