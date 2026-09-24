# API Model Tester

一个 Windows PowerShell GUI 工具，用于拉取和测试 OpenAI / Anthropic / OpenAI-compatible API 模型。

填一个 Base URL 和 API Key，拉到模型列表后并发把每个模型打一遍，看谁真的能用、谁只是 HTTP 200 但内容为空。

纯 PowerShell + WinForms。**不编译任何代码、不安装任何依赖、除了你填的那个地址之外不向任何地方发包。**

---

## 主要功能

- **Fetch Models** —— 从 `/v1/models` 或 `/models` 拉取模型列表（自动处理重复的 `/v1` 路径）
- **Test Selected / Test All** —— 并发测试，默认并发 3、超时 30s，随时可 Stop
- **Auto Detect protocol** —— 自动探测可用协议与端点（有界探测，命中即停，会话内缓存）
- **OpenAI Chat Completions** —— `POST /v1/chat/completions`
- **OpenAI Responses** —— `POST /v1/responses`
- **Anthropic Messages** —— `POST /v1/messages`（`x-api-key` + `anthropic-version`）
- **OpenAI Compatible** —— 同上协议，但对不规范响应结构更宽容
- **HTTP / latency / TTFB / finish reason** —— 每个模型逐项记录，另含 reasoning tokens 与内容预览
- **Compatibility Warning** —— HTTP 200 但内容异常（空内容 / 只有 reasoning / 结构不兼容）不会被误判为 OK
- **CSV / report export** —— 导出明细 CSV、复制测试报告、复制可用模型清单
- **API Key only kept in memory** —— 密钥只存在于内存，绝不落盘

## 环境

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / 11 |
| PowerShell | **PowerShell 7 推荐**；Windows PowerShell 5.1 兼容（两者均已通过 151 项自检） |
| 其他依赖 | 无。不需要 Node / Python / 管理员权限 |

## 启动方法

在本目录（例如 `D:\Tools\ApiModelTester`）下任选一种：

```powershell
# 1) 直接运行主程序（推荐 PowerShell 7）
pwsh    -NoProfile -STA -ExecutionPolicy Bypass -File .\ApiModelTester.ps1

# 2) 用 Windows 自带的 PowerShell 5.1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\ApiModelTester.ps1

# 3) 双击 Launch.vbs —— 无控制台窗口（快捷方式指向它）
#    优先 PowerShell 7，找不到再回退到 5.1

# 4) 双击 Launch.cmd —— 备用启动器，万一脚本宿主报错时用
```

想做成桌面图标：给 `wscript.exe`（目标）加参数 `"<本目录>\Launch.vbs"` 建一个快捷方式，图标可用 `assets\icon.ico`。

主程序还有三个可选开关：

| 开关 | 用途 |
| --- | --- |
| `-Diagnose` | 不显示窗口，把界面完整构造一遍就退出，结果写进 `startup.log`（用于确认"程序能不能起来"） |
| `-AutoDemo <url>` | 启动后自动跑完 Fetch Models + Test All，**只用于本地假服务器**（会填一个占位假 key） |
| `-ForceShow` | 被"隐藏窗口"方式拉起（`WScript.Shell.Run(cmd, 0)`）时强制显示主窗口 |

## 快速上手

1. 启动程序
2. `Base URL` 填 `https://example.com/v1`（填 `https://example.com` 也行，程序会自己补 `/v1`）
3. `API Key` 填 `sk-example-key`（实际使用时填你自己的 key）
4. 点 `Fetch Models` → 勾选要测的模型 → `Test All`
5. 用 `Copy Test Report` 或 `Export CSV` 取结果

> 没有真实 key 也能试：先跑 `tests\MiniMock.ps1`（本地假服务器，会把地址写进 `tests\minimock.url`），把那个 `http://127.0.0.1:xxxxx` 填进 Base URL，随便填个 key，就能看到完整的 OK / Compatibility Warning / 失败三种状态。

---

## 界面

- **Base URL**：`https://example.com` 或 `https://example.com/v1` 都行；粘成完整端点（`.../v1/chat/completions`）也会自动剥回根地址。
- **API Key**：默认密码遮挡，旁边「显示 / 隐藏」切换；**永不落盘**。
- **Protocol**：`Auto Detect` / `OpenAI Chat Completions` / `OpenAI Responses` / `Anthropic Messages` / `OpenAI Compatible`。
- **Timeout**：默认 30 秒（整体请求时限，含读取响应体）。
- **Concurrency**：默认 3。
- **Normalize /v1 automatically**：默认勾选，保证不会发出 `/v1/v1/models` 这种路径。
- **Auto test after fetching models**：拉到模型后自动开测。
- 按钮：`Fetch Models` / `Test Selected` / `Test All` / `Stop`。
- 表格 13 列：Model、Returned Model、Protocol、Endpoint、HTTP、Status、Latency、TTFB、Finish Reason、Reasoning Tokens、Content、Error（首列打勾用于「只测选中」；列可排序，数值列按数值排而不是按字符串排）。
- 下方日志区会记录每一步，并保留服务器返回的原始 `error.message`。

---

## 协议与端点

| 协议 | 测试请求 | 鉴权头 |
| --- | --- | --- |
| OpenAI Chat Completions | `POST /v1/chat/completions`，`max_tokens: 8` | `Authorization: Bearer` |
| OpenAI Compatible | 同上，响应结构判定更宽松 | `Authorization: Bearer` |
| OpenAI Responses | `POST /v1/responses`，最小 `input` | `Authorization: Bearer` |
| Anthropic Messages | `POST /v1/messages`，`max_tokens: 8` | `x-api-key` + `anthropic-version: 2023-06-01` |

测试请求体统一是「回一句 OK」的最小 prompt。

**Auto Detect 的探测顺序**（最多 6 个候选，命中即停，结果在会话内缓存，不会每个模型重探）：

1. Chat：`/v1/chat/completions` → `/chat/completions`
2. Responses：`/v1/responses` → `/responses`
3. Anthropic：`/v1/messages` → `/messages`

先跑一轮规范形态（`/v1/...`）再跑一轮备用形态；候选全部不通时会换一个样本模型再试一轮（最多 3 个样本，有界）。

打分规则：200 且有内容 = 100 分（立即停止探测）；200 但内容异常 = 95；429 = 45；400/422 = 40（报错里点名了模型则 50）；401/403 = 35（路由存在，鉴权/协议头问题）；5xx = 10；404/405 = 0。取最高分，同分按探测顺序（OpenAI 兼容优先）。

**兼容性重试**（每个模型最多换一个变量重试一次，绝不无限重试）：

- Chat 因 `max_tokens` 报 400/422 → 换 `max_completion_tokens` 再试一次
- Anthropic 报 401/403 → 追加 `Authorization: Bearer` 再试一次
- 404/405 → 换另一种路径形态（`/v1/...` ↔ `/...`）再试一次

**HTTP 200 ≠ 可用。** 以下情况会标成 `Compatibility Warning`，而不是 OK：

- `content` 为空或全是空白
- 只有 `reasoning_content` / `thinking`，没有最终 `content`
- 响应不是合法 JSON，或缺 `choices` / `output` / `content` 字段
- SSE 流里没有任何文本
- HTTP 200 但响应体里是 `error` 对象

状态映射：400 BadRequest、401 AuthFail、403 Forbidden、404 NotFound、408 Timeout、429 RateLimit、500 ServerErr、502 BadGateway、503 Unavailable、524 UpstreamTO；本地超时记为 Timeout；DNS / TLS 失败单独显示真实原因，不吞掉服务器返回的 `error.message`。

---

## 输出

- **Copy Available Models**：把判定为 OK 的模型名逐行复制；还没测过则复制全部模型名。
- **Export CSV**：13 列明细，UTF-8 带 BOM（Excel 直接双击不乱码），**不含 API Key**。
- **Copy Test Report**：等宽表格，形如

```
Model                     ReturnedModel            HTTP Status         Latency   TTFB
------------------------------------------------------------------------------------------
gpt-5.6-sol               gpt-5.6-sol              200  OK             2.30s     1.90s
gpt-6-astra               gpt-6-astra              429  RateLimit      1.80s     1.55s

Summary   : OK 1 | Warning 0 | Failed 1 | Cancelled 0
```

- **Clear**：清空表格与日志（测试进行中需先 Stop）。

---

## 安全说明（API Key 处理）

1. Key 只存在于内存里的输入框，**不写入**日志、CSV、报告、配置、错误日志。
2. 配置白名单写入：只有 `baseUrl / protocol / timeoutSec / concurrency / normalizeV1 / autoTestAfterFetch / window / columnWidths` 会落盘；写之前还会再检查一遍序列化结果里有没有 `apiKey|apikey|authorization|token|secret` 字段名。
3. HTTP 请求在进程内由 .NET 的 `HttpClient` 直接发出，**不拼 `curl.exe`**，Key 不会出现在任何进程命令行参数里。
4. 所有要显示 / 导出的文本统一走 `Mask-Secret`：先精确替换真实 Key，再兜底处理 `sk-xxxx`、`Bearer xxx`、`api_key: xxx` 形态，统一显示成 `sk-abc...xyz`。
5. 无遥测、无统计、不上传任何数据；唯一会发包的地方就是你填的那个地址。
6. 自检脚本会在安装目录、配置目录、报告目录里全文扫描假 Key，确认没有明文落盘（用每次运行随机生成的假 Key，断言才有意义）。

配置文件位置：`%LOCALAPPDATA%\ApiModelTester\settings.json`（纯文本，可随时删）。**该文件不在本仓库里**，也不会被提交。

---

## 目录结构

```
<项目目录>\
├─ ApiModelTester.ps1        主程序（WinForms 界面 + 状态机）
├─ Launch.vbs                无控制台窗口启动器（快捷方式指向它）
├─ Launch.cmd                备用启动器（万一 Launch.vbs 报错就用它）
├─ uninstall.ps1             卸载脚本（默认演练模式）
├─ README.md                 本文件
├─ .gitignore
├─ lib\
│  ├─ Core.ps1               URL 规范化 / 密钥遮挡 / 错误分类 / 响应解析 / 报告 / 配置
│  ├─ HttpEngine.ps1         轮询式异步 HTTP 引擎（并发上限 + 本地超时 + Stop）
│  └─ Detect.ps1             Auto Detect 探测计划、端点候选、重试决策、批量测试运行器
├─ tests\
│  ├─ MockServer.ps1         本地假 API 服务器（TcpListener，无需管理员）
│  ├─ MiniMock.ps1           现成的假服务器靶子：没 key 也能把整套流程跑通看效果
│  └─ Test-Core.ps1          自检：151 项断言，含并发 / Stop / 不落盘验证
└─ assets\
   ├─ icon.ico               应用与快捷方式图标
   └─ make-icon.ps1          图标生成脚本（可重复执行）
```

clone 下来即可直接运行，只依赖仓库内的文件；运行期产生的日志 / 配置 / 报告都在仓库外或已在 `.gitignore` 中。

---

## 自检与排错

### 单元 / 集成自检（不需要任何 key）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Core.ps1 -OutFile "$env:TEMP\amt-selftest.txt"
```

151 项断言，覆盖：语法解析、URL 规范化（含「绝不出现 /v1/v1」）、密钥遮挡、HTTP 状态映射、四类协议响应解析（含畸形 JSON / 空内容 / 只有 reasoning / SSE）、真实往返（打本地假服务器，覆盖 200/400/401/403/404/408/429/500/502/503/524/本地超时）、兼容性重试、Auto Detect 有界探测、并发上限（假服务器侧观测 + 引擎侧峰值 + 耗时对比）、Stop 立即生效、Key 不落盘、报告与 CSV 结构。

自检**不发任何真实请求**，只用 `127.0.0.1` 上的假服务器，也不需要管理员权限。Windows PowerShell 5.1 与 PowerShell 7 均已验证 151/151。

### 界面 headless 自检

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\ApiModelTester.ps1 -Diagnose
```

把界面完整构造一遍但不显示窗口，结果写进 `%LOCALAPPDATA%\ApiModelTester\startup.log`。用于确认「程序本身能不能起来」，不涉及任何网络请求。

### 双击没反应 / 弹出 Windows Script Host 报错怎么办

1. 先看 `%LOCALAPPDATA%\ApiModelTester\launch.log`：启动器每次运行都会重写它，里面记录了它挑中的解释器、拼出的完整命令行、以及候选路径各自是否存在，启动器自身失败时也会写入错误码。
2. 如果报的是 **Windows Script Host / `800A0408 无效字符`** 这类脚本宿主错误 → 双击同目录的 `Launch.cmd`。它不经过 `.vbs`，直接用 `powershell.exe` / `pwsh.exe` 拉起主程序（代价是会闪一下黑框）。
3. 再看 `%LOCALAPPDATA%\ApiModelTester\startup.log`：主程序自己的启动追踪（解释器、程序集加载、界面构造、消息循环），启动阶段的致命错误也记在最后一行并弹对话框。这两个日志都**不含任何密钥**。

### 常见现象

- `HTTP 200` + `Compatibility Warning` 且备注「只有 reasoning / thinking 内容」：这类中转站的 chat 端点对最小 prompt 只吐思考内容、不吐最终答案，属于供应商差异，不代表端点不可用 —— 换个协议（例如 Responses）或换个模型再看。
- 某些站点会对 `/v1/messages` 单独返回 403（本分组不允许该路由），这时 Auto Detect 会跳过它继续找能用的端点。
- 429 的原文（例如 `rate limit exceeded`）会保留在 Error 列里，不会被吞掉。

---

## 已知限制

- 只做「单轮最小请求」可用性探测，不测流式输出、函数调用、图片 / 多模态、token 计费准确性。
- 不做 SSE 流式请求（`stream` 未开启）；但如果服务器擅自返回 SSE，会尽力解析出文本内容。
- TLS 证书校验无法关闭（自签证书站点会报 TLS 错误）。用明文 `http://` 地址可以绕过。
- DNS 解析在 Windows PowerShell 5.1 上可能占用主线程极短时间（.NET Framework 的实现细节），极端慢 DNS 下界面可能短暂顿一下。
- 时间戳精度约 ±20ms（异步完成状态由 20ms 心跳轮询感知），对秒级网络延迟无影响。
- 测试大模型列表时不限制响应体大小，超大响应会占用相应内存（会把内容截断显示）。
- 高 DPI 缩放未做逐显示器适配，改缩放比例后界面可能需要重开。
- 不支持需要额外鉴权流程（OAuth / 浏览器授权）的站点。

---

## 卸载

```powershell
# 先演练（只列出要删什么）
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1

# 确认后真删
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -Force

# 想保留配置
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -Force -KeepSettings
```

本程序没有服务、没有注册表项、没有计划任务、没有环境变量，删掉文件就是彻底卸载。脚本自身所在目录可能无法自删，最后手动删掉整个项目目录即可。

---

## 改代码时注意

- **所有 `.ps1` 必须是 UTF-8 with BOM**。Windows PowerShell 5.1 对无 BOM 的脚本按系统 ANSI 代码页解码，中文字符串会被拆坏，直接语法报错。用编辑器保存时务必选「UTF-8 带 BOM」。
- **`Launch.vbs` 与 `Launch.cmd` 必须保持纯 ASCII（不放任何中文）**。Windows Script Host 与 cmd 对无 BOM 的脚本同样按系统 ANSI 代码页解码：中文注释会变成乱码字节，`Launch.vbs` 会直接编译失败并弹出 `800A0408 无效字符`。这两个文件里所有提示文字都用英文。
- **`Launch.vbs` 里 `sh.Run cmd, 0, False` 的第二个参数不能随便改**。它现在是 `0`（SW_HIDE），控制台窗口从创建起就是隐藏的、彻底不闪黑框；但 `SW_HIDE` 会被子进程的 `STARTUPINFO.wShowWindow` 继承，**WinForms 主窗口也会一起被藏起来**（现象：进程活着、`startup.log` 显示 `form shown`，但看不到窗口、`hwnd=0`）。所以 `Launch.vbs` 给主程序传了 `-ForceShow`，由主程序在 `Add_Shown` 里做一次 `Visible` 抖动强制显示。改启动方式时两者要配套：
  - 用 `sh.Run(cmd, 0)`（零闪烁）→ 必须带 `-ForceShow`
  - 用 `sh.Run(cmd, 1)` + `-WindowStyle Hidden`（可能闪一下黑框）→ 不要带 `-ForceShow`（否则窗口会多闪一次）
- 不要引入 `Add-Type` / 运行时编译，不要把包管理依赖带进来；程序集用 `Import-NetAssemblies`（反射加载框架自带程序集）解决。
- 网络 I/O 必须继续走 `lib\HttpEngine.ps1` 的「发起异步 → 主线程轮询」模型，任何在主线程上 `.Wait()` / `.Result` 的写法都会让界面卡死。
- 新增解析分支时，请同步在 `tests\Test-Core.ps1` 里加断言，并让假服务器覆盖对应的畸形响应。
- 改完 `ApiModelTester.ps1` 后建议跑一次 `-Diagnose`：它能在不弹窗的情况下把界面构造全程走一遍。
