#Requires -Version 5.0
<#
.SYNOPSIS
    启动 Qwen3-ASR（offline Gradio / streaming）。实际逻辑按 PowerShell 7 执行。
.DESCRIPTION
    主路径：无参运行后交互选择要启动的服务（可单开或同开多个）。
.PARAMETER Mode
    direct = 本机直接运行；docker = docker compose（本项目未配置 compose，仅占位）。
.PARAMETER Port
    仅当最终只启动一个需端口的服务时，作为该服务的端口搜索起点。
.PARAMETER Service
    内部/自动化用：跳过菜单，直接启动指定 Id。日常请无参走交互。
#>
[CmdletBinding()]
param(
    [ValidateSet('direct', 'docker')]
    [string]$Mode = 'direct',

    [int]$Port = 0,

    [string]$Service = ''
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw '未找到 PowerShell 7 (pwsh)。请先全局安装：winget install --id Microsoft.PowerShell -e'
    }
    $argList = @('-NoProfile', '-File', $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        $argList += "-$key"
        $val = $PSBoundParameters[$key]
        if ($val -isnot [System.Management.Automation.SwitchParameter]) {
            $argList += [string]$val
        }
    }
    & $pwsh.Source @argList
    exit $LASTEXITCODE
}

Set-Location $PSScriptRoot

$FfmpegBin = 'E:\Programs\ffmpeg-master-latest-win64-gpl\bin'
if (Test-Path $FfmpegBin) {
    $env:Path = "$FfmpegBin;$env:Path"
} else {
    Write-Warning "未找到本机 ffmpeg：$FfmpegBin"
}

if (-not $env:HF_ENDPOINT) {
    $env:HF_ENDPOINT = 'https://hf-mirror.com'
}
if (-not $env:HF_HOME) {
    $env:HF_HOME = 'E:\huggingface_cache'
}

function Show-GpuStatus {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        Write-Warning '未检测到 nvidia-smi，跳过 GPU 检查。'
        return
    }
    Write-Host '=== GPU 状态 ===' -ForegroundColor Cyan
    & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
}

function Test-PortBusy {
    param([int]$TargetPort)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $TargetPort)
        $listener.Start()
        return $false
    } catch {
        return $true
    } finally {
        if ($null -ne $listener) { $listener.Stop() }
    }
}

function Get-FreePort {
    param(
        [int]$StartPort,
        [int]$MaxTries = 50
    )
    if ($StartPort -lt 1) { $StartPort = 1024 }
    $end = $StartPort + $MaxTries - 1
    if ($end -gt 65535) { $end = 65535 }
    $p = $StartPort
    while ($p -le $end) {
        if (-not (Test-PortBusy -TargetPort $p)) {
            if ($p -ne $StartPort) {
                Write-Host "端口 $StartPort 已占用，顺延到 $p" -ForegroundColor Yellow
            }
            return $p
        }
        $p++
    }
    throw "从 $StartPort 起连续探测均被占用，放弃。"
}

function Select-ServicesInteractive {
    param([object[]]$AllServices)

    if ($AllServices.Count -eq 0) {
        throw '未配置 $Services，请按项目改写模板。'
    }
    if ($AllServices.Count -eq 1) {
        Write-Host "仅一个服务，直接启动：$($AllServices[0].Label)" -ForegroundColor Cyan
        return @($AllServices[0])
    }

    Write-Host ''
    Write-Host '=== 启动哪些服务？===' -ForegroundColor Cyan
    for ($i = 0; $i -lt $AllServices.Count; $i++) {
        $svc = $AllServices[$i]
        $portHint = if ($svc.NeedsPort) { "端口起点 $($svc.PreferredPort)" } else { '无需端口' }
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $svc.Label, $portHint)
    }
    Write-Host ("  [{0}] 全部开" -f ($AllServices.Count + 1))
    Write-Host '  [0] 取消'
    Write-Host ''

    $defaultChoice = '1'
    $raw = Read-Host "请选择（可多选，逗号分隔，如 1,2；默认 $defaultChoice）"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultChoice }

    if ($raw.Trim() -eq '0') {
        throw '已取消启动。'
    }

    $allIndex = $AllServices.Count + 1
    $parts = $raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($part in $parts) {
        $n = 0
        if (-not [int]::TryParse($part, [ref]$n)) {
            throw "无效选项：$part"
        }
        if ($n -eq $allIndex) {
            return @($AllServices)
        }
        if ($n -lt 1 -or $n -gt $AllServices.Count) {
            throw "选项超出范围：$n"
        }
        $selected.Add($AllServices[$n - 1])
    }

    if ($selected.Count -eq 0) {
        throw '未选择任何服务。'
    }

    $byId = [ordered]@{}
    foreach ($s in $selected) { $byId[$s.Id] = $s }
    return @($byId.Values)
}

function Assert-GpuOkForSelection {
    param([object[]]$Selected)

    $gpuServices = @($Selected | Where-Object { $_.UsesGpu })
    if ($gpuServices.Count -le 1) { return }

    $labels = ($gpuServices | ForEach-Object { $_.Label }) -join ', '
    Write-Host ''
    Write-Host "已选多个占卡服务：$labels" -ForegroundColor Yellow
    Write-Host '16GB 显存下同时加载多个推理服务容易 OOM。请确认剩余显存足够，或改回只开一个。' -ForegroundColor Yellow
    $confirm = Read-Host '仍要继续？[y/N]'
    if ($confirm -notmatch '^[yY]') {
        throw '已取消：多服务占卡未确认。'
    }
}

function Get-UvCommand {
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) { throw '未找到 uv，请先安装 uv。' }
    return $uv.Source
}

$Services = @(
    [pscustomobject]@{
        Id            = 'offline'
        Label         = 'offline（Gradio：1.7B + Aligner + transformers）'
        PreferredPort = 8000
        NeedsPort     = $true
        UsesGpu       = $true
    }
    [pscustomobject]@{
        Id            = 'streaming'
        Label         = 'streaming（实时流式：1.7B + vLLM）'
        PreferredPort = 8001
        NeedsPort     = $true
        UsesGpu       = $true
    }
)

function Start-ProjectService {
    param(
        [Parameter(Mandatory)]
        [object]$Service,

        [Parameter(Mandatory)]
        [string]$RunMode,

        [int]$ListenPort = 0
    )

    if ($RunMode -eq 'docker') {
        throw '本项目 start.ps1 未配置 docker 启动；请用 -Mode direct，或自行 docker run qwenllm/qwen3-asr。'
    }

    $null = Get-UvCommand
    $venvPy = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path $venvPy)) {
        throw "未找到虚拟环境：$venvPy。请先按 RUN.md 执行 uv venv 与依赖安装。"
    }

    # 不用 uv run qwen-asr-demo*.exe：uv trampoline 在仓库迁路径后会失败；改走模块入口。
    function Invoke-QwenEntry {
        param(
            [Parameter(Mandatory)][string]$ImportSpec,
            [Parameter(Mandatory)][string]$Argv0,
            [Parameter(Mandatory)][string[]]$CliArgs
        )
        $mod, $fn = $ImportSpec -split ':', 2
        & $venvPy -c "import sys; from $mod import $fn as _main; sys.argv=['$Argv0']+sys.argv[1:]; raise SystemExit(_main() or 0)" @CliArgs
    }

    switch ($Service.Id) {
        'offline' {
            $backendKw = '{"device_map":"cuda:0","dtype":"bfloat16","max_inference_batch_size":8,"max_new_tokens":256}'
            $alignerKw = '{"device_map":"cuda:0","dtype":"bfloat16"}'
            Write-Host "启动 offline Gradio → http://127.0.0.1:$ListenPort" -ForegroundColor Green
            $asrCkpt = 'Qwen/Qwen3-ASR-1.7B'
            $alignerCkpt = 'Qwen/Qwen3-ForcedAligner-0.6B'
            if (Test-Path 'E:\huggingface_cache\Qwen3-ASR-1.7B\config.json') {
                $asrCkpt = 'E:\huggingface_cache\Qwen3-ASR-1.7B'
            }
            if (Test-Path 'E:\huggingface_cache\Qwen3-ForcedAligner-0.6B\config.json') {
                $alignerCkpt = 'E:\huggingface_cache\Qwen3-ForcedAligner-0.6B'
            }
            Invoke-QwenEntry -ImportSpec 'qwen_asr.cli.demo:main' -Argv0 'qwen-asr-demo' -CliArgs @(
                '--asr-checkpoint', $asrCkpt,
                '--aligner-checkpoint', $alignerCkpt,
                '--backend', 'transformers',
                '--cuda-visible-devices', '0',
                '--backend-kwargs', $backendKw,
                '--aligner-kwargs', $alignerKw,
                '--ip', '0.0.0.0',
                '--port', "$ListenPort"
            )
            if ($LASTEXITCODE -ne 0) { throw "offline 退出码：$LASTEXITCODE" }
            return
        }
        'streaming' {
            & $venvPy -c "import vllm" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host 'streaming 需要 vLLM；Windows 本机装不上官方 vllm==0.14.0（无 win_amd64 wheel）。' -ForegroundColor Yellow
                Write-Host '可选：启动 Docker Desktop 后用 qwenllm/qwen3-asr 镜像，或 WSL2/Linux 安装 vLLM。' -ForegroundColor Yellow
                throw 'streaming 暂不可用：缺少 vLLM（Windows）。请先用菜单 [1] offline。'
            }
            $asrCkpt = 'Qwen/Qwen3-ASR-1.7B'
            if (Test-Path 'E:\huggingface_cache\Qwen3-ASR-1.7B\config.json') {
                $asrCkpt = 'E:\huggingface_cache\Qwen3-ASR-1.7B'
            }
            Write-Host "启动 streaming Demo → http://127.0.0.1:$ListenPort" -ForegroundColor Green
            Invoke-QwenEntry -ImportSpec 'qwen_asr.cli.demo_streaming:main' -Argv0 'qwen-asr-demo-streaming' -CliArgs @(
                '--asr-model-path', $asrCkpt,
                '--gpu-memory-utilization', '0.85',
                '--host', '0.0.0.0',
                '--port', "$ListenPort"
            )
            if ($LASTEXITCODE -ne 0) { throw "streaming 退出码：$LASTEXITCODE" }
            return
        }
        default {
            throw "未知服务：$($Service.Id)"
        }
    }
}

Show-GpuStatus

if ($Service) {
    $match = @($Services | Where-Object { $_.Id -eq $Service })
    if ($match.Count -eq 0) {
        throw "未知服务 Id：$Service。可选：$($Services.Id -join ', ')"
    }
    $chosen = $match
} else {
    $chosen = Select-ServicesInteractive -AllServices $Services
    Assert-GpuOkForSelection -Selected $chosen
}

$multi = $chosen.Count -gt 1

if ($multi) {
    $started = @()
    foreach ($svc in $chosen) {
        $listen = 0
        if ($svc.NeedsPort) {
            $listen = Get-FreePort -StartPort $svc.PreferredPort
            Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
        }

        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.AddRange([string[]]@('-NoProfile', '-File', $PSCommandPath, '-Mode', $Mode, '-Service', $svc.Id))
        if ($listen -gt 0) {
            $argList.Add('-Port')
            $argList.Add("$listen")
        }

        $p = Start-Process -FilePath 'pwsh' -ArgumentList $argList -PassThru -WorkingDirectory $PSScriptRoot
        $started += [pscustomobject]@{ Id = $svc.Id; Label = $svc.Label; Port = $listen; Pid = $p.Id }
        Write-Host "已后台启动 $($svc.Label) PID=$($p.Id)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '=== 已启动 ===' -ForegroundColor Cyan
    foreach ($s in $started) {
        $portInfo = if ($s.Port -gt 0) { " port=$($s.Port)" } else { '' }
        Write-Host ("- {0}{1} pid={2}" -f $s.Label, $portInfo, $s.Pid)
    }
    Write-Host '各服务在独立进程中运行；结束请自行停对应 PID。' -ForegroundColor Yellow
    return
}

$svc = $chosen[0]
$listen = 0
if ($svc.NeedsPort) {
    $startPort = $svc.PreferredPort
    if ($Port -gt 0) { $startPort = $Port }
    $listen = Get-FreePort -StartPort $startPort
    Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
}

Start-ProjectService -Service $svc -RunMode $Mode -ListenPort $listen