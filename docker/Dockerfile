# Build environment for LineageOS 24.0 (gts210ltexx, Linux 3.10 kernel built with GCC 4.9 prebuilts)
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates ccache cpio curl file flex g++-multilib gcc-multilib \
      git git-lfs gnupg gperf imagemagick kmod lib32ncurses5-dev lib32readline-dev lib32z1-dev \
      libdw-dev libelf-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \
      libxml2 libxml2-utils locales lz4 lzop m4 nano openjdk-17-jre-headless openssl patch perl \
      pngcrush protobuf-compiler python-is-python3 python3 python3-protobuf rsync schedtool \
      squashfs-tools unzip xsltproc xxd xz-utils zip zlib1g-dev zstd \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8 C.UTF-8
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} builder && useradd -m -u ${UID} -g ${GID} -s /bin/bash builder
USER builder
ENV USER=builder LANG=C.UTF-8
# No WORKDIR: scripts/docker-run.sh sets the working directory (-w) to the project root, which it
# mounts at its host path.
