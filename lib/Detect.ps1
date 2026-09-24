# ============================================================================
#  Detect.ps1  -  Auto Detect 探测计划 / 端点候选 / 重试决策
#  纯逻辑层：只构造 job 与打分，不发起网络请求
# ============================================================================

function Get-ProtocolPathKind {
    # 协议种类 -> Get-ApiCandidates 使用的 Kind
    param([string]$Kind)
    switch ($Kind) {
        'Chat'       { return 'Chat' }
        'Compatible' { return 'Chat' }
        'Responses'  { return 'Responses' }
        'Messages'   { return 'Messages' }
    }
    return 'Chat'
}

function Get-ApiUrlForAttempt {
    <#
      取标准形态或备用形态的端点地址。
      正常形态：优先 /v1/xxx（或用户 base 已含的形态）
      备用形态：另一种路径形态；若两个候选塌缩成同一个 URL，则显式去掉 /v1 段
    #>
    param(
        [string]$BaseUrl,
        [string]$Kind,
        [switch]$Normalize,
        [switch]$Alternate
    )

    $pathKind = Get-ProtocolPathKind -Kind $Kind
    $cands = @(Get-ApiCandidates -BaseUrl $BaseUrl -Kind $pathKind -Normalize:$Normalize)
    if ($cands.Count -eq 0) { return '' }
    if (-not $Alternate) { return $cands[0] }
    if ($cands.Count -gt 1) { return $cands[$cands.Count - 1] }

    $u = $cands[0]
    $m = [regex]::Match($u, '(?i)^(.*)/v1(/.*)$')
    if ($m.Success) { return ($m.Groups[1].Value + $m.Groups[2].Value) }
    return $u
}

function Get-ModelListCandidates {
    param([string]$BaseUrl, [switch]$Normalize)
    return @(Get-ApiCandidates -BaseUrl $BaseUrl -Kind 'Models' -Normalize:$Normalize)
}

function New-ApiTestJob {
    param(
        [string]$Id,
        [string]$Model,
        [string]$Kind,
        [string]$Url,
        [string]$ApiKey,
        [int]$TimeoutSec = 30,
        [int]$RowIndex = -1,
        [switch]$UseMaxCompletionTokens,
        [switch]$AnthropicBearer,
        [hashtable]$Meta = $null,
        [int]$Attempt = 1
    )

    $body = New-TestBody -Kind $Kind -Model $Model -UseMaxCompletionTokens:$UseMaxCompletionTokens
    $headers = Get-RequestHeaders -Kind $Kind -ApiKey $ApiKey -AnthropicBearer:$AnthropicBearer

    return New-HttpJob -Id $Id -Kind 'Api' -Label $Model -Url $Url -Method 'POST' -Body $body `
        -Headers $headers -TimeoutSec $TimeoutSec -RowIndex $RowIndex -ProtocolKind $Kind `
        -Meta $Meta -Attempt $Attempt
}

function New-ApiRetryJob {
    <#
      基于失败结果构造一个「只换一个变量」的重试 job。
      Reason 取值：max_completion_tokens | anthropic-bearer | alt-endpoint
    #>
    param(
        $Job,
        [string]$Reason,
        [string]$ApiKey,
        [int]$TimeoutSec = 30
    )

    $m = @{}
    if ($Job.Meta) { foreach ($k in $Job.Meta.Keys) { $m[$k] = $Job.Meta[$k] } }

    $maxct = [bool]$m['MaxCompletionTokens']
    $bearer = [bool]$m['AnthropicBearer']
    $alt = [bool]$m['AltEndpoint']
    $norm = $true
    if ($m.ContainsKey('Normalize')) { $norm = [bool]$m['Normalize'] }
    $baseUrl = [string]$m['BaseUrl']

    switch ($Reason) {
        'max_completion_tokens' { $maxct = $true }
        'anthropic-bearer'      { $bearer = $true }
        'alt-endpoint'          { $alt = $true }
    }
    $m['MaxCompletionTokens'] = $maxct
    $m['AnthropicBearer'] = $bearer
    $m['AltEndpoint'] = $alt
    $m['Normalize'] = $norm
    $m['BaseUrl'] = $baseUrl

    $kind = $Job.ProtocolKind
    $url = $Job.Url
    if ($Reason -eq 'alt-endpoint' -and $baseUrl -ne '') {
        $url = Get-ApiUrlForAttempt -BaseUrl $baseUrl -Kind $kind -Normalize:$norm -Alternate
    }

    return New-ApiTestJob -Id ($Job.Id + '-r' + ($Job.Attempt + 1)) -Model $Job.Label -Kind $kind `
        -Url $url -ApiKey $ApiKey -TimeoutSec $TimeoutSec -RowIndex $Job.RowIndex `
        -UseMaxCompletionTokens:$maxct -AnthropicBearer:$bearer -Meta $m -Attempt ($Job.Attempt + 1)
}

function Get-RetryDecision {
    <#
      判断一个已完成的 API job 是否值得重试。返回 @{ Reason; Note } 或 $null
      最多两个变量：先修参数兼容性，再换路径形态
    #>
    param($Job, [int]$AttemptsUsed = 1, [int]$MaxAttempts = 2)

    if ($AttemptsUsed -ge $MaxAttempts) { return $null }
    $kind = $Job.ProtocolKind
    $m = $Job.Meta
    if ($null -eq $m) { $m = @{} }

    if ($kind -eq 'Chat' -and -not [bool]$m['MaxCompletionTokens'] -and
        (Test-ShouldRetryWithMaxCompletionTokens $Job.Http $Job.RespBody)) {
        return @{ Reason = 'max_completion_tokens'; Note = '改用 max_completion_tokens 重试' }
    }
    if ($kind -eq 'Messages' -and -not [bool]$m['AnthropicBearer'] -and
        (Test-ShouldRetryAnthropicBearer $Job.Http $Job.RespBody)) {
        return @{ Reason = 'anthropic-bearer'; Note = '追加 Authorization: Bearer 重试' }
    }
    if (-not [bool]$m['AltEndpoint'] -and (Test-ShouldRetryAlternateEndpoint $Job.Http)) {
        return @{ Reason = 'alt-endpoint'; Note = '改用备用路径形态重试' }
    }
    return $null
}

function New-DetectPlan {
    <#
      Auto Detect 的探测计划（有界：最多 6 个 POST，命中即止）
      顺序：Chat -> Responses -> Anthropic，每个协议先正常形态再备用形态
      -PreferPlain：如果 /models 只在无 /v1 形态下可用，则优先探测无 /v1 形态
    #>
    param(
        [string]$BaseUrl,
        [string]$Model,
        [string]$ApiKey,
        [int]$TimeoutSec = 30,
        [switch]$Normalize,
        [switch]$PreferPlain
    )

    $kinds = @('Chat', 'Responses', 'Messages')
    $plan = New-Object System.Collections.ArrayList
    $planIndex = 0

    # 先跑一轮「规范形态」（/v1/...），再跑一轮「备用形态」。
    # 这样同一个并发窗口里的候选都在同一轮内，优先级由 PlanIndex 唯一确定，
    # 不会出现 /responses 抢在 /v1/responses 前面被选中的情况。
    $forms = @($false, $true)
    if ($PreferPlain) { $forms = @($true, $false) }

    foreach ($alt in $forms) {
        foreach ($kind in $kinds) {
            $url = Get-ApiUrlForAttempt -BaseUrl $BaseUrl -Kind $kind -Normalize:$Normalize -Alternate:$alt
            if ([string]::IsNullOrEmpty($url)) { continue }
            $dup = $false
            foreach ($j in $plan) { if ($j.Url -eq $url) { $dup = $true; break } }
            if ($dup) { continue }
            $job = New-ApiTestJob -Id ('probe-' + $kind + '-' + $(if ($alt) { 'alt' } else { 'std' })) `
                -Model $Model -Kind $kind -Url $url -ApiKey $ApiKey -TimeoutSec $TimeoutSec -RowIndex -1 `
                -Meta @{ BaseUrl = $BaseUrl; Normalize = [bool]$Normalize; AltEndpoint = $alt; PlanIndex = $planIndex }
            [void]$plan.Add($job)
            $planIndex++
        }
    }
    return $plan.ToArray()
}

function Get-ProbeOutcome {
    <#
      对一次探测结果打分：分值越高越像是「真正可用的端点」
        100 = 200 且有可用内容（命中，立即停止探测）
         95 = 200 但内容异常（端点确认存在，记录警告）
         55 = 200 但完全无内容
         45 = 429（限流说明路由存在）
         40/50 = 400/422（协议或参数不兼容，但路由存在；报错点名模型则 +10）
         35 = 401/403（路由存在，鉴权/协议头问题）
         10 = 5xx（路由可能存在，服务端异常）
          0 = 404/405/无法连接（视为路由不存在）
    #>
    param($Job, [string]$Model = '')

    $kind = $Job.ProtocolKind
    $res = $null
    if ($Job.Http -eq 200 -and [string]::IsNullOrEmpty($Job.ErrorType)) {
        $res = Read-ApiResult -Kind $kind -Body $Job.RespBody -ContentType $Job.ContentType
    } elseif ($Job.Http -gt 0) {
        $res = New-TestResult
        $res.HasError = $true
        $res.RemoteError = Get-RemoteErrorText $Job.RespBody
    }
    $verdict = Get-TestVerdict -Result $res -Http $Job.Http -ErrorType $Job.ErrorType `
        -ErrorMessage $Job.ErrorMessage -Kind $kind

    $score = 0
    if ($Job.Http -eq 200) {
        if ($verdict.Class -eq 'ok' -and $verdict.Rank -eq 0) { $score = 100 }
        elseif ($verdict.Class -eq 'ok') { $score = 95 }
        else { $score = 55 }
    } elseif ($Job.Http -eq 400 -or $Job.Http -eq 422) {
        $score = 40
        if ($Model -ne '' -and $Job.RespBody -and ($Job.RespBody.IndexOf($Model, [StringComparison]::OrdinalIgnoreCase) -ge 0)) { $score = 50 }
    } elseif ($Job.Http -eq 401 -or $Job.Http -eq 403) {
        $score = 35
    } elseif ($Job.Http -eq 429) {
        $score = 45
    } elseif ($Job.Http -ge 500) {
        $score = 10
    } else {
        $score = 0
    }

    $planIndex = 9999
    if ($Job.Meta -and $Job.Meta.ContainsKey('PlanIndex')) {
        try { $planIndex = [int]$Job.Meta['PlanIndex'] } catch { $planIndex = 9999 }
    }

    return [pscustomobject]@{
        Score     = $score
        Http      = $Job.Http
        Kind      = $kind
        Url       = $Job.Url
        PlanIndex = $planIndex
        Verdict   = $verdict
        Result    = $res
        ErrorType = $Job.ErrorType
        Error     = $Job.ErrorMessage
    }
}

function Select-BestProbe {
    <#
      稳定选择：分值最高者；同分取计划顺序更靠前的
      （计划顺序 = Chat -> Responses -> Messages，每个协议先 /v1 形态再备用形态）
      刻意不用「完成先后」做同分裁决 —— 并发完成顺序是随机的，
      否则同一套配置可能这次选 /v1/responses、下次选 /responses。
    #>
    param([object[]]$Outcomes)

    $best = $null
    foreach ($o in @($Outcomes)) {
        if ($o.Score -le 0) { continue }
        if ($null -eq $best) { $best = $o; continue }
        if ($o.Score -gt $best.Score) { $best = $o; continue }
        if ($o.Score -eq $best.Score -and $o.PlanIndex -lt $best.PlanIndex) { $best = $o }
    }
    return $best
}

# ---------------------------------------------------------------- 可轮询驱动器
# 下面两个驱动器把「多端点顺序尝试」和「有界探测」封装成 Tick 式状态机，
# UI 定时器与自检脚本共用同一份逻辑，避免行为漂移。

function New-FetchModelsRun {
    param(
        $Engine,
        [string[]]$Urls,
        [int]$TimeoutSec = 30,
        [object[]]$Headers = @()
    )
    return [pscustomobject]@{
        Engine     = $Engine
        Urls       = @($Urls)
        TimeoutSec = $TimeoutSec
        Headers    = $Headers
        Index      = -1
        Batch      = $null
        Current    = $null
        Done       = $false
        Stopped    = $false
        Ok         = $false
        Models     = @()
        Error      = ''
        UsedUrl    = ''
        Http       = 0
        Attempts   = (New-Object System.Collections.ArrayList)
    }
}

function Update-FetchModelsRun {
    <#  返回 @{ Finished; Ok; Models; Error; Url; Http; Raw }  #>
    param($Run)

    if ($Run.Done) {
        return @{ Finished = $true; Ok = $Run.Ok; Models = $Run.Models; Error = $Run.Error; Url = $Run.UsedUrl; Http = $Run.Http; Raw = '' }
    }

    if ($Run.Stopped) {
        $Run.Done = $true
        if ([string]::IsNullOrEmpty($Run.Error)) { $Run.Error = '用户中止' }
        return @{ Finished = $true; Ok = $false; Models = @(); Error = $Run.Error; Url = ''; Http = 0; Raw = '' }
    }

    if ($null -eq $Run.Batch) {
        $Run.Index++
        if ($Run.Index -ge $Run.Urls.Count) {
            $Run.Done = $true
            if ([string]::IsNullOrEmpty($Run.Error)) { $Run.Error = '所有候选端点都没有返回可用的模型列表' }
            return @{ Finished = $true; Ok = $Run.Ok; Models = $Run.Models; Error = $Run.Error; Url = $Run.UsedUrl; Http = $Run.Http; Raw = '' }
        }
        $job = New-HttpJob -Id ('models-' + $Run.Index) -Kind 'Models' -Label 'models' `
            -Url $Run.Urls[$Run.Index] -Method 'GET' -Headers $Run.Headers -TimeoutSec $Run.TimeoutSec
        $Run.Current = $job
        $Run.Batch = New-HttpBatch -Engine $Run.Engine -Jobs @($job) -Concurrency 1
        return @{ Finished = $false; InFlight = 1 }
    }

    $r = Update-HttpBatch -Batch $Run.Batch
    if (-not $r.Finished) {
        return @{ Finished = $false; InFlight = $r.InFlight }
    }

    $job = $Run.Current
    $Run.Batch = $null
    $parsed = $null
    if ($job.Http -eq 200) { $parsed = Read-ModelList $job.RespBody }

    if ($null -ne $parsed -and $parsed.Ok) {
        $Run.Ok = $true
        $Run.Models = $parsed.Models
        $Run.UsedUrl = $job.Url
        $Run.Http = $job.Http
        $Run.Error = ''
        $Run.Done = $true
        [void]$Run.Attempts.Add(@{ Url = $job.Url; Http = $job.Http; Ok = $true; Error = '' })
        return @{ Finished = $true; Ok = $true; Models = $Run.Models; Error = ''; Url = $Run.UsedUrl; Http = $job.Http; Raw = $job.RespBody }
    }

    $err = ''
    if ($job.Http -le 0) {
        $err = $job.ErrorType + ': ' + $job.ErrorMessage
    } elseif ($job.Http -ne 200) {
        $err = 'HTTP ' + $job.Http + ': ' + (Get-RemoteErrorText $job.RespBody)
    } elseif ($null -ne $parsed) {
        $err = 'HTTP 200 但内容不是模型列表: ' + $parsed.Error
    } else {
        $err = 'HTTP 200 但无法解析'
    }
    $Run.Error = $err
    $Run.Http = $job.Http
    [void]$Run.Attempts.Add(@{ Url = $job.Url; Http = $job.Http; Ok = $false; Error = $err })
    return @{ Finished = $false }
}

function New-DetectRun {
    param($Engine, [object[]]$Plan, [int]$Concurrency = 2)
    return [pscustomobject]@{
        Engine       = $Engine
        Batch        = New-HttpBatch -Engine $Engine -Jobs $Plan -Concurrency $Concurrency
        Outcomes     = (New-Object System.Collections.ArrayList)
        Best         = $null
        EarlyStopped = $false
        RequestCount = 0
    }
}

function Update-DetectRun {
    <#  命中（score >= 100）后立即取消剩余探测，保证请求数有界  #>
    param($Run)

    if (-not $Run.EarlyStopped) {
        $r = Update-HttpBatch -Batch $Run.Batch
        foreach ($job in @($r.NewlyCompleted)) {
            if ($job.Meta -and $job.Meta['Skipped']) { continue }
            $o = Get-ProbeOutcome -Job $job
            [void]$Run.Outcomes.Add($o)
            # RequestCount 只统计「真正到达服务器的请求」，被取消的不计入
            if ($job.Http -gt 0) { $Run.RequestCount++ }
            if ($o.Score -ge 100) {
                # 只有当「优先级更高（计划序更靠前）的探测」都不在飞时才提前停止，
                # 否则会出现：/responses 先回来就命中，而 /v1/responses 被取消。
                $betterInFlight = $false
                foreach ($f in $Run.Batch.InFlight) {
                    $pi = 9999
                    if ($f.Meta -and $f.Meta.ContainsKey('PlanIndex')) { try { $pi = [int]$f.Meta['PlanIndex'] } catch { $pi = 9999 } }
                    if ($pi -lt $o.PlanIndex) { $betterInFlight = $true; break }
                }
                if ($betterInFlight) { continue }

                $Run.EarlyStopped = $true
                $cancelled = Stop-HttpBatch -Batch $Run.Batch
                foreach ($cj in @($cancelled)) {
                    $cj.Meta['Skipped'] = $true
                }
                break
            }
        }
        $done = $r.Finished
        if ($Run.EarlyStopped) { $done = ($Run.Batch.InFlight.Count -eq 0) }
        # 收敛后再裁决：必须等所有已发出的探测都打分完，否则会按「谁先完成」选端点
        if ($done) { $Run.Best = Select-BestProbe -Outcomes $Run.Outcomes.ToArray() }
        return @{ Finished = $done; Best = $Run.Best; InFlight = $Run.Batch.InFlight.Count; Pending = $Run.Batch.Queue.Count; Requests = $Run.RequestCount }
    }

    # 提前停止后仍需把在飞的取消请求收尾（取消的不计入请求数）
    $r2 = Update-HttpBatch -Batch $Run.Batch
    foreach ($job in @($r2.NewlyCompleted)) {
        if ($job.Meta -and $job.Meta['Skipped']) { continue }
        [void]$Run.Outcomes.Add((Get-ProbeOutcome -Job $job))
        if ($job.Http -gt 0) { $Run.RequestCount++ }
    }
    $done2 = ($Run.Batch.InFlight.Count -eq 0)
    if ($done2) { $Run.Best = Select-BestProbe -Outcomes $Run.Outcomes.ToArray() }
    return @{ Finished = $done2; Best = $Run.Best; InFlight = $Run.Batch.InFlight.Count; Pending = 0; Requests = $Run.RequestCount }
}

# ---------------------------------------------------------------- 批量测试运行器
function New-ResultRow {
    param([int]$Index, [string]$Model, [string]$Protocol)

    return [ordered]@{
        Index           = $Index
        Model           = $Model
        ReturnedModel   = ''
        Protocol        = $Protocol
        Endpoint        = ''
        Http            = 0
        Status          = '(pending)'
        StatusShort     = ''
        Rank            = -1
        Class           = ''
        LatencyMs       = $null
        TtfbMs          = $null
        FinishReason    = ''
        ReasoningTokens = $null
        ContentPresent  = $false
        ContentPreview  = ''
        Error           = ''
        Notes           = ''
        Done            = $false
        Attempts        = 0
        RetryNotes      = (New-Object System.Collections.ArrayList)
    }
}

function Fill-ResultRow {
    param($Row, $Job, [string]$Kind, [string]$Secret = '')

    $Row.Protocol = Get-ProtocolDisplayName -Kind $Kind
    $Row.Endpoint = $Job.FinalUrl
    if ([string]::IsNullOrEmpty($Row.Endpoint)) { $Row.Endpoint = $Job.Url }
    $Row.Http = $Job.Http
    $Row.LatencyMs = $Job.LatencyMs
    $Row.TtfbMs = $Job.TtfbMs

    $res = $null
    if ($Job.Http -eq 200 -and [string]::IsNullOrEmpty($Job.ErrorType)) {
        $res = Read-ApiResult -Kind $Kind -Body $Job.RespBody -ContentType $Job.ContentType
    } elseif ($Job.Http -gt 0) {
        # 非 200：只取服务器错误原文。不要按成功响应去解析 body，
        # 否则会冒出「响应缺少 output 字段」这类误导性备注（429 本来就没有 output）。
        $res = New-TestResult
        $res.HasError = $true
        $res.RemoteError = Get-RemoteErrorText $Job.RespBody
    }

    $v = Get-TestVerdict -Result $res -Http $Job.Http -ErrorType $Job.ErrorType `
        -ErrorMessage $Job.ErrorMessage -Kind $Kind
    $Row.Status = $v.Status
    $Row.StatusShort = $v.Short
    $Row.Rank = $v.Rank
    $Row.Class = $v.Class

    if ($null -ne $res) {
        $Row.ReturnedModel = $res.ReturnedModel
        $Row.FinishReason = $res.FinishReason
        $Row.ReasoningTokens = $res.ReasoningTokens
        $Row.ContentPresent = (-not [string]::IsNullOrWhiteSpace($res.Content))
        $Row.ContentPreview = Format-ContentPreview $res.Content 90
        if (@($res.Notes).Count -gt 0) { $Row.Notes = ($res.Notes -join '; ') }
    }

    $err = ''
    if ($null -ne $res -and $res.RemoteError) { $err = $res.RemoteError }
    elseif ($Job.ErrorMessage) { $err = $Job.ErrorMessage }
    elseif ($v.Detail) { $err = $v.Detail }
    $Row.Error = $err

    # 出口统一遮挡：行上的任何文本在离开数据层前都已经不含完整密钥
    if ($Secret -and $Secret.Length -ge 6) {
        $Row.Error = Mask-Secret $Row.Error $Secret
        $Row.ContentPreview = Mask-Secret $Row.ContentPreview $Secret
        $Row.Notes = Mask-Secret $Row.Notes $Secret
        $Row.Endpoint = Mask-Secret $Row.Endpoint $Secret
    }
}

function New-ApiTestRun {
    <#
      Models        : 要测的模型名（顺序 = 表格顺序 = 网格行号）
      Kind          : Chat / Compatible / Responses / Messages
      EndpointUrl   : 本次要打的端点（Auto Detect 命中后传入；显式协议时由候选算法给出）
      AllowRetry    : 是否允许「只换一个变量」的兼容性重试（默认开）
    #>
    param(
        $Engine,
        [string[]]$Models,
        [string]$Kind,
        [string]$ApiKey,
        [string]$EndpointUrl,
        [int]$Concurrency = 3,
        [int]$TimeoutSec = 30,
        [hashtable]$MetaBase = $null,
        [switch]$AllowRetry
    )

    $rows = New-Object System.Collections.ArrayList
    $jobs = New-Object System.Collections.ArrayList
    $byIndex = @{}
    $i = 0

    foreach ($m in @($Models)) {
        $meta = @{}
        if ($null -ne $MetaBase) { foreach ($k in $MetaBase.Keys) { $meta[$k] = $MetaBase[$k] } }
        $row = New-ResultRow -Index $i -Model $m -Protocol (Get-ProtocolDisplayName -Kind $Kind)
        [void]$rows.Add($row)
        $byIndex[$i] = $row
        $job = New-ApiTestJob -Id ('row' + $i + '-a1') -Model $m -Kind $Kind -Url $EndpointUrl `
            -ApiKey $ApiKey -TimeoutSec $TimeoutSec -RowIndex $i -Meta $meta -Attempt 1
        [void]$jobs.Add($job)
        $i++
    }

    return [pscustomobject]@{
        Engine         = $Engine
        Rows           = $rows
        RowByIndex     = $byIndex
        Batch          = (New-HttpBatch -Engine $Engine -Jobs $jobs.ToArray() -Concurrency $Concurrency)
        Kind           = $Kind
        ApiKey         = $ApiKey
        TimeoutSec     = $TimeoutSec
        EndpointUrl    = $EndpointUrl
        AllowRetry     = [bool]$AllowRetry
        Total          = @($Models).Count
        CompletedCount = 0
        Retried        = 0
        Stopped        = $false
    }
}

function Update-ApiTestRun {
    param($Run)

    $updated = New-Object System.Collections.ArrayList
    $r = Update-HttpBatch -Batch $Run.Batch
    $requeued = $false

    foreach ($job in @($r.NewlyCompleted)) {
        if ($job.RowIndex -lt 0) { continue }
        $row = $Run.RowByIndex[$job.RowIndex]
        if ($null -eq $row) { continue }

        Fill-ResultRow -Row $row -Job $job -Kind $Run.Kind -Secret $Run.ApiKey
        $row.Attempts = $job.Attempt

        $retry = $null
        if ($Run.AllowRetry) {
            $retry = Get-RetryDecision -Job $job -AttemptsUsed $job.Attempt -MaxAttempts 2
        }

        if ($null -ne $retry) {
            [void]$row.RetryNotes.Add($retry.Note)
            $rj = New-ApiRetryJob -Job $job -Reason $retry.Reason -ApiKey $Run.ApiKey -TimeoutSec $Run.TimeoutSec
            $Run.Batch.Queue.Enqueue($rj)
            $Run.Retried++
            $requeued = $true
            [void]$updated.Add($row)
            continue
        }

        if ($row.RetryNotes.Count -gt 0) {
            $row.Status = $row.Status + ' [retry: ' + ($row.RetryNotes -join '; ') + ']'
        }
        $row.Done = $true
        $Run.CompletedCount++
        [void]$updated.Add($row)
    }

    $finished = $r.Finished
    if ($requeued) { $finished = $false }
    if ($Run.Stopped) {
        $inflight = $Run.Batch.InFlight.Count
        if ($inflight -gt 0) { $finished = $false }
    }

    return @{
        Finished       = $finished
        UpdatedRows    = $updated.ToArray()
        InFlight       = $Run.Batch.InFlight.Count
        Pending        = $Run.Batch.Queue.Count
        Peak           = $Run.Engine.PeakConcurrency
        CompletedCount = $Run.CompletedCount
        Total          = $Run.Total
        Retried        = $Run.Retried
    }
}

function Stop-ApiTestRun {
    <#  取消未开始的请求；在飞的在后续 tick 里自然变成 Cancelled  #>
    param($Run)

    $Run.Stopped = $true
    $cancelled = Stop-HttpBatch -Batch $Run.Batch
    foreach ($job in @($cancelled)) {
        if ($job.RowIndex -lt 0) { continue }
        $row = $Run.RowByIndex[$job.RowIndex]
        if ($null -eq $row -or $row.Done) { continue }
        $row.Http = 0
        $row.Status = 'Cancelled'
        $row.StatusShort = 'Cancelled'
        $row.Rank = 95
        $row.Class = 'cancelled'
        $row.Error = '用户中止（未开始）'
        $row.Done = $true
        $Run.CompletedCount++
    }
}


