#Requires -Version 5.1
<#
.SYNOPSIS
    Codex 代理一键修复工具（自动探测本地代理端口）

.DESCRIPTION
    Codex 桌面版自带网络栈，不读取 Windows 系统代理设置，所以即使浏览器能上网，
    它也可能一直"正在重连 1/5…5/5"。本工具通过设置用户级 HTTP_PROXY / HTTPS_PROXY
    环境变量解决这个问题，并用 codex doctor 验证 Codex 自己的网络栈是否真的通了。

    换代理软件、换端口都不需要改代码：端口是自动探测的。

.PARAMETER Port
    手动指定代理端口，跳过自动探测。指定的端口不通会直接报错，不会偷偷换成别的。

.PARAMETER Status
    只读体检，不做任何修改。

.PARAMETER Rollback
    还原到本工具首次写入之前的状态。

.PARAMETER Restart
    写入后自动结束并重启 Codex 桌面应用。

.PARAMETER NoRestart
    不询问、也不重启 Codex（配合 -Yes 做无人值守运行时用）。

.PARAMETER Yes
    跳过所有确认提示（适合自己写脚本调用）。

.PARAMETER SkipDoctor
    跳过 codex doctor 验证（没联网时用）。

.EXAMPLE
    .\CodexProxy.ps1
    自动探测 + 确认后写入 + 验证。

.EXAMPLE
    .\CodexProxy.ps1 -Status
    只看看当前是什么情况。

.EXAMPLE
    .\CodexProxy.ps1 -Port 7897 -Restart
    手动指定端口并自动重启 Codex。

.EXAMPLE
    .\CodexProxy.ps1 -Rollback
    改回原样。

.NOTES
    只写 HKCU 用户级环境变量，不改系统代理、不改 config.toml、不动其他软件。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$Port = 0,
    [switch]$Status,
    [switch]$Rollback,
    [switch]$Restart,
    [switch]$NoRestart,
    [switch]$Yes,
    [switch]$SkipDoctor
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# -WhatIf 会让脚本里所有支持 ShouldProcess 的 cmdlet 都变成干跑（连模块自动加载都会打印
# "What if: New Alias"），所以这里把它收进自己的开关，内部 cmdlet 照常执行。
$Script:DryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

# ============================ 常量 ============================
$Script:StateDir    = Join-Path $env:LOCALAPPDATA 'CodexProxyFix'
$Script:StateFile   = Join-Path $Script:StateDir   'state.json'
$Script:LogFile     = Join-Path $Script:StateDir   'run.log'
$Script:NoProxy     = 'localhost,127.0.0.1,::1'
$Script:TestUrl     = 'http://www.gstatic.com/generate_204'
$Script:CommonPorts = @(7890, 7891, 7892, 7897, 10808, 10809, 1080, 2080, 8080, 8888)
$Script:ProxyHints  = @(
    'clash', 'mihomo', 'verge', 'v2ray', 'xray', 'sing-box', 'singbox', 'nekoray',
    'nekobox', 'hiddify', 'shadowsocks', 'ss-local', 'trojan', 'netch', 'qiyou',
    'chaoshihui', 'proxifier', 'warp', 'tun2socks', 'naive', 'qv2ray', 'v2raya', 'flclash'
)
$Script:CandList = New-Object System.Collections.ArrayList

# ============================ 输出 ============================
function Write-Head([string]$t) {
    Write-Host ''
    Write-Host ("== {0} {1}" -f $t, ('=' * [Math]::Max(2, 58 - $t.Length))) -ForegroundColor Cyan
}
function Write-Ok([string]$t)   { Write-Host ("  [OK]   {0}" -f $t) -ForegroundColor Green }
function Write-Bad([string]$t)  { Write-Host ("  [失败] {0}" -f $t) -ForegroundColor Red }
function Write-Warn([string]$t) { Write-Host ("  [注意] {0}" -f $t) -ForegroundColor Yellow }
function Write-Info([string]$t) { Write-Host ("         {0}" -f $t) -ForegroundColor Gray }

function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path $Script:StateDir)) {
            New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
        }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Invoke-Action([string]$What, [scriptblock]$Action) {
    if ($Script:DryRun) {
        Write-Host ("         [WhatIf] 将执行：{0}" -f $What) -ForegroundColor DarkYellow
        return
    }
    & $Action
}

# ============================ 环境变量读写 ============================
function Get-EnvSnapshot {
    $h = [ordered]@{}
    foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY') {
        $h[$n] = [Environment]::GetEnvironmentVariable($n, 'User')
    }
    return $h
}

function Format-EnvValue($v) {
    if ([string]::IsNullOrEmpty($v)) { return '(未设置)' }
    if ($v.Length -gt 34) { return $v.Substring(0, 31) + '...' }
    return $v
}

function Set-UserEnv([string]$Name, $Value) {
    if ([string]::IsNullOrEmpty($Value)) {
        [Environment]::SetEnvironmentVariable($Name, $null, 'User')
    } else {
        [Environment]::SetEnvironmentVariable($Name, [string]$Value, 'User')
    }
}

function Send-EnvChange {
    try {
        if (-not ('Win32.NativeMethods' -as [type])) {
            Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $res = [UIntPtr]::Zero
        [Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$res) | Out-Null
        return $true
    } catch {
        Write-Verbose "广播 WM_SETTINGCHANGE 失败: $($_.Exception.Message)"
        return $false
    }
}

function Show-EnvDiff($Prior, $Target) {
    Write-Host ''
    Write-Host '  变量            当前值                              -> 将改为' -ForegroundColor DarkGray
    foreach ($k in $Target.Keys) {
        $old = Format-EnvValue $Prior[$k]
        $new = Format-EnvValue $Target[$k]
        $mark = ''
        if ($old -eq $new) { $mark = '   (不变)' }
        Write-Host ("  {0,-12}  {1,-34} -> {2}{3}" -f $k, $old, $new, $mark)
    }
}

function Ask-Confirm([string]$Prompt) {
    if ($Script:DryRun) {
        Write-Host ("         [WhatIf] 跳过确认：{0}" -f $Prompt) -ForegroundColor DarkYellow
        return $true
    }
    if ($Yes) { return $true }
    Write-Host ''
    $a = Read-Host ("  {0} [Y/N]" -f $Prompt)
    return [bool]($a -match '^\s*(y|yes|是|确认)\s*$')
}

# ============================ Codex 定位 ============================
function Get-CodexInstallPath {
    try {
        $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation -and (Test-Path $pkg.InstallLocation)) {
            return $pkg.InstallLocation
        }
    } catch { }

    try {
        $cp = Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cp -and $cp.Path) { return (Split-Path (Split-Path $cp.Path -Parent) -Parent) }
        $cx = Get-Process -Name 'codex' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cx -and $cx.Path) { return (Split-Path (Split-Path (Split-Path $cx.Path -Parent) -Parent) -Parent) }
    } catch { }
    return $null
}

function Get-CodexExe([string]$Install) {
    if ([string]::IsNullOrEmpty($Install)) { return $null }
    $c = Join-Path $Install 'app\resources\codex.exe'
    if (Test-Path $c) { return $c }
    try {
        $hit = Get-ChildItem -Path $Install -Filter 'codex.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    } catch { }
    return $null
}

# ============================ 代理探测 ============================
function Get-SystemProxyInfo {
    $info = [pscustomobject]@{ Enabled = $false; Server = $null; Port = 0; AutoConfig = $null }
    try {
        $r = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($r) {
            $info.AutoConfig = $r.AutoConfigURL
            if ($r.ProxyEnable -eq 1 -and $r.ProxyServer) {
                $info.Enabled = $true
                $info.Server  = $r.ProxyServer
                $info.Port    = ConvertTo-PortFromProxyString $r.ProxyServer
            }
        }
    } catch { }
    return $info
}

function ConvertTo-PortFromProxyString([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
    $parts = @($s -split ';' | Where-Object { $_ -match '\S' })
    if ($parts.Count -eq 0) { return 0 }
    $srv = $null
    foreach ($p in $parts) { if ($p -match '^\s*https?=') { $srv = ($p -split '=', 2)[1]; break } }
    if (-not $srv) { $srv = ($parts[0] -split '=', 2)[1] }
    if (-not $srv) { $srv = $parts[0] }
    if ($srv -match ':(\d{2,5})\s*$') { return [int]$Matches[1] }
    return 0
}

function Get-PortOwner([int]$p) {
    try {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) {
            $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($pr) { return $pr.ProcessName }
        }
    } catch { }
    return $null
}

function Test-ProxyPort([int]$p) {
    $r = [pscustomobject]@{ Port = $p; Ok = $false; Code = 0; Ms = 0; Error = $null; Owner = (Get-PortOwner $p) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -Uri $Script:TestUrl -Proxy ("http://127.0.0.1:{0}" -f $p) `
            -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop
        $r.Code = [int]$resp.StatusCode
        $r.Ok = ($r.Code -ge 200 -and $r.Code -lt 400)
    } catch {
        $msg = $_.Exception.Message
        if ($msg.Length -gt 80) { $msg = $msg.Substring(0, 77) + '...' }
        $r.Error = $msg
    } finally {
        $sw.Stop()
        $r.Ms = [int]$sw.ElapsedMilliseconds
    }
    return $r
}

function Add-Cand([int]$p) {
    if ($p -le 0 -or $p -gt 65535) { return }
    if ($Script:CandList.Contains($p)) { return }
    [void]$Script:CandList.Add($p)
}

function Get-CandidatePorts([int]$Explicit) {
    $Script:CandList = New-Object System.Collections.ArrayList
    if ($Explicit -gt 0) { Add-Cand $Explicit }

    $sp = Get-SystemProxyInfo
    if ($sp.Port -gt 0) { Add-Cand $sp.Port }

    try {
        $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::', '::1') }
        foreach ($c in $conns) {
            $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if (-not $pr) { continue }
            $nm = $pr.ProcessName.ToLower()
            foreach ($h in $Script:ProxyHints) {
                if ($nm.Contains($h)) { Add-Cand $c.LocalPort; break }
            }
        }
    } catch { }

    foreach ($p in $Script:CommonPorts) { Add-Cand $p }
    return @($Script:CandList)
}

function Find-WorkingProxy([int]$Explicit, [switch]$Quiet) {
    $cands = Get-CandidatePorts $Explicit
    if (-not $Quiet) { Write-Info ("将依次验证 {0} 个候选端口（每个最多 4 秒）…" -f $cands.Count) }
    foreach ($p in $cands) {
        $r = Test-ProxyPort $p
        if (-not $Quiet) {
            if ($r.Ok) {
                $own = if ($r.Owner) { "，属主 $($r.Owner)" } else { '' }
                Write-Ok ("127.0.0.1:{0} 可用（{1} ms，HTTP {2}{3}）" -f $p, $r.Ms, $r.Code, $own)
            } else {
                $err = if ($r.Error) { "：$($r.Error)" } else { '' }
                Write-Info ("127.0.0.1:{0} 不可用（{1} ms）{2}" -f $p, $r.Ms, $err)
            }
        }
        if ($r.Ok) { return $r }
    }
    return $null
}

# ============================ 状态文件 ============================
function Read-State {
    if (-not (Test-Path $Script:StateFile)) { return $null }
    try { return (Get-Content -Path $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-State($Prior, $Applied) {
    if (-not (Test-Path $Script:StateDir)) {
        New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
    }
    $o = [ordered]@{
        savedAt   = (Get-Date -Format 'o')
        prior     = $Prior
        applied   = $Applied
        codexPath = (Get-CodexInstallPath)
    }
    ($o | ConvertTo-Json -Depth 6) | Set-Content -Path $Script:StateFile -Encoding UTF8
}

# ============================ 验证 ============================
function Invoke-Doctor($EnvMap) {
    $install = Get-CodexInstallPath
    $exe = Get-CodexExe $install
    if (-not $exe) {
        return [pscustomobject]@{ Ok = $false; Json = $null; Reason = '找不到 codex.exe，无法验证' }
    }

    $saved = @{}
    foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY') {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        $v = $null
        if ($EnvMap) {
            try { $v = $EnvMap[$k] } catch { $v = $null }
        }
        [Environment]::SetEnvironmentVariable($k, $v, 'Process')
    }

    try {
        $out = & $exe doctor --network-only --json 2>$null | Out-String
        $json = $null
        try { $json = $out | ConvertFrom-Json } catch { }
        if (-not $json) {
            return [pscustomobject]@{ Ok = $false; Json = $null; Reason = 'codex doctor 输出不是 JSON' }
        }
        return [pscustomobject]@{ Ok = ($json.overallStatus -eq 'ok'); Json = $json; Reason = $null }
    } catch {
        return [pscustomobject]@{ Ok = $false; Json = $null; Reason = $_.Exception.Message }
    } finally {
        foreach ($k in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process')
        }
    }
}

function Get-DoctorCheck($Json, [string]$Id) {
    if (-not $Json -or -not $Json.checks) { return $null }
    $p = $Json.checks.PSObject.Properties[$Id]
    if ($p) { return $p.Value }
    return $null
}

function Show-DoctorResult($res) {
    if (-not $res) { return }
    if ($res.Reason) { Write-Warn ("无法验证：$($res.Reason)"); return }

    $j = $res.Json
    if ($j.overallStatus -eq 'ok') {
        Write-Ok 'codex doctor: overallStatus = ok'
    } else {
        Write-Warn ("codex doctor: overallStatus = {0}" -f $j.overallStatus)
    }

    $envCheck = Get-DoctorCheck $j 'network.env'
    if ($envCheck -and $envCheck.details) {
        $vars = $envCheck.details.'proxy env vars present'
        if ($vars) { Write-Info ("Codex 读到的代理变量：{0}" -f $vars) }
    }

    $ws = Get-DoctorCheck $j 'network.websocket_reachability'
    if ($ws) {
        if ($ws.status -eq 'ok') {
            Write-Ok 'WebSocket 通道：已连通（Responses 流式请求能走通）'
        } else {
            Write-Warn ("WebSocket 通道：{0}" -f $ws.status)
        }
        if ($ws.summary) { Write-Info ("说明：{0}" -f $ws.summary) }
        if ($ws.details -and $ws.details.'handshake result') {
            Write-Info ("握手：{0}" -f $ws.details.'handshake result')
        }
        if ($ws.remediation) { Write-Info ("建议：{0}" -f $ws.remediation) }
    }

    $prov = Get-DoctorCheck $j 'network.provider_reachability'
    if ($prov -and $prov.status -ne 'ok') {
        Write-Warn ("HTTP 可达性：{0} — {1}" -f $prov.status, $prov.summary)
        if ($prov.remediation) { Write-Info ("建议：{0}" -f $prov.remediation) }
    }

    if ($j.overallStatus -eq 'ok') {
        Write-Host ''
        Write-Ok '代理已经对 Codex 生效。重启 Codex 后应该不会再出现"正在重连"。'
    } else {
        Write-Host ''
        Write-Warn '代理变量已写入，但 Codex 还没完全连通。可能原因：'
        Write-Info '1) 代理软件没开、或节点本身不通（先用浏览器打开 chatgpt.com 试）'
        Write-Info '2) 端口探测到了但不是真正的 HTTP 代理（用 -Port <端口> 指定另一个）'
        Write-Info '3) 需要完全退出 Codex 再启动（仅关闭窗口不算）'
    }
}

# ============================ 重启 Codex ============================
function Restart-CodexApp {
    $install = Get-CodexInstallPath
    if (-not $install) {
        Write-Warn '找不到 Codex 安装位置，跳过自动重启。'
        return
    }

    $names = @('ChatGPT', 'codex', 'codex-code-mode-host', 'node_repl')
    $procs = @()
    try {
        $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.ToLower().StartsWith($install.ToLower()) })
    } catch { }

    if ($procs.Count -gt 0) {
        Write-Info ("正在结束 {0} 个 Codex 进程…" -f $procs.Count)
        Invoke-Action ("结束 {0} 个 Codex 进程" -f $procs.Count) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
    }

    $exe = Get-CodexExe $install
    if (-not $exe) {
        Write-Warn '找不到 codex.exe，请手动从开始菜单启动 Codex。'
        return
    }

    Write-Info '正在启动 Codex…'
    Invoke-Action '启动 Codex 桌面应用' {
        Start-Process -FilePath $exe -ArgumentList 'app' -WorkingDirectory $env:USERPROFILE
    }
    Start-Sleep -Seconds 4

    if ($Script:DryRun) { return }

    $now = @()
    try {
        $now = @(Get-Process -Name $names -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.ToLower().StartsWith($install.ToLower()) })
    } catch { }

    if ($now.Count -gt 0) {
        Write-Ok ("Codex 已启动（{0} 个进程）。" -f $now.Count)
    } else {
        Write-Warn '没检测到 Codex 进程，请手动从开始菜单打开。'
    }
}

# ============================ 主流程 ============================
function Invoke-Apply([int]$ExplicitPort) {
    Write-Head '1/4  探测本地代理端口'

    if ($ExplicitPort -gt 0) {
        # 手动指定端口时以用户为准：不通就直接报错，不偷偷换成别的端口
        $hit = Test-ProxyPort $ExplicitPort
        if (-not $hit.Ok) {
            $err = if ($hit.Error) { $hit.Error } else { "HTTP $($hit.Code)" }
            Write-Bad ("指定的端口 {0} 不可用：{1}" -f $ExplicitPort, $err)
            Write-Info '确认代理软件里就是这个端口；或者去掉 -Port，让它自动探测。'
            Write-Log ("指定端口 {0} 不可用: {1}" -f $ExplicitPort, $err)
            exit 2
        }
        $ownTxt = if ($hit.Owner) { "，属主 $($hit.Owner)" } else { '' }
        Write-Ok ("127.0.0.1:{0} 可用（{1} ms，HTTP {2}{3}）" -f $hit.Port, $hit.Ms, $hit.Code, $ownTxt)
    } else {
        $hit = Find-WorkingProxy 0
    }
    if (-not $hit) {
        Write-Bad '没有找到可用的本地 HTTP 代理端口。'
        Write-Host ''
        Write-Info '请依次检查：'
        Write-Info '  - 代理软件是否已经启动（不是只开了个窗口）'
        Write-Info '  - 软件里是否开启了"HTTP 代理"或"混合端口"（只开 SOCKS 不行）'
        Write-Info '  - 端口是不是非标准值 → 用  -Port 12345  手动指定'
        Write-Info '  - 想让本工具看看都发现了什么 → 运行  -Status'
        Write-Log '探测失败：没有可用端口'
        exit 2
    }

    $proxyUrl = 'http://127.0.0.1:{0}' -f $hit.Port
    $ownerTxt = if ($hit.Owner) { $hit.Owner } else { '未知进程' }
    Write-Ok ("采用端口 {0}（{1}）" -f $hit.Port, $ownerTxt)

    Write-Head '2/4  即将写入的内容'
    $target = [ordered]@{
        HTTP_PROXY  = $proxyUrl
        HTTPS_PROXY = $proxyUrl
        NO_PROXY    = $Script:NoProxy
    }
    $cur = Get-EnvSnapshot
    Show-EnvDiff $cur $target

    # 已经跑过就保留最初的原始值，避免把"上次自己写的值"当成回滚目标
    $st = Read-State
    $priorToSave = [ordered]@{}
    if ($st -and $st.prior) {
        foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY') { $priorToSave[$k] = $st.prior.$k }
    } else {
        foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY') { $priorToSave[$k] = $cur[$k] }
    }

    $changed = $false
    foreach ($k in $target.Keys) { if ($cur[$k] -ne $target[$k]) { $changed = $true } }

    if (-not $changed) {
        Write-Host ''
        Write-Ok '当前值已经一致，不需要改写（仍然会跑一次连通性验证）。'
    } elseif (-not (Ask-Confirm '确认写入这三项用户级环境变量？')) {
        Write-Host ''
        Write-Info '已取消，什么都没有改。'
        Write-Log '用户取消写入'
        return
    }

    Write-Head '3/4  写入用户级环境变量'
    foreach ($k in $target.Keys) {
        $val = $target[$k]
        Invoke-Action ("设置 {0} = {1}" -f $k, $val) { Set-UserEnv $k $val }
    }
    Invoke-Action '广播 WM_SETTINGCHANGE 刷新环境' { Send-EnvChange | Out-Null }
    Invoke-Action '备份原始值到 state.json' { Save-State $priorToSave $target }
    Write-Ok '已写入并广播刷新（不用重启资源管理器）。'
    Write-Log ("已写入 HTTP_PROXY/HTTPS_PROXY = {0}" -f $proxyUrl)

    Write-Head '4/4  验证（codex doctor，约 10~20 秒）'
    if ($SkipDoctor) {
        Write-Info '已跳过（-SkipDoctor）。'
    } else {
        $res = Invoke-Doctor $target
        Show-DoctorResult $res
    }

    Write-Head '重启 Codex 让它生效'
    if ($NoRestart) {
        Write-Info '已跳过重启（-NoRestart）。请手动：托盘图标右键 → Quit（完全退出）→ 重新打开 Codex。'
    } elseif ($Restart) {
        Restart-CodexApp
    } elseif (Ask-Confirm '现在重启 Codex？（会关闭当前窗口）') {
        Restart-CodexApp
    } else {
        Write-Info '请手动操作：托盘图标右键 → Quit（完全退出，只关窗口无效）→ 重新打开 Codex。'
        Write-Info '确认方法是看还有没有"正在重连 1/5…5/5"。'
        Write-Info '想改回去就跑： Codex代理修复.cmd -Rollback'
    }
}

function Invoke-Rollback {
    Write-Head '还原到本工具写入之前的状态'

    $st = Read-State
    $target = [ordered]@{}

    if ($st -and $st.prior) {
        foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY') { $target[$k] = $st.prior.$k }
        Write-Info ("备份时间：{0}" -f $st.savedAt)
    } else {
        Write-Warn '没有找到 state.json（没备份过，或文件被删了）。'
        Write-Info '将把这三个变量直接删掉——如果它们原本就不存在，效果一样。'
        foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY') { $target[$k] = $null }
    }

    $cur = Get-EnvSnapshot
    Show-EnvDiff $cur $target

    if (-not (Ask-Confirm '确认还原？')) {
        Write-Host ''
        Write-Info '已取消，什么都没有改。'
        return
    }

    foreach ($k in $target.Keys) {
        $val = $target[$k]
        Invoke-Action ("还原 {0} = {1}" -f $k, (Format-EnvValue $val)) { Set-UserEnv $k $val }
    }
    Invoke-Action '广播 WM_SETTINGCHANGE 刷新环境' { Send-EnvChange | Out-Null }
    Invoke-Action '删除 state.json' { Remove-Item $Script:StateFile -Force -ErrorAction SilentlyContinue }

    Write-Ok '已还原。'
    Write-Info '正在运行的 Codex 仍持有旧值，需要完全退出后重新打开才彻底生效。'
    Write-Info '系统代理、config.toml 本工具从来没碰过，不用管。'
    Write-Log '已执行还原'
}

function Show-Status {
    Write-Head '用户级环境变量'
    $cur = Get-EnvSnapshot
    foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY') {
        Write-Info ("{0,-12} = {1}" -f $k, (Format-EnvValue $cur[$k]))
    }

    $st = Read-State
    if ($st) { Write-Info ("（有备份，可回滚；备份时间 {0}）" -f $st.savedAt) }
    else { Write-Info '（没有备份，说明还没用本工具写过）' }

    Write-Head '系统代理（本工具不会修改）'
    $sp = Get-SystemProxyInfo
    if ($sp.Enabled) {
        Write-Info ("已启用    ProxyServer = {0}   端口 = {1}" -f $sp.Server, $sp.Port)
    } else {
        Write-Info '未启用'
    }
    if ($sp.AutoConfig) { Write-Info ("PAC 脚本  {0}" -f $sp.AutoConfig) }

    Write-Head '本机可疑的代理监听端口'
    $rows = @()
    try {
        $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::', '::1') }
        foreach ($c in $conns) {
            $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if (-not $pr) { continue }
            $nm = $pr.ProcessName
            $hitHint = $false
            foreach ($h in $Script:ProxyHints) { if ($nm.ToLower().Contains($h)) { $hitHint = $true; break } }
            if ($hitHint -or ($Script:CommonPorts -contains $c.LocalPort)) {
                $rows += [pscustomobject]@{ Port = $c.LocalPort; Process = $nm; PID = $c.OwningProcess }
            }
        }
    } catch { }

    if ($rows.Count -eq 0) {
        Write-Info '没发现明显的代理进程（可以用 -Port 手动指定端口）'
    } else {
        $rows | Sort-Object Port -Unique | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }

    Write-Head '自动探测结果'
    $probe = Find-WorkingProxy $Port -Quiet
    if ($probe) {
        $own = if ($probe.Owner) { $probe.Owner } else { '未知' }
        Write-Ok ("可用：127.0.0.1:{0}（{1} ms，属主 {2}）" -f $probe.Port, $probe.Ms, $own)
    } else {
        Write-Warn '没有探测到可用的 HTTP 代理端口。'
    }

    Write-Head 'Codex'
    $install = Get-CodexInstallPath
    if ($install) { Write-Info ("安装位置  {0}" -f $install) } else { Write-Warn '没检测到 Codex 桌面版' }
    $exe = Get-CodexExe $install
    if ($exe) { Write-Info ("codex.exe  {0}" -f $exe) }
    $running = @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue).Count
    Write-Info ("运行中进程数  {0}" -f $running)

    Write-Head 'codex doctor 检测（约 10~20 秒）'
    $map = @{
        HTTP_PROXY  = $cur['HTTP_PROXY']
        HTTPS_PROXY = $cur['HTTPS_PROXY']
        NO_PROXY    = $cur['NO_PROXY']
        ALL_PROXY   = $cur['ALL_PROXY']
    }
    $res = Invoke-Doctor $map
    Show-DoctorResult $res
}

# ============================ 入口 ============================
try {
    Write-Host ''
    Write-Host '  Codex 代理修复工具' -ForegroundColor White
    Write-Host '  （只改用户级环境变量，不动系统代理和其他软件）' -ForegroundColor DarkGray

    if ($Status) {
        Show-Status
        exit 0
    }
    if ($Rollback) {
        Invoke-Rollback
        exit 0
    }
    Invoke-Apply $Port
    exit 0
} catch {
    Write-Host ''
    Write-Bad ("出错了：" + $_.Exception.Message)
    Write-Info '详细信息已写入 %LOCALAPPDATA%\CodexProxyFix\run.log'
    Write-Log ("ERROR " + $_.Exception.ToString())
    exit 1
}
