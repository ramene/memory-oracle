# mae-video-ingestion — Qwen2.5-VL native-video mode + Whisper transcript pipeline
#
# Pinned to today's known-working stack (validated 2026-06-05/06-06 against
# Two Minute Papers AlphaProof Nexus video + López QuantCon keynote + Warrior
# Cameron pullback). Eliminates the 6/8 cold-start bugs that previously cost
# ~30 minutes of pip-resolve + version-drift debugging per fresh Deepnote
# machine spin-up.
#
# Build:
#   docker build -t ghcr.io/ramene/mae-video-ingestion:latest \
#       notebooks/video-ingestion
#
# Or via CI: .github/workflows/build-video-ingestion-image.yml builds + pushes
# to ghcr.io/ramene/mae-video-ingestion on every change to this file or the
# notebook itself.

ARG CUDA_VERSION=13.0.0
ARG UBUNTU_VERSION=22.04

# ── Stage 1: Base CUDA + system deps ──────────────────────────────────────────
# CUDA 13.0 base matches the torch 2.12.0+cu130 wheels published at
# https://download.pytorch.org/whl/cu130 . Deepnote's labeled "CUDA 12.3" L4
# machines actually run a CUDA 13.0+ driver under the TF base image, which is
# why their notebook resolves torch+cu130 successfully — we just need to
# match the toolkit in our own image to remove the cold-start install.
FROM nvidia/cuda:${CUDA_VERSION}-cudnn-runtime-ubuntu${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System deps. Python 3.11 from deadsnakes PPA — Ubuntu 22.04's apt-shipped
# python3.11 is the 3.11.0~rc1 pre-release which lacks sys.get_int_max_str_digits
# and other 3.11.0-final features PyTorch 2.12+ assumes are present. Without
# deadsnakes, `import torch._dynamo` fails with AttributeError at module load.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        software-properties-common \
        ca-certificates \
        curl \
        && \
    add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        python3.11 python3.11-dev python3.11-venv python3.11-distutils \
        ffmpeg \
        git \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11 && \
    ln -sf /usr/bin/python3.11 /usr/local/bin/python && \
    ln -sf /usr/bin/python3.11 /usr/local/bin/python3 && \
    python -m pip install --upgrade pip setuptools wheel

# ── Stage 2: PyTorch (huge layer — cache aggressively) ────────────────────────
# torch 2.12.0+cu130 is the version that runs in the validated Deepnote env.
# Letting torchvision/torchaudio resolve from the same cu130 index keeps the
# CUDA runtime ABI consistent. PyPI's plain `torch` would resolve to a CPU or
# generic-CUDA build; pinning the index is non-optional.
RUN pip install --index-url https://download.pytorch.org/whl/cu130 \
        torch==2.12.0 \
        torchvision \
        torchaudio

# ── Stage 3: HuggingFace / ML stack ───────────────────────────────────────────
# Pinned to today's working set per Deepnote runtime logs:
#   transformers 5.10.1 — Qwen2.5-VL processor signature stable here
#   bitsandbytes 0.49.2 — 4-bit NF4 quantization (defer activation until needed)
# accelerate left at a recent floor compatible with transformers 5.x.
RUN pip install \
        transformers==5.10.1 \
        accelerate \
        bitsandbytes==0.49.2 \
        safetensors \
        sentencepiece \
        einops

# ── Stage 4: Video processing + Whisper ────────────────────────────────────────
# decord 0.6.0 — fast video decoder Qwen2.5-VL uses via qwen-vl-utils.
# qwen-vl-utils 0.0.14 (current latest) supports return_video_kwargs needed
# for native video mode. --no-deps prevents it from downgrading torch or
# transformers if its setup.py has loose upper bounds.
RUN pip install \
        decord==0.6.0 \
        openai-whisper \
        ffmpeg-python \
        Pillow

RUN pip install --no-deps qwen-vl-utils==0.0.14

# ── Stage 5: yt-dlp + misc CLI tools ──────────────────────────────────────────
RUN pip install \
        yt-dlp \
        requests \
        tqdm

# ── Stage 6: Environment + workdir ────────────────────────────────────────────
ENV FORCE_QWENVL_VIDEO_READER=decord \
    TOKENIZERS_PARALLELISM=false \
    HF_HOME=/work/.hf-cache \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    TRANSFORMERS_OFFLINE=0 \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

WORKDIR /work
RUN mkdir -p /work/.hf-cache

# ── Verification — fail-fast if a pinned version drifted ──────────────────────
RUN python -c "import torch; assert torch.__version__.startswith('2.12'), torch.__version__; \
               import transformers; assert transformers.__version__.startswith('5.10'), transformers.__version__; \
               import decord; assert decord.__version__ == '0.6.0', decord.__version__; \
               import qwen_vl_utils, inspect; \
               sig = str(inspect.signature(qwen_vl_utils.process_vision_info)); \
               assert 'return_video_kwargs' in sig, f'qwen-vl-utils signature drift: {sig}'; \
               import bitsandbytes, whisper, yt_dlp; \
               print(f'OK torch={torch.__version__} transformers={transformers.__version__} decord={decord.__version__} qwen-vl-utils={getattr(qwen_vl_utils, \"__version__\", \"?\")}')"

LABEL org.opencontainers.image.source="https://github.com/ramene/memory-oracle" \
      org.opencontainers.image.description="Pinned Qwen2.5-VL + Whisper video-ingestion stack for Deepnote (Task #121, mae-curriculae)" \
      org.opencontainers.image.licenses="MIT"

CMD ["python", "-c", "import torch; print(f'CUDA available: {torch.cuda.is_available()}'); print(f'GPU: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"none\"}')"]
