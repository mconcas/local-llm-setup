# llama.cpp server for NVIDIA Jetson Orin (JetPack 6 / L4T r36.4, CUDA 12.6).
# The upstream server-cuda arm64 image is built with CUDA 12.8 and no sm_87
# cubin, which the Tegra driver rejects; this builds a pinned llama-server
# release against the L4T toolchain instead. Build on the Jetson itself:
# GGML_NATIVE tunes for the build host's CPU.

ARG L4T_JETPACK_TAG=r36.4.0
ARG L4T_CUDA_RUNTIME_TAG=12.6.11-runtime

FROM nvcr.io/nvidia/l4t-jetpack:${L4T_JETPACK_TAG} AS build

ARG LLAMA_CPP_REF=b10373
# The Orin Nano has 6 cores but only ~7 GiB of shared RAM; nvcc jobs are
# memory-hungry, so default below $(nproc).
ARG BUILD_JOBS=4

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git cmake build-essential libcurl4-openssl-dev && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${LLAMA_CPP_REF}" \
      https://github.com/ggml-org/llama.cpp /src

RUN cmake -S /src -B /build \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES=87 \
      -DLLAMA_CURL=ON \
      -DBUILD_SHARED_LIBS=OFF \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF && \
    cmake --build /build --target llama-server -j "${BUILD_JOBS}"

FROM nvcr.io/nvidia/l4t-cuda:${L4T_CUDA_RUNTIME_TAG}

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl libcurl4 libgomp1 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /build/bin/llama-server /app/llama-server

ENV LC_ALL=C.utf8

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]
