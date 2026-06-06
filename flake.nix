{
  description = "Odysseus — FastAPI assistant + chromadb/searxng/ntfy via NixOS oci-containers (Docker)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.services.odysseus;
        docker = config.virtualisation.docker.package;
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

          puid = lib.mkOption { type = lib.types.int; default = 1000; description = "UID the odysseus container drops to."; };
          pgid = lib.mkOption { type = lib.types.int; default = 1000; description = "GID the odysseus container drops to."; };

          httpPort = lib.mkOption {
            type = lib.types.port;
            default = 7000;
            description = "Host port published for the Odysseus web UI.";
          };
        };

        config = lib.mkIf cfg.enable {
          virtualisation.docker.enable = true;
          virtualisation.oci-containers.backend = "docker";

          # Persistent bind-mount dirs for the odysseus container. (searxng's
          # settings.yml template is mounted from the Nix store, not from here.)
          systemd.tmpfiles.rules = [
            "d ${cfg.basePath}                  0755 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/data             0755 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/logs             0755 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/data/ssh         0700 ${toString cfg.puid} ${toString cfg.pgid} - -"
            "d ${cfg.basePath}/data/huggingface 0755 ${toString cfg.puid} ${toString cfg.pgid} - -"
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
              ExecStart = "${docker}/bin/docker build -t ${cfg.imageTag} ${cfg.basePath}";
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
              networks = [ cfg.network ];
              ports = [ "8100:8000" ];
              environment.ANONYMIZED_TELEMETRY = "FALSE";
              volumes = [ "chromadb-data:/chroma/chroma" ];
            };

            searxng = {
              # Pinned, not :latest — upstream `latest`/2026.6.2 crashes on boot
              # with `KeyError: 'default_doi_resolver'` (issue #1414). Bump this
              # deliberately after verifying a newer tag boots clean. Mirrors
              # docker-compose.yml.
              image = "searxng/searxng:2026.5.31-7159b8aed";
              networks = [ cfg.network ];
              ports = [ "127.0.0.1:8080:8080" ];
              # Wrapper substitutes __SEARXNG_SECRET__ into the named-volume copy of
              # settings.yml on first boot (generating a secret when SEARXNG_SECRET
              # is unset), then hands off to the stock entrypoint. The repo template
              # is mounted read-only straight from the Nix store, so the bind source
              # always exists — a missing source would make Docker create it as a
              # directory and the container would fail to start with exit 125.
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
                    sed "s|__SEARXNG_SECRET__|$secret|g" /tmp/searxng-settings.yml.template > /etc/searxng/settings.yml
                  fi
                  exec /usr/local/searxng/entrypoint.sh
                ''
              ];
              environment.SEARXNG_BASE_URL = "http://localhost:8080/";
              volumes = [
                "searxng-data:/etc/searxng"
                "${./config/searxng/settings.yml}:/tmp/searxng-settings.yml.template:ro"
              ];
              # The image runs as the non-root `searxng` user, but its entrypoint
              # still needs to chown /etc/searxng on first boot, drop privs via
              # su-exec, and write settings.yml into the named volume. Without these
              # caps it aborts with EACCES. Mirrors upstream searxng-docker (issue #721).
              extraOptions = [
                "--cap-drop=ALL"
                "--cap-add=CHOWN"
                "--cap-add=SETGID"
                "--cap-add=SETUID"
                "--cap-add=DAC_OVERRIDE"
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
              networks = [ cfg.network ];
              ports = [ "8091:80" ];
              environment.NTFY_BASE_URL = "http://localhost:8091";
              volumes = [ "ntfy-cache:/var/cache/ntfy" ];
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
