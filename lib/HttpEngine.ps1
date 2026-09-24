# ============================================================================
#  HttpEngine.ps1  -  轮询式异步 HTTP 引擎
#
#  设计要点（为满足「UI 不卡死 + 并发上限 + Stop 有效」而刻意选择的方案）：
#   1. 全部网络 I/O 由 .NET 的异步 API 抛出，交给 IO 完成端口；本进程不占线程。
#   2. 主线程（WinForms UI 线程 / 测试循环）只做「轮询 IsCompleted」，不做阻塞等待。
#   3. 因此不需要后台 Runspace、不需要编译 C#、不需要 Start-Job —— 零依赖且无跨线程状态。
#   4. 并发上限用「在飞任务数 <= Concurrency」的补位算法实现（等效 SemaphoreSlim 语义）。
#   5. 本地超时由我们自己的 Stopwatch 判定，Reason 只有一处赋值，语义不会和 Stop 混淆。
# ============================================================================

function Get-ResponseHeadersReadOption {
    return [System.Enum]::Parse([System.Net.Http.HttpCompletionOption], 'ResponseHeadersRead', $true)
}

function New-HttpClientPool {
    param([int]$MaxConnections = 32)

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    try {
        $handler.AutomaticDecompression = ([System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate)
    } catch { }

    $client = New-Object System.Net.Http.HttpClient($handler)
    # 超时全部由本引擎自己控制（便于区分 Timeout / Cancelled）
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    try { $client.DefaultRequestHeaders.Add('User-Agent', $Script:AMT_USER_AGENT) } catch { }

    return $client
}

function New-HttpEngine {
    <#  每次「运行一批测试」都新建引擎，Stop 后不复用  #>
    param([int]$MaxConnections = 32)

    $cts = New-Object System.Threading.CancellationTokenSource
    $engine = [pscustomobject]@{
        Client            = (New-HttpClientPool -MaxConnections $MaxConnections)
        StopCts           = $cts
        StopToken         = $cts.Token
        HeadersReadOption = (Get-ResponseHeadersReadOption)
        StartedCount      = 0
        CompletedCount    = 0
        PeakConcurrency   = 0
        Secret            = ''
    }
    return $engine
}

function Remove-HttpEngine {
    param($Engine)
    if ($null -eq $Engine) { return }
    try { if ($Engine.Client) { $Engine.Client.Dispose() } } catch { }
    try { if ($Engine.StopCts) { $Engine.StopCts.Dispose() } } catch { }
    $Engine.Client = $null
    $Engine.StopCts = $null
}

function New-HttpJob {
    param(
        [string]$Id,
        [string]$Kind = 'Api',                 # 'Models' | 'Api'
        [string]$Label = '',
        [string]$Url,
        [string]$Method = 'GET',
        [string]$Body = '',
        [object[]]$Headers = @(),
        [int]$TimeoutSec = 30,
        [int]$RowIndex = -1,
        [string]$ProtocolKind = 'Chat',
        [hashtable]$Meta = $null,
        [int]$Attempt = 1
    )

    if ($null -eq $Meta) { $Meta = @{} }

    return [pscustomobject]@{
        Id           = $Id
        Kind         = $Kind
        Label        = $Label
        Url          = $Url
        Method       = $Method
        Body         = $Body
        Headers      = $Headers
        TimeoutSec   = $TimeoutSec
        RowIndex     = $RowIndex
        ProtocolKind = $ProtocolKind
        Meta         = $Meta
        Attempt      = $Attempt
        Stage        = 'New'
        Reason       = ''
        Sw           = $null
        Cts          = $null
        Req          = $null
        Resp         = $null
        SendTask     = $null
        ReadTask     = $null
        Http         = 0
        RespBody     = ''
        ContentType  = ''
        FinalUrl     = ''
        TtfbMs       = $null
        LatencyMs    = $null
        ErrorType    = ''
        ErrorMessage = ''
        Done         = $false
    }
}

function Start-HttpJob {
    param($Engine, $Job)

    try {
        $Job.Cts = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($Engine.StopToken)
        $Job.Sw = [System.Diagnostics.Stopwatch]::StartNew()

        $method = [System.Net.Http.HttpMethod]::Get
        if ($Job.Method -ieq 'POST') { $method = [System.Net.Http.HttpMethod]::Post }
        $uri = New-Object System.Uri($Job.Url)
        $req = New-Object System.Net.Http.HttpRequestMessage($method, $uri)

        foreach ($h in $Job.Headers) {
            [void]$req.Headers.TryAddWithoutValidation([string]$h.Name, [string]$h.Value)
        }
        if (-not [string]::IsNullOrEmpty($Job.Body)) {
            $req.Content = New-Object System.Net.Http.StringContent(
                $Job.Body, [System.Text.Encoding]::UTF8, 'application/json')
        }

        $Job.Req = $req
        $Job.Stage = 'Send'
        $Job.SendTask = $Engine.Client.SendAsync($req, $Engine.HeadersReadOption, $Job.Cts.Token)
        $Engine.StartedCount++
    } catch {
        $Job.Stage = 'Failed'
        $Job.ErrorType = 'Error'
        $Job.ErrorMessage = ('请求构造失败: ' + $_.Exception.Message)
        Complete-HttpJob -Job $Job
    }
    return $Job
}

function Complete-HttpJob {
    param(
        $Job,
        [string]$ErrorType = '',
        [string]$ErrorMessage = ''
    )

    if ($Job.Done) { return }

    if ($Job.Sw -and $null -eq $Job.LatencyMs) {
        $Job.LatencyMs = $Job.Sw.Elapsed.TotalMilliseconds
    }
    if ($ErrorType -ne '') { $Job.ErrorType = $ErrorType }
    if ($ErrorMessage -ne '') { $Job.ErrorMessage = $ErrorMessage }

    $Job.Stage = 'Done'
    $Job.Done = $true

    try { if ($Job.Cts) { $Job.Cts.Cancel() } } catch { }
    try { if ($Job.Cts) { $Job.Cts.Dispose() } } catch { }
    $Job.Cts = $null
    try { if ($Job.Resp) { $Job.Resp.Dispose() } } catch { }
    $Job.Resp = $null
    try { if ($Job.Req) { $Job.Req.Dispose() } } catch { }
    $Job.Req = $null
    $Job.SendTask = $null
    $Job.ReadTask = $null
}

function Update-HttpJob {
    <#  推进一步：返回 'Pending' 或 'Done'。绝不阻塞。  #>
    param($Engine, $Job)

    if ($Job.Done) { return 'Done' }

    # ---- 本地超时：整体请求时限，由本引擎独立判定 ----
    if ($Job.Sw -and $Job.TimeoutSec -gt 0) {
        if ($Job.Sw.Elapsed.TotalMilliseconds -gt ($Job.TimeoutSec * 1000)) {
            $Job.Reason = 'Timeout'
            Complete-HttpJob -Job $Job -ErrorType 'Timeout' `
                -ErrorMessage ('本地超时：超过 ' + $Job.TimeoutSec + ' 秒未完成（Timeout 设置）')
            return 'Done'
        }
    }

    if ($Job.Stage -eq 'Failed') {
        Complete-HttpJob -Job $Job
        return 'Done'
    }

    if ($Job.Stage -eq 'Send') {
        $t = $Job.SendTask
        if ($null -eq $t -or -not $t.IsCompleted) { return 'Pending' }

        if ($t.IsCanceled) {
            $reason = 'Cancelled'
            if ($Job.Reason -ne '') { $reason = $Job.Reason }
            if ($reason -eq 'Cancelled') {
                Complete-HttpJob -Job $Job -ErrorType 'Cancelled' -ErrorMessage '用户中止'
            } else {
                Complete-HttpJob -Job $Job -ErrorType $reason -ErrorMessage '请求超时或已中止'
            }
            return 'Done'
        }
        if ($t.IsFaulted) {
            $info = Classify-NetworkError $t.Exception
            Complete-HttpJob -Job $Job -ErrorType $info.Type -ErrorMessage $info.Message
            return 'Done'
        }

        $resp = $null
        try {
            $resp = $t.GetAwaiter().GetResult()
        } catch {
            $info = Classify-NetworkError $_.Exception
            Complete-HttpJob -Job $Job -ErrorType $info.Type -ErrorMessage $info.Message
            return 'Done'
        }

        $Job.Resp = $resp
        $Job.Http = [int]$resp.StatusCode
        $Job.TtfbMs = $Job.Sw.Elapsed.TotalMilliseconds
        try {
            if ($resp.RequestMessage -and $resp.RequestMessage.RequestUri) {
                $Job.FinalUrl = [string]$resp.RequestMessage.RequestUri
            }
        } catch { }
        try {
            if ($resp.Content -and $resp.Content.Headers.ContentType) {
                $ct = $resp.Content.Headers.ContentType
                $Job.ContentType = ([string]$ct.MediaType) + ''
                if ($ct.CharSet) { $Job.ContentType = $Job.ContentType + '; charset=' + [string]$ct.CharSet }
            }
        } catch { }

        if ($null -eq $resp.Content) {
            Complete-HttpJob -Job $Job
            return 'Done'
        }

        $Job.ReadTask = $resp.Content.ReadAsStringAsync()
        $Job.Stage = 'Read'
        return 'Pending'
    }

    if ($Job.Stage -eq 'Read') {
        $t = $Job.ReadTask
        if ($null -eq $t -or -not $t.IsCompleted) { return 'Pending' }

        if ($t.IsFaulted) {
            $info = Classify-NetworkError $t.Exception
            Complete-HttpJob -Job $Job -ErrorType $info.Type -ErrorMessage ('读取响应体失败: ' + $info.Message)
            return 'Done'
        }
        if ($t.IsCanceled) {
            $reason = 'Cancelled'
            if ($Job.Reason -ne '') { $reason = $Job.Reason }
            Complete-HttpJob -Job $Job -ErrorType $reason -ErrorMessage '响应体读取被中止'
            return 'Done'
        }

        $body = ''
        try {
            $body = [string]$t.GetAwaiter().GetResult()
        } catch {
            $info = Classify-NetworkError $_.Exception
            Complete-HttpJob -Job $Job -ErrorType $info.Type -ErrorMessage ('读取响应体失败: ' + $info.Message)
            return 'Done'
        }

        $Job.RespBody = $body
        $Job.LatencyMs = $Job.Sw.Elapsed.TotalMilliseconds
        Complete-HttpJob -Job $Job
        return 'Done'
    }

    Complete-HttpJob -Job $Job
    return 'Done'
}

# ---------------------------------------------------------------- 批调度
function New-HttpBatch {
    <#  Queue = 待发；InFlight = 在飞。Concurrency 决定在飞上限  #>
    param($Engine, [object[]]$Jobs, [int]$Concurrency = 3)

    $q = New-Object System.Collections.Queue
    foreach ($j in @($Jobs)) { $q.Enqueue($j) }

    return [pscustomobject]@{
        Engine      = $Engine
        Queue       = $q
        InFlight    = (New-Object System.Collections.ArrayList)
        Completed   = (New-Object System.Collections.ArrayList)
        Concurrency = [Math]::Max(1, $Concurrency)
        Peak        = 0
        Stopped     = $false
    }
}

function Update-HttpBatch {
    <#
      推进一步：先补位（保持并发上限），再轮询在飞任务。
      返回 @{ Finished; NewlyCompleted=@(); InFlight; Pending; Peak }
    #>
    param($Batch, [scriptblock]$OnJobStarted = $null)

    $newly = New-Object System.Collections.ArrayList

    if (-not $Batch.Stopped) {
        while (($Batch.InFlight.Count -lt $Batch.Concurrency) -and ($Batch.Queue.Count -gt 0)) {
            $job = $Batch.Queue.Dequeue()
            Start-HttpJob -Engine $Batch.Engine -Job $job | Out-Null
            [void]$Batch.InFlight.Add($job)
            if ($OnJobStarted) { & $OnJobStarted $job }
        }
    }

    if ($Batch.InFlight.Count -gt $Batch.Peak) { $Batch.Peak = $Batch.InFlight.Count }
    if ($Batch.Peak -gt $Batch.Engine.PeakConcurrency) { $Batch.Engine.PeakConcurrency = $Batch.Peak }

    for ($i = $Batch.InFlight.Count - 1; $i -ge 0; $i--) {
        $job = $Batch.InFlight[$i]
        if ((Update-HttpJob -Engine $Batch.Engine -Job $job) -eq 'Done') {
            $Batch.InFlight.RemoveAt($i)
            [void]$Batch.Completed.Add($job)
            [void]$newly.Add($job)
        }
    }

    $finished = ($Batch.InFlight.Count -eq 0) -and (($Batch.Queue.Count -eq 0) -or $Batch.Stopped)
    return @{
        Finished       = $finished
        NewlyCompleted = $newly.ToArray()
        InFlight       = $Batch.InFlight.Count
        Pending        = $Batch.Queue.Count
        Peak           = $Batch.Peak
    }
}

function Stop-HttpBatch {
    <#
      取消未开始的请求 + 中止在飞请求；返回被取消的 job 列表。
      仅逐个取消 job 的 CTS（不整体废掉 Engine），这样「探测命中提前停止」和
      「用户按 Stop」两种场景都不会污染后续阶段可用的连接池。
    #>
    param($Batch, [switch]$CancelEngine)

    $Batch.Stopped = $true
    $canceled = New-Object System.Collections.ArrayList

    while ($Batch.Queue.Count -gt 0) {
        $j = $Batch.Queue.Dequeue()
        $j.Done = $true
        $j.Stage = 'Done'
        $j.ErrorType = 'Cancelled'
        $j.ErrorMessage = '未开始即被中止'
        $j.Http = 0
        if ($null -ne $j.Sw) { $j.LatencyMs = $j.Sw.Elapsed.TotalMilliseconds }
        [void]$canceled.Add($j)
        [void]$Batch.Completed.Add($j)
    }

    foreach ($job in $Batch.InFlight) {
        if (-not $job.Done) {
            $job.Reason = 'Cancelled'
            try { if ($job.Cts) { $job.Cts.Cancel() } } catch { }
        }
    }

    if ($CancelEngine) {
        try { if ($Batch.Engine.StopCts) { $Batch.Engine.StopCts.Cancel() } } catch { }
    }

    return $canceled.ToArray()
}

function Invoke-HttpBatchBlocking {
    <#  非 UI 场景（自检 / 命令行）用的阻塞驱动  #>
    param($Batch, [int]$TimeoutMs = 180000, [int]$SleepMs = 5)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $r = Update-HttpBatch -Batch $Batch
        if ($r.Finished) { break }
        if ($sw.Elapsed.TotalMilliseconds -gt $TimeoutMs) { break }
        Start-Sleep -Milliseconds $SleepMs
    }
    return $Batch.Completed.ToArray()
}

function Invoke-HttpJobBlocking {
    <#  单请求阻塞执行（探测 / 取模型列表用）  #>
    param($Engine, $Job, [int]$TimeoutMs = 0)

    $jobs = @($Job)
    $batch = New-HttpBatch -Engine $Engine -Jobs $jobs -Concurrency 1
    $limit = $TimeoutMs
    if ($limit -le 0) { $limit = (($Job.TimeoutSec + 5) * 1000) }
    Invoke-HttpBatchBlocking -Batch $batch -TimeoutMs $limit | Out-Null
    return $Job
}
