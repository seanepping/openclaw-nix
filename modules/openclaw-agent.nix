{ config, lib, pkgs, ... }:

let
  cfg = config.services.openclaw;

  json = pkgs.formats.json {};

  # Non-secret base config. Secrets should be injected via systemd credentials/env.
  openclawConfigFile = json.generate "openclaw.json" cfg.settings;

  # The upstream OpenClaw package to run. You can override this in host config.
  openclawPkg = cfg.package;

  # Convenience: a stable state dir.
  stateDir = "/var/lib/openclaw";

in
{
  options.services.openclaw = {
    enable = lib.mkEnableOption "OpenClaw gateway/agent";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.openclaw-gateway or null;
      description = "OpenClaw gateway package (from nixpkgs or an overlay).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "openclaw";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "openclaw";
    };

    # This becomes the content of openclaw.json. Keep secrets out.
    settings = lib.mkOption {
      type = json.type;
      default = {};
    };

    # Map of env vars to load from systemd credentials files.
    # We keep this generic because OpenClaw's config supports providers/channels
    # and you may choose different secret injection patterns.
    credentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      example = {
        # "MISSION_CONTROL_API_KEY" = config.age.secrets.openclaw-mission-control.path;
      };
      description = "Env var -> file path. Files must contain the secret value.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = stateDir;
      createHome = true;
    };

    users.groups.${cfg.group} = {};

    systemd.services.openclaw-agent = {
      description = "OpenClaw Agent Gateway";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = stateDir;

        # Keep state writable but avoid exposing user homes.
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        Restart = "always";

        # OpenClaw runtime expects HOME.
        Environment = [
          "HOME=${stateDir}"
          "OPENCLAW_CONFIG_PATH=${stateDir}/openclaw.json"
        ];

        # Preferred: pass secrets via systemd credentials then map into env.
        # NixOS exposes this as LoadCredential=NAME:PATH.
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentials;

        ExecStart = lib.mkIf (cfg.credentials == {}) "${openclawPkg}/bin/openclaw gateway";
      };

      # Convert loaded credentials into env vars without copying them into the nix store.
      # systemd mounts credentials at $CREDENTIALS_DIRECTORY/<name>
      # When we use `script`, systemd will generate an ExecStart wrapper for it, so we must
      # not also set a conflicting ExecStart.
      script = lib.mkIf (cfg.credentials != {}) ''
        set -euo pipefail
        export CREDENTIALS_DIRECTORY="${"$"}CREDENTIALS_DIRECTORY"

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _path: ''
          export ${name}="$(cat "${"$"}CREDENTIALS_DIRECTORY/${name}")"
        '') cfg.credentials)}

        exec ${openclawPkg}/bin/openclaw gateway
      '';
    };

    environment.etc."openclaw/openclaw.json".source = openclawConfigFile;

    # Also place the config at the runtime path expected by the service.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 ${cfg.user} ${cfg.group} - -"
      "L+ ${stateDir}/openclaw.json - - - - /etc/openclaw/openclaw.json"
    ];
  };
}
