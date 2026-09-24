# ============================================================================
#  MockServer.ps1  -  本地假 API 服务器（自检用，不联网、不需要管理员）
#
#  用 TcpListener 而不是 HttpListener，原因是 Windows 上 HttpListener 需要
#  管理员权限或 netsh urlacl 注册，TcpListener 直接监听 127.0.0.1 即可。
#  它同样用轮询方式驱动，因此不需要额外线程/进程。
#
#  路由表键： 'GET /v1/models'  或  '/v1/models'（不限方法，作为兜底）
#  路由值  ： 哈希表
#      Status      = 200
#      Json        = '{...}'        # 与 Body 二选一
#      Body        = 'raw text'
#      ContentType = 'application/json'
#      DelayMs     = 0              # 收到完整请求后延迟多久回包（用于超时/并发测试）
#      Headers     = @{ 'X-A' = '1' }
#      或 Script   = { param($req) @{ Status=...; Body=... } }
#     $req = @{ Method; Path; RawPath; Query; Headers(hashtable); Body; Raw }
# ============================================================================

function New-MockServer {
    param(
        [hashtable]$Routes = @{},
        [int]$DefaultDelayMs = 0
    )

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port

    $server = [pscustomobject]@{
        Listener       = $listener
        Port           = $port
        BaseUrl        = ('http://127.0.0.1:' + $port)
        AcceptTask     = $null
        Connections    = (New-Object System.Collections.ArrayList)
        Routes         = $Routes
        DefaultDelayMs = $DefaultDelayMs
        Requests       = (New-Object System.Collections.ArrayList)
        ActiveRequests = 0
        MaxConcurrent  = 0
        Closed         = $false
    }
    try { $server.AcceptTask = $listener.AcceptTcpClientAsync() } catch { $server.AcceptTask = $null }
    return $server
}

function Add-MockRoute {
    param($Server, [string]$Method, [string]$Path, $Spec)
    $key = $Path
    if ($Method -and $Method -ne '*') { $key = $Method.ToUpper() + ' ' + $Path }
    $Server.Routes[$key] = $Spec
}

function Stop-MockServer {
    param($Server)
    if ($null -eq $Server) { return }
    $Server.Closed = $true
    foreach ($c in $Server.Connections) {
        try { if ($c.Client) { $c.Client.Close() } } catch { }
    }
    try { $Server.Connections.Clear() } catch { }
    try { if ($Server.Listener) { $Server.Listener.Stop() } } catch { }
    $Server.ActiveRequests = 0
}

function Get-MockRequestSummary {
    param($Server)
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $Server.Requests) {
        [void]$out.Add([pscustomobject]@{
            Method  = $r.Method
            Path    = $r.Path
            Full    = $r.Method + ' ' + $r.RawPath
            Body    = $r.Body
            Headers = $r.Headers
        })
    }
    return $out.ToArray()
}

function Test-MockSawPath {
    param($Server, [string]$Path)
    foreach ($r in $Server.Requests) { if ($r.Path -eq $Path) { return $true } }
    return $false
}

# ---------------------------------------------------------------- 内部工具
function Get-MockHeaderEnd {
    param([byte[]]$Buf, [int]$Len)
    for ($i = 0; $i -le ($Len - 4); $i++) {
        if ($Buf[$i] -eq 13 -and $Buf[$i + 1] -eq 10 -and $Buf[$i + 2] -eq 13 -and $Buf[$i + 3] -eq 10) {
            return $i + 4
        }
    }
    return -1
}

function Convert-MockRequest {
    param([byte[]]$Buf, [int]$Len, [int]$HeaderEnd)
    $headerText = [System.Text.Encoding]::ASCII.GetString($Buf, 0, $HeaderEnd)
    $lines = $headerText -split "`r`n"
    $requestLine = $lines[0]
    $parts = $requestLine -split ' '
    $method = 'GET'; $rawPath = '/'
    if ($parts.Count -ge 2) { $method = $parts[0]; $rawPath = $parts[1] }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ([string]::IsNullOrEmpty($l)) { continue }
        $idx = $l.IndexOf(':')
        if ($idx -le 0) { continue }
        $k = $l.Substring(0, $idx).Trim().ToLowerInvariant()
        $v = $l.Substring($idx + 1).Trim()
        if ($headers.ContainsKey($k)) { $headers[$k] = $headers[$k] + ', ' + $v }
        else { $headers[$k] = $v }
    }

    $body = ''
    if ($Len -gt $HeaderEnd) {
        $body = [System.Text.Encoding]::UTF8.GetString($Buf, $HeaderEnd, $Len - $HeaderEnd)
    }

    $path = $rawPath
    $query = ''
    $qi = $rawPath.IndexOf('?')
    if ($qi -ge 0) { $path = $rawPath.Substring(0, $qi); $query = $rawPath.Substring($qi + 1) }

    return @{
        Method  = $method.ToUpper()
        Path    = $path
        RawPath = $rawPath
        Query   = $query
        Headers = $headers
        Body    = $body
        Raw     = $headerText + $body
    }
}

function Get-MockResponseSpec {
    param($Server, $Req)
    $key = $Req.Method + ' ' + $Req.Path
    $spec = $null
    if ($Server.Routes.ContainsKey($key)) { $spec = $Server.Routes[$key] }
    elseif ($Server.Routes.ContainsKey($Req.Path)) { $spec = $Server.Routes[$Req.Path] }
    elseif ($Server.Routes.ContainsKey($Req.Method + ' *')) { $spec = $Server.Routes[$Req.Method + ' *'] }
    elseif ($Server.Routes.ContainsKey('*')) { $spec = $Server.Routes['*'] }

    if ($null -ne $spec -and $spec.ContainsKey('Script')) {
        $spec = & $spec['Script'] $Req
    }
    if ($null -eq $spec) {
        $spec = @{
            Status      = 404
            ContentType = 'application/json'
            Json        = '{"error":{"message":"mock route not found","path":"' + $Req.Path + '","type":"not_found"}}'
        }
    }
    return $spec
}

function Send-MockResponse {
    param($Conn, $Spec)
    $status = 200
    if ($Spec.ContainsKey('Status')) { $status = [int]$Spec['Status'] }

    $ctype = 'application/json'
    if ($Spec.ContainsKey('ContentType')) { $ctype = [string]$Spec['ContentType'] }

    $bodyText = ''
    if ($Spec.ContainsKey('Json')) { $bodyText = [string]$Spec['Json'] }
    elseif ($Spec.ContainsKey('Body')) { $bodyText = [string]$Spec['Body'] }

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)

    $reason = 'Status'
    switch ($status) {
        200 { $reason = 'OK' }
        400 { $reason = 'Bad Request' }
        401 { $reason = 'Unauthorized' }
        403 { $reason = 'Forbidden' }
        404 { $reason = 'Not Found' }
        408 { $reason = 'Request Timeout' }
        429 { $reason = 'Too Many Requests' }
        500 { $reason = 'Internal Server Error' }
        502 { $reason = 'Bad Gateway' }
        503 { $reason = 'Service Unavailable' }
        524 { $reason = 'A Timeout Occurred' }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $status $reason`r`n")
    [void]$sb.Append("Content-Type: $ctype`r`n")
    [void]$sb.Append("Content-Length: $($bodyBytes.Length)`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    if ($Spec.ContainsKey('Headers')) {
        foreach ($k in $Spec['Headers'].Keys) {
            [void]$sb.Append([string]$k + ': ' + [string]$Spec['Headers'][$k] + "`r`n")
        }
    }
    [void]$sb.Append("Connection: close`r`n`r`n")

    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $all = New-Object byte[] ($headBytes.Length + $bodyBytes.Length)
    [System.Array]::Copy($headBytes, 0, $all, 0, $headBytes.Length)
    [System.Array]::Copy($bodyBytes, 0, $all, $headBytes.Length, $bodyBytes.Length)

    try {
        $Conn.Stream.Write($all, 0, $all.Length)
        $Conn.Stream.Flush()
    } catch { }
    $Conn.Sent = $true
}

function Update-MockServer {
    <#
      连接状态机： Reading -> Scheduled -> Closing -> 回收
      每个连接只在自己的阶段被处理一次，不存在重复发送/重复计数。
    #>
    param($Server)

    if ($Server.Closed) { return }

    # ---- 接受新连接 ----
    if ($null -ne $Server.AcceptTask -and $Server.AcceptTask.IsCompleted) {
        $client = $null
        try { $client = $Server.AcceptTask.Result } catch { $client = $null }
        if ($null -ne $client) {
            try { $client.NoDelay = $true } catch { }
            $conn = [pscustomobject]@{
                Client       = $client
                Stream       = $client.GetStream()
                Buf          = (New-Object byte[] 65536)
                Len          = 0
                HeaderEnd    = -1
                ExpectLen    = 0
                ReadTask     = $null
                Stage        = 'Reading'
                RespondAt    = $null
                CloseAt      = $null
                ResponseSpec = $null
                Sent         = $false
                Req          = $null
                Counted      = $false
                Dead         = $false
            }
            $conn.ReadTask = $conn.Stream.ReadAsync($conn.Buf, 0, $conn.Buf.Length)
            [void]$Server.Connections.Add($conn)
        }
        try { $Server.AcceptTask = $Server.Listener.AcceptTcpClientAsync() } catch { $Server.AcceptTask = $null }
    }

    $now = [DateTime]::UtcNow

    for ($i = $Server.Connections.Count - 1; $i -ge 0; $i--) {
        $conn = $Server.Connections[$i]

        # ---- Reading ----
        if ($conn.Stage -eq 'Reading' -and $null -ne $conn.ReadTask -and $conn.ReadTask.IsCompleted) {
            $n = 0
            try { $n = [int]$conn.ReadTask.Result } catch { $n = -1 }
            if ($n -le 0) {
                $conn.Dead = $true
            } else {
                $conn.Len += $n
                if ($conn.HeaderEnd -lt 0) {
                    $he = Get-MockHeaderEnd -Buf $conn.Buf -Len $conn.Len
                    if ($he -gt 0) {
                        $conn.HeaderEnd = $he
                        # 先只解析头部，用于算出「完整请求」的期望长度
                        $headReq = Convert-MockRequest -Buf $conn.Buf -Len $he -HeaderEnd $he
                        $cl = 0
                        if ($headReq.Headers.ContainsKey('content-length')) {
                            try { $cl = [int]$headReq.Headers['content-length'] } catch { $cl = 0 }
                        }
                        $conn.ExpectLen = $he + $cl
                    }
                }

                if ($conn.HeaderEnd -gt 0 -and $conn.Len -ge $conn.ExpectLen) {
                    # 关键：body 可能和头部不在同一个 TCP 分段里到达。
                    # 必须在「完整收到」这一刻才解析 body 并登记请求，
                    # 否则 body 会丢（曾导致模型名解析为空、测试结果时好时坏）。
                    $conn.Req = Convert-MockRequest -Buf $conn.Buf -Len $conn.Len -HeaderEnd $conn.HeaderEnd
                    [void]$Server.Requests.Add($conn.Req)

                    $Server.ActiveRequests++
                    $conn.Counted = $true
                    if ($Server.ActiveRequests -gt $Server.MaxConcurrent) {
                        $Server.MaxConcurrent = $Server.ActiveRequests
                    }
                    $spec = Get-MockResponseSpec -Server $Server -Req $conn.Req
                    $conn.ResponseSpec = $spec
                    $delay = 0
                    if ($spec.ContainsKey('DelayMs')) { $delay = [int]$spec['DelayMs'] }
                    elseif ($Server.DefaultDelayMs -gt 0) { $delay = $Server.DefaultDelayMs }

                    if ($delay -gt 0) {
                        $conn.Stage = 'Scheduled'
                        $conn.RespondAt = $now.AddMilliseconds($delay)
                    } else {
                        try { Send-MockResponse -Conn $conn -Spec $spec } catch { $conn.Dead = $true }
                        $conn.Stage = 'Closing'
                        $conn.CloseAt = $now.AddMilliseconds(25)
                    }
                } else {
                    # 关键：必须追加到已收数据的后面（offset=$conn.Len）。
                    # 之前固定写 offset 0，body 若与头部不在同一个 TCP 分段，
                    # 就会覆盖掉头部，导致请求解析出垃圾（表现为时好时坏）。
                    $space = $conn.Buf.Length - $conn.Len
                    if ($space -le 0) {
                        $conn.Dead = $true
                    } else {
                        $conn.ReadTask = $conn.Stream.ReadAsync($conn.Buf, $conn.Len, $space)
                    }
                }
            }
        }

        # ---- Scheduled -> 到点回包 ----
        if ($conn.Stage -eq 'Scheduled' -and $now -ge $conn.RespondAt) {
            try { Send-MockResponse -Conn $conn -Spec $conn.ResponseSpec } catch { $conn.Dead = $true }
            $conn.Stage = 'Closing'
            $conn.CloseAt = $now.AddMilliseconds(25)
        }

        # ---- 关闭连接（回包完成立即归还在飞计数） ----
        if ($conn.Sent -and $conn.Counted) {
            $Server.ActiveRequests--
            $conn.Counted = $false
        }

        $doClose = $false
        if ($conn.Stage -eq 'Closing' -and $now -ge $conn.CloseAt) { $doClose = $true }
        if ($conn.Dead) { $doClose = $true }
        if ($doClose) {
            if ($conn.Counted) { $Server.ActiveRequests--; $conn.Counted = $false }
            try { $conn.Client.Close() } catch { }
            $Server.Connections.RemoveAt($i)
        }
    }
}

function Start-MockServerLoop {
    param($Server, [int]$Ms = 0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMilliseconds -lt $Ms) {
        Update-MockServer -Server $Server
        Start-Sleep -Milliseconds 3
    }
}
