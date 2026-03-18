FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    bison \
    build-essential \
    ca-certificates \
    ccache \
    curl \
    dosfstools \
    e2fsprogs \
    file \
    flex \
    g++-multilib \
    gcc-multilib \
    gdisk \
    git \
    git-lfs \
    gnupg \
    gperf \
    imagemagick \
    jq \
    lib32readline-dev \
    lib32z1-dev \
    libdw-dev \
    libelf-dev \
    libgl1-mesa-dev \
    liblz4-tool \
    libsdl1.2-dev \
    libssl-dev \
    libxml2 \
    libxml2-utils \
    locales \
    lzop \
    openjdk-17-jdk \
    pngcrush \
    protobuf-compiler \
    python-is-python3 \
    python3 \
    python3-protobuf \
    qemu-utils \
    rsync \
    schedtool \
    squashfs-tools \
    unzip \
    xz-utils \
    xsltproc \
    zip \
    zlib1g-dev \
    zstd && \
    rm -rf /var/lib/apt/lists/*

RUN git lfs install --system

WORKDIR /workspace

CMD ["/bin/bash"]
