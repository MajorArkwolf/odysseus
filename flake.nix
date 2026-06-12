{
  description = "Odysseus — FastAPI assistant + chromadb/searxng/ntfy via NixOS oci-containers (Docker)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.services.odysseus;
        docker = config.virtualisation.docker.package;
        # searxng's settings template, exposed as a Nix-store *directory* (not a
        # bare store file). Docker cannot prepare a bind-mount whose source is a
        # single file in the read-only /nix/store — the container fails to start
        # with exit 125. A store directory mounts cleanly, and writeTextDir keeps
        # the "source always exists, immutable" guarantee. Read at the same path
        # the cmd's sed expects: /tmp/searxng-template/settings.yml.
        searxngSettingsDir = pkgs.writeTextDir "settings.yml" (builtins.readFile ./config/searxng/settings.yml);
      in {
        options.services.odysseus = {
          enable = lib.mkEnableOption "Odysseus self-hosted assistant stack";

          basePath = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/odysseus";
            description = "Repo checkout (Dockerfile build context) + persistent data/logs/config + .env.";
          };

          envFile = lib.mkOption {
            type = lib.types.str;
            default = "${cfg.basePath}/.env";
            description = "Path to the .env file passed to the odysseus container (--env-file).";
          };

          imageTag = lib.mkOption {
            type = lib.types.str;
            default = "odysseus:local";
            description = "Local Docker image tag built from the repo Dockerfile.";
          };

          network = lib.mkOption {
            type = lib.types.str;
            default = "odysseus";
            description = "Shared user-defined Docker bridge network (DNS by container name).";
          };

          # Default to 982, NOT 1000. On a typical server 1000 is a real human
          # login user (often with sudo); running a container as that uid means
          # a container compromise can touch that user's files. 982 is a
          # dedicated, login-less system user created below.
          puid = lib.mkOption { type = lib.types.int; default = 982; description = "UID the odysseus container runs as."; };
          pgid = lib.mkOption { type = lib.types.int; default = 982; description = "GID the odysseus container runs as."; };

          # Each sidecar gets its own dedicated uid so the four containers are
          # isolated from each other's data, not just from the host.
          chromadbUid = lib.mkOption { type = lib.types.int; default = 981; description = "UID/GID the chromadb container runs as."; };
          ntfyUid = lib.mkOption { type = lib.types.int; default = 980; description = "UID/GID the ntfy container runs as."; };
          searxngUid = lib.mkOption { type = lib.types.int; default = 977; description = "UID/GID the searxng container runs as. Must match the in-image searxng user (977) so it can read /etc/searxng."; };

          httpPort = lib.mkOption {
            type = lib.types.port;
            default = 7000;
            description = "Host port published for the Odysseus web UI.";
          };
        };

        config = lib.mkIf cfg.enable {
          virtualisation.docker.enable = true;
          virtualisation.oci-containers.backend = "docker";

          # Dedicated, login-less system users — one per container — so each
          # runs non-root and is isolated from the others' data. Fixed,
          # symmetric uids (uid == gid). Groups share the same id as their user.
          users.groups.odysseus.gid = cfg.pgid;
          users.users.odysseus = {
            isSystemUser = true;
            group = "odysseus";
            description = "Odysseus assistant container user";
            home = cfg.basePath;
            uid = cfg.puid;
          };
          users.groups.chromadb.gid = cfg.chromadbUid;
          users.users.chromadb = {
            isSystemUser = true;
            group = "chromadb";
            description = "Odysseus chromadb container user";
            uid = cfg.chromadbUid;
          };
          users.groups.ntfy.gid = cfg.ntfyUid;
          users.users.ntfy = {
            isSystemUser = true;
            group = "ntfy";
            description = "Odysseus ntfy container user";
            uid = cfg.ntfyUid;
          };
          users.groups.searxng.gid = cfg.searxngUid;
          users.users.searxng = {
            isSystemUser = true;
            group = "searxng";
            description = "Odysseus searxng container user";
            uid = cfg.searxngUid;
          };

          # Persistent bind-mount dirs, each owned by the container that writes
          # it. The three sidecars (chromadb/ntfy/searxng) previously used Docker
          # *named* volumes; they're now host bind mounts under basePath so the
          # ownership is declarative here (and they're visible to host backups).
          # (searxng's settings.yml template is mounted from the Nix store, not
          # from here.)
          systemd.tmpfiles.rules = [
            "d ${cfg.basePath}                  0755 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/data             0755 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/logs             0755 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/data/ssh         0700 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/data/huggingface 0755 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/chromadb         0750 ${toString cfg.chromadbUid} ${toString cfg.chromadbUid} - -"
            "d ${cfg.basePath}/ntfy             0750 ${toString cfg.ntfyUid} ${toString cfg.ntfyUid} - -"
            "d ${cfg.basePath}/searxng          0750 ${toString cfg.searxngUid} ${toString cfg.searxngUid} - -"
          ];

          # Build/refresh odysseus:local from the local Dockerfile (layer-cached, fast after first).
          systemd.services.odysseus-image = {
            description = "Build odysseus Docker image from ${cfg.basePath}/Dockerfile";
            after = [ "docker.service" "network-online.target" ];
            requires = [ "docker.service" ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              # Bake the target uid/gid into the image: the Dockerfile creates a
              # matching `odysseus` user and chowns /app to it at build time, so
              # the container can be started directly with `--user` (no root
              # entrypoint needed). Changing these build-args also makes this
              # ExecStart differ on a uid change, forcing a rebuild at switch.
              ExecStart = "${docker}/bin/docker build -t ${cfg.imageTag} --build-arg PUID=${toString cfg.puid} --build-arg PGID=${toString cfg.pgid} ${cfg.basePath}";
            };
          };

          # Create the shared bridge network.
          systemd.services.odysseus-network = {
            description = "Create odysseus Docker network";
            after = [ "docker.service" ];
            requires = [ "docker.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "odysseus-network" ''
                ${docker}/bin/docker network inspect ${cfg.network} >/dev/null 2>&1 \
                  || ${docker}/bin/docker network create ${cfg.network}
              '';
            };
          };

          virtualisation.oci-containers.containers = {
            odysseus = {
              image = cfg.imageTag;
              pull = "never";                       # built locally; never hit a registry
              # Run as the dedicated odysseus uid. The image is built with a
              # matching user owning /app, and the bind mounts are pre-owned via
              # tmpfiles, so the entrypoint takes its non-root path (no useradd /
              # chown / gosu — see docker/entrypoint.sh).
              user = "${toString cfg.puid}:${toString cfg.pgid}";
              cmd = [ "uvicorn" "app:app" "--host" "0.0.0.0" "--port" "7000" ];
              networks = [ cfg.network ];
              dependsOn = [ "searxng" "chromadb" ];
              ports = [ "${toString cfg.httpPort}:7000" ];
              environmentFiles = [ cfg.envFile ];
              environment = {                        # overrides .env, matching compose
                SEARXNG_INSTANCE = "http://searxng:8080";
                CHROMADB_HOST = "chromadb";
                CHROMADB_PORT = "8000";
                PUID = toString cfg.puid;
                PGID = toString cfg.pgid;
              };
              volumes = [
                "${cfg.basePath}/data:/app/data"
                "${cfg.basePath}/logs:/app/logs"
                "${cfg.basePath}/data/ssh:/app/.ssh"
                "${cfg.basePath}/data/huggingface:/app/.cache/huggingface"
              ];
            };

            chromadb = {
              image = "chromadb/chroma:latest";
              # Run as the dedicated chromadb uid against a host bind mount whose
              # ownership is set by tmpfiles above (replacing the old named
              # volume `chromadb-data`).
              #
              # Mount at /data, NOT /chroma/chroma: the current (Rust) chroma
              # image persists to /data (it logs `persist_path: /data`). The old
              # /chroma/chroma mount was silently unused — chroma wrote to the
              # in-image /data instead, so nothing actually persisted across
              # container recreates. With --user that root-owned /data is no
              # longer writable, so we mount our 981-owned dir there directly.
              user = "${toString cfg.chromadbUid}:${toString cfg.chromadbUid}";
              networks = [ cfg.network ];
              ports = [ "8100:8000" ];
              environment.ANONYMIZED_TELEMETRY = "FALSE";
              volumes = [ "${cfg.basePath}/chromadb:/data" ];
            };

            searxng = {
              # Pinned, not :latest — upstream `latest`/2026.6.2 crashes on boot
              # with `KeyError: 'default_doi_resolver'` (issue #1414). Bump this
              # deliberately after verifying a newer tag boots clean. Mirrors
              # docker-compose.yml.
              image = "searxng/searxng:2026.5.31-7159b8aed";
              # Run directly as the in-image searxng user (977) against a host
              # bind mount owned by 977 (tmpfiles above). Because the volume is
              # already correctly owned, the entrypoint no longer needs to chown
              # /etc/searxng or su-exec down from root, so the CHOWN/SET*ID/
              # DAC_OVERRIDE caps below are dropped (only --cap-drop=ALL remains).
              user = "${toString cfg.searxngUid}:${toString cfg.searxngUid}";
              networks = [ cfg.network ];
              ports = [ "127.0.0.1:8080:8080" ];
              # Wrapper substitutes __SEARXNG_SECRET__ into the named-volume copy of
              # settings.yml on first boot (generating a secret when SEARXNG_SECRET
              # is unset), then hands off to the stock entrypoint. The repo template
              # is mounted read-only as a Nix-store directory (see searxngSettingsDir):
              # mounting it as a single store file makes Docker fail to start the
              # container (exit 125), since it can't prepare a file bind source on
              # the read-only store.
              entrypoint = "/bin/sh";
              cmd = [
                "-c"
                ''
                  set -eu
                  if [ ! -s /etc/searxng/settings.yml ] || grep -q 'odysseus-local-searxng-json-2026-05-30\|__SEARXNG_SECRET__' /etc/searxng/settings.yml; then
                    secret="''${SEARXNG_SECRET:-}"
                    if [ -z "$secret" ]; then
                      secret="$(python -c 'import secrets; print(secrets.token_urlsafe(48))')"
                    fi
                    sed "s|__SEARXNG_SECRET__|$secret|g" /tmp/searxng-template/settings.yml > /etc/searxng/settings.yml
                  fi
                  exec /usr/local/searxng/entrypoint.sh
                ''
              ];
              environment.SEARXNG_BASE_URL = "http://localhost:8080/";
              volumes = [
                "${cfg.basePath}/searxng:/etc/searxng"
                "${searxngSettingsDir}:/tmp/searxng-template:ro"
              ];
              # Started directly as uid 977 against a pre-owned /etc/searxng bind
              # mount, so the entrypoint's first-boot chown / su-exec path is a
              # no-op and the CHOWN/SETGID/SETUID/DAC_OVERRIDE caps are no longer
              # needed. The sh wrapper writes settings.yml as 977 into the
              # 977-owned dir. If a future image regresses to needing the root
              # chown path, restore those four caps and drop the `user =` line.
              extraOptions = [
                "--cap-drop=ALL"
                "--health-cmd=python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8080/', timeout=5).read(1)\""
                "--health-interval=5s"
                "--health-timeout=6s"
                "--health-retries=20"
                "--health-start-period=10s"
              ];
            };

            ntfy = {
              image = "binwiederhier/ntfy";
              cmd = [ "serve" ];
              # Run as the dedicated ntfy uid. The image's default listen port
              # is 80 (privileged — a non-root process can't bind it), so move
              # it to 8091 via NTFY_LISTEN_HTTP and publish 1:1. The odysseus app
              # reaches ntfy through the host-port base_url, not container DNS,
              # so the internal port change is transparent to it.
              user = "${toString cfg.ntfyUid}:${toString cfg.ntfyUid}";
              networks = [ cfg.network ];
              ports = [ "8091:8091" ];
              environment = {
                NTFY_BASE_URL = "http://localhost:8091";
                NTFY_LISTEN_HTTP = ":8091";
              };
              volumes = [ "${cfg.basePath}/ntfy:/var/cache/ntfy" ];
            };
          };

          # Order generated container units after the network + image build.
          systemd.services.docker-odysseus = {
            after = [ "odysseus-image.service" "odysseus-network.service" ];
            requires = [ "odysseus-image.service" "odysseus-network.service" ];
          };
          systemd.services.docker-chromadb = { after = [ "odysseus-network.service" ]; requires = [ "odysseus-network.service" ]; };
          systemd.services.docker-searxng  = { after = [ "odysseus-network.service" ]; requires = [ "odysseus-network.service" ]; };
          systemd.services.docker-ntfy     = { after = [ "odysseus-network.service" ]; requires = [ "odysseus-network.service" ]; };
        };
      };
  };
}
