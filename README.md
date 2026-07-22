# Portable CUDA development container

This image provides a CUDA development environment, micromamba, and an SSH
service for VS Code Remote - SSH. Source code and
Hugging Face assets stay on the host through bind mounts.

## Use Cases

- VS Code (Your PC) <-> Linux (server) <-> Docker Container
- VS Code (Your PC) <-> Windows (server) <-> WSL <-> Docker Container

## Host prerequisites

- Docker Engine and the NVIDIA Container Toolkit must be installed on every
	host that runs GPU workloads.
- The NVIDIA driver must support the CUDA version selected by `CUDA_IMAGE` in
	the `Dockerfile`. A host CUDA toolkit installation is **not** required.
- To use the recommended `ProxyJump` setup, the Docker host must already be
	reachable through SSH. The container port is then bound only to localhost.

The image has CUDA 12.2 by default. For older drivers, rebuild with a CUDA base
image supported by the oldest target driver, for example:

		docker build \
			--build-arg CUDA_IMAGE=nvidia/cuda:12.6.3-devel-ubuntu24.04 \
			-t cuda-dev:ssh .

## Build

From this directory:

		docker build \
			-t cuda-dev:ssh .

To use proxy, for example:

		docker build \
			--network host \
			--build-arg HTTP_PROXY="$HTTP_PROXY" \
			--build-arg HTTPS_PROXY="$HTTPS_PROXY" \
			--build-arg NO_PROXY="$NO_PROXY" \
			-t cuda-dev:ssh .

The micromamba binary platform is configurable at build time. The default,
`linux-64`, is for `linux/amd64` images. For an ARM64 base image, use the
matching micromamba platform:

		docker build --build-arg MICROMAMBA_PLATFORM=linux-aarch64 -t cuda-dev:ssh .

Create project environments with micromamba after connecting to the container.
The entrypoint assigns the micromamba root prefix to the runtime UID/GID, so the
SSH user can create and update environments without `sudo`.
The root prefix is stored in a named volume below, so environments and installed
packages survive container recreation without committing a new image. For a
reproducible long-term setup, also pin dependencies in an `environment.yml` or
lock file and add the environment creation to the `Dockerfile`.

## Run with host projects and Hugging Face cache

Run this command **on the Docker host**. It maps the host's numeric UID/GID into
the container. Numeric IDs, not usernames, control permissions on bind mounts.
Therefore this works even when servers use different login names.

		docker volume create cuda-dev-vscode-server
		docker volume create cuda-dev-micromamba
		docker volume create cuda-dev-ssh-host-keys
		USERNAME=$(id -un)
		USER_UID=$(id -u)
		USER_GID=$(id -g)
		WORKSPACE=/media/npu-tao/disk4T/jason
		docker run -d --name cuda-dev \
			--gpus all \
			--restart unless-stopped \
			-p 127.0.0.1:3333:22 \
			-e USERNAME=$USERNAME \
			-e USER_UID="$USER_UID" \
			-e USER_GID="$USER_GID" \
			-e AUTHORIZED_KEYS_FILE=/run/secrets/authorized_keys \
			-v "$HOME/.ssh/authorized_keys:/run/secrets/authorized_keys:ro" \
			-v $WORKSPACE:/workspace \
			-v "${HF_HOME:-$HOME/.cache/huggingface}:/hf-cache" \
			-v cuda-dev-vscode-server:/home/$USERNAME/.vscode-server \
			-v cuda-dev-micromamba:/opt/micromamba \
			-v cuda-dev-ssh-host-keys:/ssh-host-keys \
			cuda-dev:ssh

The container exposes the Hugging Face cache as `/hf-cache` through `HF_HOME`.
If the cache is instead in `$HF_HOME/.cache/huggingface`, mount that exact path
by replacing the second bind-mount source, for example:

		-v "$HF_HOME/.cache/huggingface:/hf-cache"

Use a **named volume** for `/ssh-host-keys`. Otherwise host keys change on each
container recreation and VS Code/SSH will warn about a changed host key.

Use the `cuda-dev-micromamba` named volume for `/opt/micromamba`. It stores the
micromamba executable, package cache, and environments independently of the
container, so interactive package and environment changes survive container
recreation. Docker initializes an empty named volume with the image's existing
`/opt/micromamba` contents on its first attachment. Do not replace this with an
empty host-directory bind mount.

The initial run copies the public keys from the mounted `authorized_keys` file.
After changing keys, restart the container or recreate it. Password and root SSH
logins are disabled.

The `127.0.0.1:3333:22` mapping makes the container SSH service reachable only
from the Docker host. This is intentional: access it through the existing host
SSH connection with `ProxyJump`, rather than exposing another externally
reachable SSH port. Do not add a firewall rule for TCP port `3333` when using
this setup.

## Connect from VS Code

Add the existing Docker-host SSH endpoint to `~/.ssh/config` on the machine
running VS Code. Replace the example address, port, user, and key path with
your host connection details:

		Host cuda-dev-host
			HostName docker-host.example.com
			Port 22
			User host-login-name
			IdentityFile ~/.ssh/id_ed25519

Then add the container entry:

		Host cuda-dev
			HostName 127.0.0.1
			HostKeyAlias MIPLab-2-417-jason-2x-3090
			Port 3333
			User host-login-name
			IdentityFile ~/.ssh/id_ed25519
			IdentitiesOnly yes
			ProxyJump cuda-dev-host

Then run **Remote-SSH: Connect to Host...** in VS Code and select `cuda-dev`.
The SSH username must match the `USERNAME` value supplied to `docker run`.

`ProxyJump` creates the route below. It relies only on the already-exposed host
SSH service; the container port remains private to the host:

		VS Code machine -> docker-host.example.com:22 -> 127.0.0.1:3333 -> container:22

There are two SSH authentications: one to `cuda-dev-host`, then one to
`cuda-dev`. Both can use the same private key when its public key appears in the
host user's and container user's `authorized_keys` files.

### Windows SSH host with Docker in WSL

Use `ProxyCommand` to run `nc` inside the WSL distribution:

		Host cuda-dev-windows
			HostName docker-windows-host.example.com
			Port 22
			User windows-login-name
			IdentityFile ~/.ssh/id_ed25519
			IdentitiesOnly yes

		Host cuda-dev-wsl
			HostName ignored
			User container-login-name
			IdentityFile ~/.ssh/id_ed25519
			IdentitiesOnly yes
			ProxyCommand ssh cuda-dev-windows "wsl.exe -d Ubuntu-24.04 -- nc %h %p"

Replace `Ubuntu` with the WSL distribution that runs Docker. Run the following
on Windows to list installed distributions:

		wsl.exe -l -v

Install `nc` in that WSL distribution if necessary:

		sudo apt-get update && sudo apt-get install -y netcat-openbsd

Then select `cuda-dev-wsl` in VS Code Remote-SSH. Keep the Docker mapping
private to WSL:

		-p 127.0.0.1:3333:22

The route is:

		VS Code machine -> Windows SSH host -> wsl.exe -> WSL 127.0.0.1:3333 -> container:22

## Move environments to another server

The CUDA development image is independent of the mutable micromamba state.
Build the same image on the destination, pull it from a registry, or transfer
it once if rebuilding is impractical:

		docker save cuda-dev:ssh | pv | gzip > cuda-dev-ssh-image.tar.gz

Copy `cuda-dev-ssh-image.tar.gz` to the destination host. There, import it:

		pv -s "$(stat -c %s cuda-dev-ssh-image.tar.gz)" \
			cuda-dev-ssh-image.tar.gz \
			| gzip -dc \
			| docker load

Stop the container before archiving its volumes. On the source host, run the
following from the directory where the archives should be created:

		docker stop cuda-dev
		docker run --rm \
			-v cuda-dev-vscode-server:/from:ro \
			alpine tar -C /from -cf - . \
			| pv -s "$(docker run --rm -v cuda-dev-vscode-server:/from:ro alpine du -sb /from | awk '{print $1}')" \
			| gzip > cuda-dev-vscode-server.tar.gz
		docker run --rm \
			-v cuda-dev-micromamba:/from:ro \
			alpine tar -C /from -cf - . \
			| pv -s "$(docker run --rm -v cuda-dev-micromamba:/from:ro alpine du -sb /from | awk '{print $1}')" \
			| gzip > cuda-dev-micromambaz.tar.gz
		docker run --rm \
			-v cuda-dev-ssh-host-keys:/from:ro \
			-v "$PWD":/backup \
			alpine tar -C /from -czf /backup/cuda-dev-ssh-host-keys.tar.gz .

Copy both archives to the destination host. `cuda-dev-micromamba.tar.gz`
contains the created environments and installed packages. The SSH-host-key
archive contains private keys, so transfer and store it securely. On the
destination, create and restore both volumes before starting the container:

		docker volume create cuda-dev-vscode-server
		docker volume create cuda-dev-micromamba
		docker volume create cuda-dev-ssh-host-keys
		docker run --rm \
			-v cuda-dev-vscode-server:/to \
			-i alpine tar -C /to -xzf - \
			< <(pv -s "$(stat -c %s cuda-dev-vscode-server.tar.gz)" cuda-dev-vscode-server.tar.gz)
		docker run --rm \
			-v cuda-dev-micromamba:/to \
			-i alpine tar -C /to -xzf - \
			< <(pv -s "$(stat -c %s cuda-dev-micromamba.tar.gz)" cuda-dev-micromamba.tar.gz)
		docker run --rm \
			-v cuda-dev-ssh-host-keys:/to \
			-v "$PWD":/backup:ro \
			alpine tar -C /to -xzf /backup/cuda-dev-ssh-host-keys.tar.gz

Start the imported image using the destination host's identity and mount paths:

		docker run -d --name cuda-dev \
			--gpus all \
			--restart unless-stopped \
			-p 127.0.0.1:3333:22 \
			-e USERNAME="$(id -un)" \
			-e USER_UID="$(id -u)" \
			-e USER_GID="$(id -g)" \
			-e AUTHORIZED_KEYS_FILE=/run/secrets/authorized_keys \
			-v "$HOME/.ssh/authorized_keys:/run/secrets/authorized_keys:ro" \
			-v /path/to/projects:/workspace \
			-v "${HF_HOME:-$HOME/.cache/huggingface}:/hf-cache" \
			-v cuda-dev-vscode-server:/home/$USERNAME/.vscode-server \
			-v cuda-dev-micromamba:/opt/micromamba \
			-v cuda-dev-ssh-host-keys:/ssh-host-keys \
			cuda-dev:ssh

This is portable across different host **usernames and UID/GIDs**. PID (process
ID) does not matter. At startup, the entrypoint creates the container SSH user
using the destination values from `USER_UID` and `USER_GID`, then assigns the
micromamba volume to that identity. The restored environments remain available
and can be modified by the new user.

`docker save` does not include mounted data. Copy these separately when needed:

- `/workspace`: host bind mount containing projects.
- `/hf-cache`: host bind mount containing Hugging Face models and datasets.
- `/opt/micromamba`: named volume containing the micromamba installation,
	 package cache, and environments. Restore its archive to retain interactive
	 environment changes.
- `/ssh-host-keys`: named volume containing SSH server identity keys. Creating
	 a fresh volume on the destination creates a new SSH identity. Restore the
	 archived volume above instead when clients must continue trusting the same
	 container host key.
- `/run/secrets/authorized_keys`: bind-mounted host public keys. Mount the
	 destination host's authorized-key file when starting the imported image.

## Notes on portability

- A container cannot provide its own NVIDIA kernel driver. The host driver must
	be compatible with the image CUDA runtime.
- Build for the correct CPU architecture. An image built as `linux/amd64` does
	not directly run on an `arm64` server.
- Runtime UID/GID mapping avoids permission issues for bind-mounted files, but
	it cannot repair files already owned by another numeric ID on the host.
