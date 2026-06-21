FROM python:3.14-slim

# System deps. tmux is required by Cookbook for background downloads/serves.
# openssh-client is required for Cookbook remote server tests, setup, probes,
# downloads, and serves from Docker installs.
# git/cmake are required when Cookbook builds llama.cpp on first llama.cpp
# launch inside Docker.
# nodejs/npm provide npx for the optional built-in Browser MCP server.
# gosu lets the entrypoint drop privileges cleanly so signals still reach
# uvicorn directly (no extra shell layer like `su`/`sudo` would add).
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    curl \
    git \
    nodejs \
    npm \
    tmux \
    openssh-client \
    gosu \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first (layer cache). Optional extras (PyMuPDF AGPL, etc.)
# are opt-in so the default image stays MIT-core; see requirements-optional.txt.
ARG INSTALL_OPTIONAL=false
COPY requirements.txt requirements-optional.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
    && if [ "$INSTALL_OPTIONAL" = "true" ]; then pip install --no-cache-dir -r requirements-optional.txt; fi

# Copy app code
COPY . .

# Bake the runtime user into the image so it can be started directly with
# `docker run --user $PUID:$PGID` (how the NixOS module launches it) with no
# root entrypoint step. Create a matching `odysseus` user/group and chown the
# whole /app tree to it at build time — the app writes inside its own source
# tree at runtime (services/cache, *.json, *.log), which would otherwise be
# root-owned and crash a non-root run on the first mkdir.
#
# Defaults stay 1000:1000 for `docker compose` users on desktop distros (where
# 1000 is the login user); the NixOS module overrides them via --build-arg.
# When started as root (compose), entrypoint.sh still self-drops to PUID/PGID.
ARG PUID=1000
ARG PGID=1000
RUN mkdir -p data logs services/cache/search \
    && (getent group "$PGID" >/dev/null || groupadd -g "$PGID" odysseus) \
    && (getent passwd "$PUID" >/dev/null || useradd -u "$PUID" -g "$PGID" -M -s /bin/sh -d /app odysseus) \
    && chown -R "$PUID:$PGID" /app

# Entrypoint that, when started as root, drops to PUID/PGID and repairs
# ownership on the bind-mounted /app/data and /app/logs; when started as a
# non-root user (--user), it skips straight to running the app. Without the
# root path, a root-started container would write root-owned files into host
# bind mounts and break skill extraction, prefs persistence, mail attachments.
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 7000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "7000"]
