#!/usr/bin/env bash
set -euo pipefail

# These are deliberately runtime settings. Set USER_UID and USER_GID to the
# owner of bind-mounted host files; the host login name does not need to match.
USERNAME="${USERNAME:-dev}"
USER_UID="${USER_UID:-1000}"
USER_GID="${USER_GID:-1000}"
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-/run/secrets/authorized_keys}"

if [[ ! "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "USERNAME must be a valid Linux username." >&2
    exit 2
fi

if ! [[ "${USER_UID}" =~ ^[0-9]+$ && "${USER_GID}" =~ ^[0-9]+$ ]]; then
    echo "USER_UID and USER_GID must be numeric." >&2
    exit 2
fi

# Reuse a pre-existing numeric GID if the base image already has one; otherwise
# create the requested group. The group name is irrelevant to bind mounts.
GROUP_NAME="$(getent group "${USER_GID}" | cut -d: -f1 || true)"
if [[ -z "${GROUP_NAME}" ]]; then
    GROUP_NAME="${USERNAME}"
    if getent group "${GROUP_NAME}" >/dev/null; then
        GROUP_NAME="${USERNAME}-host"
    fi
    groupadd --gid "${USER_GID}" "${GROUP_NAME}"
fi

# -o permits a UID collision with an image-provided account. The SSH account
# still gets the requested numeric identity, which is what bind mounts require.
if ! getent passwd "${USERNAME}" >/dev/null; then
    useradd --non-unique --uid "${USER_UID}" --gid "${GROUP_NAME}" \
        --create-home --shell /bin/bash "${USERNAME}"
fi

# useradd creates a locked password entry. OpenSSH rejects locked accounts
# before checking authorized_keys, even when password authentication is off.
# Removing the password hash unlocks the account; sshd_config still forbids
# password and keyboard-interactive authentication.
passwd --delete "${USERNAME}" >/dev/null

USER_HOME="$(getent passwd "${USERNAME}" | cut -d: -f6)"
install -d -m 700 -o "${USER_UID}" -g "${USER_GID}" "${USER_HOME}/.ssh"

if [[ -f "${AUTHORIZED_KEYS_FILE}" ]]; then
    install -m 600 -o "${USER_UID}" -g "${USER_GID}" \
        "${AUTHORIZED_KEYS_FILE}" "${USER_HOME}/.ssh/authorized_keys"
fi

ensure_host_key() {
    local key_type="$1"
    local key_path="$2"
    shift 2

    # Keep an existing, valid private key.
    if [[ -s "${key_path}" ]] && ssh-keygen -y -f "${key_path}" >/dev/null 2>&1; then
        return 0
    fi

    # The key is missing, empty, or invalid. Remove any partial key pair.
    rm -f "${key_path}" "${key_path}.pub"

    # Generate a fresh private key and matching public key.
    echo "Generating new ${key_type} host key at ${key_path}."
    ssh-keygen -q -N '' -t "${key_type}" -f "${key_path}" "$@"
}

ensure_host_key ed25519 /ssh-host-keys/ssh_host_ed25519_key
ensure_host_key rsa /ssh-host-keys/ssh_host_rsa_key -b 4096

chmod 600 \
    /ssh-host-keys/ssh_host_ed25519_key \
    /ssh-host-keys/ssh_host_rsa_key

mkdir -p /workspace /hf-cache
chown "${USER_UID}:${USER_GID}" /workspace /hf-cache

# Environments are created interactively by the runtime SSH user. This also
# remaps environments captured in a committed image to the current host UID/GID.
mkdir -p "${MAMBA_ROOT_PREFIX}/envs" "${MAMBA_ROOT_PREFIX}/pkgs"
chown -R "${USER_UID}:${USER_GID}" "${MAMBA_ROOT_PREFIX}"

exec "$@"