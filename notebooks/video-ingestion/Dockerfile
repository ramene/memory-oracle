# mae-video-ingestion — Qwen2.5-VL native-video mode + Whisper transcript pipeline
#
# Pinned to today's known-working stack (validated 2026-06-05 / 06-06 against
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
#
# Use in Deepnote:
#   1. Environment selection → Set up new Docker image → ghcr.io/ramene/mae-video-ingestion:latest
#      OR Environment selection → Dockerfile → ./Dockerfile (builds in Deepnote)
#   2. Start machine — Deepnote pulls the image (~30s vs ~5min pip resolve)
#   3. Run cells — no apt-get / pip install needed; everything's baked.

ARG CUDA_VERSION=12.3.2
ARG UBUNTU_VERSION=22.04

# ── Stage 1: Base CUDA + system deps ──────────────────────────────────────────
FROM nvidia/cuda:${CUDA_VERSION}-cudnn9-runtime-ubuntu${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System deps — ffmpeg is required for video chunking; git for pip-from-source.
# Python 3.11 (matches Deepnote default); pip + venv tooling.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        python3.11 python3.11-dev python3.11-venv \
        python3-pip \
        ffmpeg \
        git \
        curl \
        ca-certificates \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/python3.11 /usr/local/bin/python && \
    ln -sf /usr/bin/python3.11 /usr/local/bin/python3 && \
    python -m pip install --upgrade pip setuptools wheel

# ── Stage 2: PyTorch (huge layer — cache aggressively) ────────────────────────
# Targeting CUDA 12.3 wheels. Pinned to torch 2.5.1 + torchvision 0.20.1 as the
# nearest-stable matching what Deepnote's TF 2.19 GPU base runs against. Bump
# only when validated end-to-end on Qwen2.5-VL native video mode.
RUN pip install --index-url https://download.pytorch.org/whl/cu123 \
        torch==2.5.1 \
        torchvision==0.20.1 \
        torchaudio==2.5.1

# ── Stage 3: HuggingFace / ML stack ───────────────────────────────────────────
# Versions pinned to today's working set:
#   transformers 4.49.0  — Qwen2.5-VL processor signature stable here
#   accelerate   1.0.1   — model.from_pretrained device_map support
#   bitsandbytes 0.44.1  — 4-bit NF4 quantization (defer activation until needed)
#   safetensors  0.4.5   — model weight loading
RUN pip install \
        transformers==4.49.0 \
        accelerate==1.0.1 \
        bitsandbytes==0.44.1 \
        safetensors==0.4.5 \
        sentencepiece==0.2.0 \
        einops==0.8.0

# ── Stage 4: Video processing + Whisper ────────────────────────────────────────
# decord 0.6.0 is the fast video decoder Qwen2.5-VL uses via qwen-vl-utils.
# qwen-vl-utils 0.0.8+ adds return_video_kwargs (required for native video mode).
# openai-whisper for audio transcript extraction (base model recommended for CPU
# fallback compatibility; larger models swappable via WHISPER_MODEL env).
RUN pip install \
        decord==0.6.0 \
        openai-whisper==20240930 \
        ffmpeg-python==0.2.0 \
        Pillow==10.4.0

# qwen-vl-utils — installed with --no-deps to prevent it pulling in older
# transformers/torch and breaking the stack above. This mirrors the working
# notebook Cell 2 install pattern.
RUN pip install --no-deps qwen-vl-utils==0.0.8

# ── Stage 5: yt-dlp + misc CLI tools ──────────────────────────────────────────
RUN pip install \
        yt-dlp==2024.10.22 \
        requests==2.32.3 \
        tqdm==4.66.5

# ── Stage 6: Environment + workdir ────────────────────────────────────────────
ENV FORCE_QWENVL_VIDEO_READER=decord \
    TOKENIZERS_PARALLELISM=false \
    HF_HOME=/work/.hf-cache \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    TRANSFORMERS_OFFLINE=0 \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# /work is the Deepnote-conventional workdir + mount point for /datasets/_deepnote_work/work
WORKDIR /work
RUN mkdir -p /work/.hf-cache

# ── Verification — fail-fast if a pinned version drifted ──────────────────────
RUN python -c "import torch; assert torch.__version__.startswith('2.5'), torch.__version__; \
               import transformers; assert transformers.__version__ == '4.49.0', transformers.__version__; \
               import decord; assert decord.__version__ == '0.6.0', decord.__version__; \
               import qwen_vl_utils, inspect; \
               sig = inspect.signature(qwen_vl_utils.process_vision_info); \
               assert 'return_video_kwargs' in str(sig), f'qwen-vl-utils signature drift: {sig}'; \
               import bitsandbytes; \
               import whisper; \
               print('✓ stack verified — torch %s, transformers %s, decord %s, qwen-vl-utils %s' % (torch.__version__, transformers.__version__, decord.__version__, getattr(qwen_vl_utils, '__version__', '?')))"

# Image metadata for traceability
LABEL org.opencontainers.image.source="https://github.com/ramene/memory-oracle" \
      org.opencontainers.image.description="Pinned Qwen2.5-VL + Whisper video-ingestion stack for Deepnote (Task #121, mae-curriculae)" \
      org.opencontainers.image.licenses="MIT"

# Default to a sanity-check command if run directly (not the Deepnote case;
# Deepnote starts Jupyter inside).
CMD ["python", "-c", "import torch; print(f'CUDA available: {torch.cuda.is_available()}'); print(f'GPU: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"none\"}')"]
