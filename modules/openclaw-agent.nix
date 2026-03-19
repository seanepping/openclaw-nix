{ config, lib, pkgs, ... }:

let
  cfg = config.services.openclaw;
  wrapperCfg = cfg.agentCliWrapper;

  json = pkgs.formats.json {};

  # Non-secret base config. Secrets should be injected via systemd credentials/env.
  # When settings are empty, we don't generate/force a JSON file.
  openclawConfigFile = json.generate "openclaw.json" cfg.settings;

  # The upstream OpenClaw package to run. You can override this in host config.
  openclawPkg = cfg.package;

  stateDir = cfg.stateDir;
  stateConfigDir = "${stateDir}/.openclaw";
  runtimeConfigPath = "${stateConfigDir}/openclaw.json";
  wrapperPolicyPath = wrapperCfg.policyFile;

  wrapperPolicyFormat = pkgs.formats.json {};
  wrapperPackage = pkgs.callPackage ../pkgs/openclaw-agent-cli.nix {};

  wrapperPolicy = wrapperPolicyFormat.generate "openclaw-agent-cli-policy.json" {
    openclawBin = "${openclawPkg}/bin/openclaw";
    env = wrapperCfg.env // {
      OPENCLAW_CONFIG_PATH = runtimeConfigPath;
      HOME = cfg.home;
    };
    profiles = wrapperCfg.profiles;
    agentBindings = wrapperCfg.agentBindings;
  };

  enabledWrapper = wrapperCfg.enable && openclawPkg != null;

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

    home = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/openclaw";
      description = "Home directory for the OpenClaw service user.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/openclaw";
      description = "Base state directory for OpenClaw runtime files.";
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

    agentCliWrapper = {
      enable = lib.mkEnableOption "a policy-enforcing OpenClaw CLI helper for agents";

      packageName = lib.mkOption {
        type = lib.types.str;
        default = "openclaw-agent-cli";
        description = "Installed command name for the wrapper helper.";
      };

      policyFile = lib.mkOption {
        type = lib.types.str;
        default = "${stateConfigDir}/agent-cli-policy.json";
        description = "Runtime path for the generated wrapper policy file.";
      };

      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Additional non-secret environment variables exported by the wrapper.";
      };

      credentialEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "Credential-backed environment variables exported by the wrapper command at runtime.";
      };

      profiles = lib.mkOption {
        type = lib.types.attrsOf json.type;
        default = {};
        example = {
          readonly = {
            commands = {
              exact = [
                [ "status" "--deep" ]
                [ "logs" "--follow" ]
              ];
              configGet.allowedPaths = [ "gateway" "gateway.*" ];
              help = {
                topLevel = true;
                subcommands = [ "status" "logs" "agents" "config" ];
              };
            };
          };
        };
        description = "Named wrapper policy profiles keyed by profile id.";
      };

      agentBindings = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = {
          main = "readonly";
        };
        description = "Map of OpenClaw agent id to wrapper profile id.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.home;
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
          "HOME=${cfg.home}"
          # If you want OpenClaw's CLI/wizard to mutate config, point this at a writable file.
          "OPENCLAW_CONFIG_PATH=${runtimeConfigPath}"
        ];

        # Preferred: pass secrets via systemd credentials then map into env.
        # NixOS exposes this as LoadCredential=NAME:PATH.
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentials;

        ExecStart = lib.mkIf (cfg.credentials == {}) "${openclawPkg}/bin/openclaw gateway";

        # Seed config on first boot (or if missing). After seeding, the CLI is free to mutate it.
        ExecStartPre = pkgs.writeShellScript "openclaw-seed-config" ''
          set -euo pipefail

          cfg_dir="${stateConfigDir}"
          cfg_path="${runtimeConfigPath}"
          if [ -e "$cfg_path" ]; then
            exit 0
          fi

          mkdir -p "$cfg_dir"

          if [ -e "${openclawConfigFile}" ] && [ "${if cfg.settings != {} then "1" else "0"}" = "1" ]; then
            # If Nix settings are provided, seed from the generated JSON.
            cp -f "${openclawConfigFile}" "$cfg_path"
          else
            # Otherwise, seed a minimal stub so `openclaw config` has a file to edit.
            printf '{\n}\n' > "$cfg_path"
          fi

          chmod 0600 "$cfg_path"
          chown ${cfg.user}:${cfg.group} "$cfg_path"
        '';
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

    environment.etc = lib.mkIf (cfg.settings != {}) {
      "openclaw/openclaw.json" = {
        source = openclawConfigFile;
      };
    };

    environment.systemPackages = lib.mkIf enabledWrapper [
      (pkgs.writeShellScriptBin wrapperCfg.packageName ''
        set -euo pipefail
        export OPENCLAW_AGENT_CLI_POLICY_PATH="${wrapperPolicyPath}"

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: path: ''
          export ${name}="$(cat ${lib.escapeShellArg (toString path)})"
        '') wrapperCfg.credentialEnv)}

        exec ${wrapperPackage}/bin/openclaw-agent-cli "$@"
      '')
    ];

    # Also place the config at the runtime path expected by the service.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateConfigDir} 0750 ${cfg.user} ${cfg.group} - -"
    ] ++ lib.optionals (cfg.settings != {}) [
      "L+ ${stateDir}/openclaw.json - - - - /etc/openclaw/openclaw.json"
    ] ++ lib.optionals enabledWrapper [
      "C ${wrapperPolicyPath} 0640 ${cfg.user} ${cfg.group} - ${wrapperPolicy}"
    ];
  };
}
