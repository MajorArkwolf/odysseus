#!/bin/sh
# Entrypoint supporting two launch modes (see the dispatch below for detail):
#
#   - Started as root (docker compose): fix the #1 self-host footgun where a
#     root container writes root-owned files into bind-mounted host volumes that
#     the host user then can't update. Standard PUID/PGID pattern — create the
#     user, chown the writable paths, drop to PUID:PGID via gosu.
#   - Started with --user (the NixOS module): we're already the unprivileged
#     app user; the root-only steps are skipped and we exec the app directly.
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Two launch modes:
#
#   root  — `docker compose` on a desktop distro starts the container as root.
#           We create a matching user/group, repair ownership on the writable
#           paths, and drop to PUID:PGID via gosu at the end. This is the
#           PUID/PGID footgun fix (root-owned files in host bind mounts).
#
#   user  — the NixOS module starts the container with `--user PUID:PGID`. The
#           image was already built with a matching `odysseus` user owning /app
#           (see Dockerfile), and the host bind mounts are pre-owned via
#           tmpfiles, so none of the root-only steps below are needed — and
#           useradd/chown/gosu would all fail with EPERM if attempted. Skip
#           straight to running the app.
#
# The CUDA/vLLM/PATH setup further down runs in BOTH modes.
if [ "$(id -u)" = "0" ]; then
    # Reuse an existing matching group/user if the host's UID/GID already
    # corresponds to one in /etc/passwd (e.g. when the image is rebuilt
    # and "odysseus" already exists at the same id). Otherwise create.
    if ! getent group "$PGID" >/dev/null 2>&1; then
        groupadd -g "$PGID" odysseus
    fi
    if ! getent passwd "$PUID" >/dev/null 2>&1; then
        useradd -u "$PUID" -g "$PGID" -M -s /bin/sh -d /app odysseus
    fi

    # Repair ownership on every writable path the app touches at runtime.
    #
    # Bind-mounted dirs (/app/data, /app/logs) are the obvious ones, but
    # the app ALSO writes inside the image's own source tree at runtime:
    #   - services/cache/{search,content}/*  (search cache LRU)
    #   - services/search_analytics.json
    #   - services/search_engine_error.log
    #   - services/tts cache, etc.
    # These dirs were created as root during `docker build`, so dropping
    # to PUID:PGID would otherwise crash on the first import that tries
    # to mkdir them. Chown the whole /app tree — fast (<1s on this size)
    # and idempotent via the `-not -uid` filter so we only touch files
    # that need fixing.
    for dir in /app /app/data /app/logs; do
        if [ -d "$dir" ]; then
            # `find ... -not -uid` keeps this O(touched-files), not
            # O(everything), so terabyte-sized maildirs don't slow startup.
            find "$dir" -not -uid "$PUID" -print0 2>/dev/null \
                | xargs -0 -r chown "$PUID:$PGID" 2>/dev/null || true
        fi
    done
fi

# Cookbook installs vllm/etc. via `pip install --user`, which pulls
# nvidia-cuda-* wheels into /app/.local but does not set CUDA_HOME or
# symlink /usr/local/cuda. vllm 0.22+ then crashes during engine init
# when FlashInfer tries to JIT a sampler kernel ("Could not find nvcc",
# then "CUDA compiler and toolkit headers are incompatible" on the
# mixed cuda-nvcc 13.3 / cuda-runtime 13.0 wheel combo).
#
# Auto-set CUDA_HOME if a pip-installed nvcc is present, and disable the
# FlashInfer JIT sampler — sampler only, no impact on attention path.
# No-op when vllm isn't installed.
#
# Checked layouts (all are real pip-wheel install paths):
#   nvidia/cu13        — nvidia-nvcc-cu13 (CUDA 13.x wheel style)
#   nvidia/cu12        — nvidia-nvcc-cu12 (CUDA 12.x wheel style)
#   nvidia/cuda_nvcc   — nvidia-cuda-nvcc-cu12 (older cu12 sub-package style)
for cu in \
    /app/.local/lib/python*/site-packages/nvidia/cu13 \
    /app/.local/lib/python*/site-packages/nvidia/cu12 \
    /app/.local/lib/python*/site-packages/nvidia/cuda_nvcc; do
    if [ -x "$cu/bin/nvcc" ]; then
        export CUDA_HOME="$cu"
        break
    fi
done
# Disable the FlashInfer JIT sampler unconditionally — it is sampler-only
# and has no impact on the attention path, but requires nvcc + matching
# CUDA headers at startup. Without this, vLLM crashes with "Could not find
# nvcc" even when the GPU itself is fully visible to the container.
export VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"

# Make Cookbook-installed Python CLIs visible after `pip install --user`.
# vLLM and helper scripts land here because /app is the non-root user's HOME.
export PATH="/app/.local/bin:$PATH"

# Run first-time setup, then exec the app. When we started as root, do both via
# gosu so data/ files get the right ownership and signals (SIGTERM from
# `docker stop`) still reach uvicorn directly (gosu adds no extra shell layer,
# unlike su/sudo). When started with --user we're already the app user, so run
# in-process. setup.py is idempotent and `|| true` so it never blocks startup.
if [ "$(id -u)" = "0" ]; then
    gosu "$PUID:$PGID" python /app/setup.py || true
    exec gosu "$PUID:$PGID" "$@"
else
    python /app/setup.py || true
    exec "$@"
fi
