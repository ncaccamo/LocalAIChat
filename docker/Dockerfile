# LocalAIChat model-serving container — fully self-contained.
#
# The block delimited by the BUILDSTAGE START / BUILDSTAGE END marker lines
# below is a vendored copy of the ROCm 7.2.4 + Vulkan + llama.cpp build
# stage, maintained outside this repo and synced in verbatim. Do NOT
# hand-edit it here; edit the product tail below the END marker instead.
#
# BUILDSTAGE START v2026.09.06  (ubuntu 24.04 | ROCm 7.2.4 apt | Vulkan
# LunarG 1.4.357.1 | llama.cpp triple build rocm+vulkan+cpu | rocm714 parked)
# ============================================================
# [COMMON] Base image + global env.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TESSDATA_PREFIX=/usr/share/tesseract-ocr/5/tessdata

# [ROCM7] ROCm 7.2.4 stable toolchain (apt). Required by the rocm
# llama.cpp build below; also supplies the cmake the vulkan build uses.
# ---- ROCm 7.2.4 (STABLE, apt) ----
# Only rocm/apt repo needed - amdgpu/ is kernel driver packaging, irrelevant
# in a container and doesn't follow ROCm version numbering anyway.
RUN apt-get update && apt-get install -y wget gnupg2 ca-certificates && \
    mkdir -p /etc/apt/keyrings && \
    wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.4 noble main" > /etc/apt/sources.list.d/rocm.list && \
    printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/rocm-pin-600 && \
    apt-get update

RUN apt-get install -y --no-install-recommends \
    rocm-hip-runtime rocm-hip-sdk rocm-hip-runtime-dev \
    hip-runtime-amd hip-dev hipcc rocm-device-libs \
    rocblas hipblas rocm-smi-lib rocm-llvm rocminfo rocm-cmake cmake \
    && rm -rf /var/lib/apt/lists/*

ENV ROCM_PATH=/opt/rocm
ENV PATH=$ROCM_PATH/bin:$PATH
ENV LD_LIBRARY_PATH=$ROCM_PATH/lib:$LD_LIBRARY_PATH
ENV HIP_PATH=$ROCM_PATH

# [VULKAN] Vulkan loader/driver + LunarG SDK. Required by the vulkan
# llama.cpp build below.
# ---- Vulkan: LunarG SDK via TARBALL (apt packages deprecated by LunarG
# since May 2025) + libvulkan-dev (loader, not part of SDK) + mesa RADV driver ----
# [VULKAN] xz-utils + Vulkan loader + mesa RADV driver.
RUN apt-get update && apt-get install -y --no-install-recommends \
    xz-utils libvulkan-dev mesa-vulkan-drivers vulkan-tools \
    && rm -rf /var/lib/apt/lists/*

RUN wget -qO /tmp/vulkansdk.tar.xz \
    https://sdk.lunarg.com/sdk/download/1.4.357.1/linux/vulkansdk-linux-x86_64-1.4.357.1.tar.xz && \
    mkdir -p /opt/vulkan-sdk && \
    tar -xf /tmp/vulkansdk.tar.xz -C /opt/vulkan-sdk && \
    rm /tmp/vulkansdk.tar.xz

ENV VULKAN_SDK=/opt/vulkan-sdk/1.4.357.1/x86_64
ENV PATH=$VULKAN_SDK/bin:$PATH
ENV LD_LIBRARY_PATH=$VULKAN_SDK/lib:$LD_LIBRARY_PATH
ENV CMAKE_PREFIX_PATH=$VULKAN_SDK:$CMAKE_PREFIX_PATH

# Fast fail-check before the expensive builds below
RUN $VULKAN_SDK/bin/glslc --version && \
    find $VULKAN_SDK -iname "spirv-headers*config.cmake" | grep -q . && \
    echo ">>> Vulkan SDK verified OK" || \
    { echo "!!! Vulkan SDK verification FAILED - listing tree:"; \
      find $VULKAN_SDK -maxdepth 4 -iname "*spirv*"; exit 1; }

# [COMMON] Python + C/C++ build tooling (git, build-essential, libcurl)
# shared by both llama.cpp builds and the rocm714 venv.
# NOTE: this same layer also installs an OCR/PDF stack
# (tesseract-ocr*, ghostscript, poppler-utils, unpaper).
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv tesseract-ocr \
    tesseract-ocr-fra tesseract-ocr-eng tesseract-ocr-ita \
    tesseract-ocr-deu tesseract-ocr-spa \
    ghostscript poppler-utils libglib2.0-0 curl ca-certificates \
    git build-essential libcurl4-openssl-dev unpaper bc file \
    && rm -rf /var/lib/apt/lists/*

# [COMMON/OCR-only] Latin tessdata -- OCR use only.
RUN mkdir -p /usr/share/tesseract-ocr/5/tessdata && \
    wget -q https://github.com/tesseract-ocr/tessdata/raw/main/lat.traineddata \
         -O /usr/share/tesseract-ocr/5/tessdata/lat.traineddata

RUN tesseract --list-langs && \
    ln -sf /usr/bin/tesseract /usr/local/bin/tesseract && \
    ln -sf /usr/bin/gs /usr/local/bin/gs

# [ROCM714] Preview venv install ONLY. The llama.cpp build against it is
# skipped (the wheel ships no hip-lang-config.cmake, so CMake HIP can't
# configure). Full rationale + revisit/un-park checklist:
# ROCM714_NOTES.md, next to this Dockerfile.
# ---- ROCm 7.14 (PREVIEW, pip/wheel) - install kept for future use, the
# llama.cpp BUILD against it is disabled. See ROCM714_NOTES.md:
# this wheel combination doesn't ship hip-lang-config.cmake, so it can't
# currently compile new HIP source, only run pre-built ROCm workloads.
RUN python3 -m venv /opt/rocm714-venv && \
    /opt/rocm714-venv/bin/pip install --upgrade pip && \
    ( /opt/rocm714-venv/bin/pip install \
        --index-url https://repo.amd.com/rocm/whl-multi-arch/ \
        "rocm[libraries,devel,device-gfx1201]==7.14.0" \
      || echo "!!! ROCm 7.14 preview pip install failed - non-fatal, disabled anyway" )

# [LLAMA.CPP] Triple build in a single layer: build-rocm (-> *-rocm),
# build-vulkan (-> *-vulkan), build-cpu (-> *-cpu, portable). Splitting
# this RUN per-backend is the main work of a future per-backend marker split.
# ---- llama.cpp: build 3x (stable ROCm, Vulkan, portable CPU). rocm714 skipped. ----
# Shared libraries (libllama-server-impl.so etc) are copied to backend-
# specific dirs BEFORE the build tree is deleted - newer llama.cpp links
# these dynamically, and ROCm/Vulkan builds must not share the same
# filenames (different backend-specific implementations).
RUN git clone --depth 1 https://github.com/ggerganov/llama.cpp /opt/llama.cpp && \
    cd /opt/llama.cpp && \
    \
    echo ">>> Building STABLE ROCm 7.2.4 backend..." && \
    cmake -B build-rocm \
        -DGGML_HIP=ON -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release \
        -DAMDGPU_TARGETS=gfx1201 && \
    cmake --build build-rocm --config Release -j$(nproc) && \
    cp build-rocm/bin/llama-server /usr/local/bin/llama-server-rocm && \
    cp build-rocm/bin/llama-cli /usr/local/bin/llama-cli-rocm && \
    cp build-rocm/bin/llama-bench /usr/local/bin/llama-bench-rocm && \
    (cp build-rocm/bin/llama-qwen2vl-cli /usr/local/bin/llama-qwen2vl-cli-rocm || true) && \
    mkdir -p /usr/local/lib/llama-rocm && \
    find build-rocm -name "*.so*" -exec cp {} /usr/local/lib/llama-rocm/ \; && \
    rm -rf build-rocm && \
    \
    echo ">>> SKIPPING ROCm 7.14 preview backend - see docker/ROCM714_NOTES.md" && \
    \
    echo ">>> Building Vulkan backend (LunarG SDK)..." && \
    cmake -B build-vulkan \
        -DGGML_VULKAN=ON -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build-vulkan --config Release -j$(nproc) && \
    cp build-vulkan/bin/llama-server /usr/local/bin/llama-server-vulkan && \
    cp build-vulkan/bin/llama-cli /usr/local/bin/llama-cli-vulkan && \
    cp build-vulkan/bin/llama-bench /usr/local/bin/llama-bench-vulkan && \
    (cp build-vulkan/bin/llama-qwen2vl-cli /usr/local/bin/llama-qwen2vl-cli-vulkan || true) && \
    mkdir -p /usr/local/lib/llama-vulkan && \
    find build-vulkan -name "*.so*" -exec cp {} /usr/local/lib/llama-vulkan/ \; && \
    rm -rf build-vulkan && \
    \
    echo ">>> Building portable CPU backend (no GPU code). GGML_CPU_ALL_VARIANTS" && \
    echo "    + GGML_BACKEND_DL build one dispatch lib per x86-64 feature level and" && \
    echo "    pick the best at runtime, so an image compiled on this Zen 3 box runs" && \
    echo "    on any homelab CPU. GGML_NATIVE=OFF keeps -march=native out of it." && \
    echo "    GGML_BACKEND_DIR bakes in where to dlopen the libggml-cpu-*.so from:" && \
    echo "    the DL loader only searches the executable dir + cwd, NOT" && \
    echo "    LD_LIBRARY_PATH, and this layout puts the binary and the libs in" && \
    echo "    different trees (/usr/local/bin vs /usr/local/lib/llama-cpu)." && \
    cmake -B build-cpu \
        -DGGML_HIP=OFF -DGGML_VULKAN=OFF \
        -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON \
        -DGGML_BACKEND_DIR=/usr/local/lib/llama-cpu \
        -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build-cpu --config Release -j$(nproc) && \
    cp build-cpu/bin/llama-server /usr/local/bin/llama-server-cpu && \
    cp build-cpu/bin/llama-cli /usr/local/bin/llama-cli-cpu && \
    cp build-cpu/bin/llama-bench /usr/local/bin/llama-bench-cpu && \
    mkdir -p /usr/local/lib/llama-cpu && \
    find build-cpu -name "*.so*" -exec cp {} /usr/local/lib/llama-cpu/ \; && \
    rm -rf build-cpu && \
    \
    cd / && rm -rf /opt/llama.cpp

# [COMMON] Post-build cleanup.
RUN rm -rf /var/lib/apt/lists/* /root/.cache /tmp/* \
    && find /opt/rocm -type d -iname "*doc*" -exec rm -rf {} + 2>/dev/null || true

# [COMMON] Bake the default llama-* -> *-vulkan symlinks (rationale below).
# Bake the default (vulkan) llama-* symlinks at build time so the container
# is usable immediately and does NOT depend on entrypoint.sh being able to
# write into /usr/local/bin -- it can't, now that the container runs as a
# non-root host user (compose `user:`, so ./processed files aren't owned by
# root). entrypoint.sh still re-points these for a non-default LLAMA_BACKEND
# but tolerates failure; switching backend at runtime needs root or a rebuild.
RUN for b in llama-server llama-cli llama-bench llama-qwen2vl-cli; do \
        ln -sf "/usr/local/bin/$b-vulkan" "/usr/local/bin/$b" || true; \
    done

# BUILDSTAGE END

# ============================================================
# LocalAIChat-specific tail. NOTHING below this line is part of the synced
# buildstage -- do not copy it back upstream.
# ============================================================

# llama-swap: an OpenAI-compatible proxy that keeps ONE llama-server
# resident and hot-swaps it between the configured models on demand.
# This is what makes the Open WebUI model dropdown load/unload models:
# pick "code", llama-swap stops "chat" and starts "code". It lives here in
# the product tail rather than the vendored buildstage.
ARG LLAMA_SWAP_VERSION=251
RUN wget -qO /tmp/llama-swap.tar.gz \
      "https://github.com/mostlygeek/llama-swap/releases/download/v${LLAMA_SWAP_VERSION}/llama-swap_${LLAMA_SWAP_VERSION}_linux_amd64.tar.gz" && \
    tar -xzf /tmp/llama-swap.tar.gz -C /usr/local/bin llama-swap && \
    rm /tmp/llama-swap.tar.gz && \
    test -x /usr/local/bin/llama-swap

ENV HIP_VISIBLE_DEVICES=0
ENV ROCR_VISIBLE_DEVICES=0
ENV LLAMA_BACKEND=vulkan

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
