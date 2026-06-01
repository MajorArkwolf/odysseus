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

          # Bind-mount dirs (searxng settings.yml comes from the repo checkout).
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
              image = "searxng/searxng:latest";
              networks = [ cfg.network ];
              ports = [ "127.0.0.1:8080:8080" ];
              environment.SEARXNG_BASE_URL = "http://localhost:8080/";
              volumes = [
                "searxng-data:/etc/searxng"
                "${cfg.basePath}/config/searxng/settings.yml:/etc/searxng/settings.yml"
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
