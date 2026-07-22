# Choose this CUDA version to be no newer than the oldest NVIDIA driver on
# hosts that will run this image. The host driver, not the host CUDA toolkit,
# is what matters at runtime.
ARG CUDA_IMAGE=nvidia/cuda:12.2.2-devel-ubuntu22.04
FROM ${CUDA_IMAGE}

ARG MICROMAMBA_PLATFORM=linux-64

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    MAMBA_ROOT_PREFIX=/opt/micromamba \
    PATH=/opt/micromamba/bin:${PATH} \
    HF_HOME=/hf-cache \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssh-server \
        tmux \
        nano \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/micromamba/bin \
    && curl -L \
        --tlsv1.3 --tls-max 1.3 \
        "https://micro.mamba.pm/api/micromamba/${MICROMAMBA_PLATFORM}/latest" \
        | tar -xj -C /opt/micromamba/bin --strip-components=1 bin/micromamba \
    && ln -s /opt/micromamba/bin/micromamba /usr/local/bin/micromamba \
    && printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ $- == *i* ]] || return 0' \
        'eval "$(micromamba shell hook --shell bash --root-prefix /opt/micromamba)"' \
        > /etc/profile.d/micromamba.sh \
    && chmod 644 /etc/profile.d/micromamba.sh \
    && printf '%s\n' \
        '' \
        '# Initialize micromamba for interactive non-login Bash shells.' \
        'source /etc/profile.d/micromamba.sh' \
        >> /etc/bash.bashrc

# SSH host keys should be persisted by mounting a named volume at this path.
# Public-key authentication is the only supported SSH authentication method.
RUN mkdir -p /run/sshd /run/secrets /ssh-host-keys /workspace /hf-cache \
    && chmod 755 /ssh-host-keys \
    && sed -ri \
        -e 's@^[#[:space:]]*PasswordAuthentication[[:space:]].*@PasswordAuthentication no@' \
        -e 's@^[#[:space:]]*KbdInteractiveAuthentication[[:space:]].*@KbdInteractiveAuthentication no@' \
        -e 's@^[#[:space:]]*PermitRootLogin[[:space:]].*@PermitRootLogin no@' \
        -e 's@^[#[:space:]]*UsePAM[[:space:]].*@UsePAM no@' \
        /etc/ssh/sshd_config \
    && printf '%s\n' \
        'PubkeyAuthentication yes' \
        'AuthorizedKeysFile .ssh/authorized_keys' \
        'HostKey /ssh-host-keys/ssh_host_ed25519_key' \
        'HostKey /ssh-host-keys/ssh_host_rsa_key' \
        >> /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/container-entrypoint
RUN chmod 755 /usr/local/bin/container-entrypoint

WORKDIR /workspace
EXPOSE 22

ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]