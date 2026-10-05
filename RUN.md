# 运行命令

- 项目：Qwen3-ASR（`qwen-asr` 本地可编辑安装）
- 生成时间：2026-09-08
- 运行方式：直接运行（uv + venv）；流式依赖 vLLM（Windows 若装失败再改 Docker）
- 硬件评估：满足（空卡 16GB 可跑 1.7B + Aligner；启动前须确认空闲显存）

## 环境准备

```powershell
$env:Path = "E:\Programs\ffmpeg-master-latest-win64-gpl\bin;" + $env:Path
$env:HF_ENDPOINT = "https://hf-mirror.com"
$env:UV_INDEX_URL = "https://pypi.tuna.tsinghua.edu.cn/simple"
$env:HF_HOME = "E:\huggingface_cache"

cd E:\AI\local-voice\Qwen3-ASR
uv venv --python 3.12 .venv
uv pip install -e ".[vllm]"
```

模型首次启动会自动下载到 `HF_HOME`（也可预拉）：

```powershell
$env:HF_ENDPOINT = "https://hf-mirror.com"
hf download Qwen/Qwen3-ASR-1.7B --local-dir E:\huggingface_cache\Qwen3-ASR-1.7B
hf download Qwen/Qwen3-ForcedAligner-0.6B --local-dir E:\huggingface_cache\Qwen3-ForcedAligner-0.6B
```

## 启动

- 推荐：`pwsh -NoProfile -File .\start.ps1`
- 说明：多服务时启动后按提示选择（可单开或同开多个）；不要默认全开
- 菜单：
  1. **offline**（默认）：Gradio 离线 UI，1.7B + ForcedAligner，transformers
  2. **streaming**：实时流式 Demo，1.7B，vLLM（`gpu_memory_utilization=0.85`）
- 等价手动命令：

```powershell
# offline
uv run qwen-asr-demo `
  --asr-checkpoint Qwen/Qwen3-ASR-1.7B `
  --aligner-checkpoint Qwen/Qwen3-ForcedAligner-0.6B `
  --backend transformers `
  --cuda-visible-devices 0 `
  --backend-kwargs '{"device_map":"cuda:0","dtype":"bfloat16","max_inference_batch_size":8,"max_new_tokens":256}' `
  --aligner-kwargs '{"device_map":"cuda:0","dtype":"bfloat16"}' `
  --ip 0.0.0.0 --port 8000

# streaming
uv run qwen-asr-demo-streaming `
  --asr-model-path Qwen/Qwen3-ASR-1.7B `
  --gpu-memory-utilization 0.85 `
  --host 0.0.0.0 `
  --port 8001
```

## 验证

- offline：浏览器打开脚本打印的 URL，上传 `asr_zh.wav` 或麦克风，应返回语言与文本（可看时间戳）
- streaming：打开流式页，对着麦克风说话应持续出字；日志无 CUDA OOM
- 样例音频：`https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-ASR-Repo/asr_zh.wav`

## 备注

- 镜像：HF=`hf-mirror.com`（官方 huggingface.co 探测超时）；PyPI/`uv`=`pypi.tuna.tsinghua.edu.cn`
- ffmpeg：`E:\Programs\ffmpeg-master-latest-win64-gpl\bin`
- `HF_HOME=E:\huggingface_cache`
- 两服务都占 GPU，不要默认同时开；同开时菜单会二次确认
- 本文件与 `start.ps1` 为本机记录，默认不提交
## 本机安装结果（2026-09-08）

- 基座安装成功：Python 3.12 venv + editable qwen-asr
- torch 已换成 CUDA 版：2.9.1+cu128（直链 wheel；勿用默认 index 误装 cpu）
- vLLM/streaming：Windows 无法安装官方 vllm 0.14.0；菜单保留但会提示改 Docker/WSL
- Docker Desktop 当前未运行
- ForcedAligner 已缓存约 1.71GB；1.7B 若 HF Xet 失败则用禁用 Xet 或 ModelScope 重试
- 镜像：HF=hf-mirror.com；PyPI 清华；torch=download.pytorch.org

## 审计备注（2026-09-09）
- 已修复 editable 映射 `E:\AI\local-voice\Qwen3-ASR` → `E:\AI\local-voice\Qwen3-ASR`。
- `start.ps1` 绕过损坏的 `qwen-asr-demo*.exe` trampoline，改调 `qwen_asr.cli.demo` / `demo_streaming`。
- Windows 上 `streaming` 仍因缺少 vLLM wheel 不可用，请用 offline。
