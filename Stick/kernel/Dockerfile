# Cross-compiles the x86-64 kernel from an arm64 (or any) host.
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu \
      bc bison flex libssl-dev libelf-dev xz-utils zstd cpio kmod python3 perl \
      curl ca-certificates patch rsync \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
