{ config, lib, pkgs, ... }:

let
  cfg = config.services.openclawCliGateway;
  openclawCfg = config.services.openclaw;
  json = pkgs.formats.json {};

  stateDir = openclawCfg.stateDir or "/var/lib/openclaw";
  stateConfigDir = "${stateDir}/.openclaw";
  policyPath = cfg.policyFile;

  policyFile = json.generate "openclaw-cli-gateway-policy.json" {
    openclawBin = "${cfg.package}/bin/openclaw";
    env = cfg.env // {
      HOME = openclawCfg.home or "/var/lib/openclaw";
      OPENCLAW_CONFIG_PATH = "${stateConfigDir}/openclaw.json";
    };
    profiles = cfg.profiles;
    agentBindings = cfg.agentBindings;
  };

  clientScript = pkgs.writeShellApplication {
    name = cfg.clientCommandName;
    runtimeInputs = [ pkgs.jq pkgs.socat ];
    text = ''
      set -euo pipefail

      socket=${lib.escapeShellArg cfg.socketPath}
      agent_id="''${OPENCLAW_AGENT_ID:-main}"

      if [[ ! -S "$socket" ]]; then
        echo "gateway socket not found: $socket" >&2
        exit 1
      fi

      request=$(${pkgs.jq}/bin/jq -nc --arg agentId "$agent_id" --args -- "$@" '{agentId: $agentId, argv: $ARGS.positional}')
      printf '%s\n' "$request" | ${pkgs.socat}/bin/socat -T30 - UNIX-CONNECT:"$socket"
    '';
  };

  gatewayScript = pkgs.writeShellApplication {
    name = "openclaw-cli-gateway";
    runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.jq ];
    text = ''
      set -euo pipefail

      POLICY_PATH=${lib.escapeShellArg policyPath}

      die() {
        local msg="$1"
        printf '%s\n' "$(${pkgs.jq}/bin/jq -nc --arg error "$msg" '{ok:false, error:$error}')"
        exit 2
      }

      if [[ ! -r "$POLICY_PATH" ]]; then
        die "policy file not readable: $POLICY_PATH"
      fi

      if ! IFS= read -r request_json; then
        die "no request received"
      fi

      [[ -n "$request_json" ]] || die "empty request"

      mapfile -t policy_env < <(${pkgs.jq}/bin/jq -r '.env // {} | to_entries[] | @base64' "$POLICY_PATH")
      for entry in "''${policy_env[@]:-}"; do
        [[ -z "$entry" ]] && continue
        key=$(printf '%s' "$entry" | ${pkgs.coreutils}/bin/base64 -d | ${pkgs.jq}/bin/jq -r '.key')
        value=$(printf '%s' "$entry" | ${pkgs.coreutils}/bin/base64 -d | ${pkgs.jq}/bin/jq -r '.value')
        export "$key=$value"
      done

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _path: ''
        export ${name}="$(cat "$CREDENTIALS_DIRECTORY/${name}")"
      '') cfg.credentialEnv)}

      openclaw_bin=$(${pkgs.jq}/bin/jq -r '.openclawBin' "$POLICY_PATH")
      [[ -n "$openclaw_bin" && "$openclaw_bin" != "null" ]] || die "policy missing openclawBin"
      [[ -x "$openclaw_bin" ]] || die "openclaw binary not executable: $openclaw_bin"

      agent_id=$(printf '%s' "$request_json" | ${pkgs.jq}/bin/jq -r '.agentId // "main"')
      profile=$(${pkgs.jq}/bin/jq -r --arg agent "$agent_id" '.agentBindings[$agent] // empty' "$POLICY_PATH")
      [[ -n "$profile" ]] || die "no gateway policy bound for agent: $agent_id"

      mapfile -t argv < <(printf '%s' "$request_json" | ${pkgs.jq}/bin/jq -r '.argv[]?')
      mapfile -t allow_rules < <(${pkgs.jq}/bin/jq -c --arg profile "$profile" '.profiles[$profile].allowRules[]? // empty' "$POLICY_PATH")
      mapfile -t deny_rules < <(${pkgs.jq}/bin/jq -c --arg profile "$profile" '.profiles[$profile].denyRules[]? // empty' "$POLICY_PATH")

      args_json=$(printf '%s\0' "''${argv[@]}" | ${pkgs.jq}/bin/jq -Rsc 'split("\u0000")[:-1]')

      match_glob() {
        local value="$1"
        local pattern="$2"
        ${pkgs.bash}/bin/bash -O extglob -c 'case "$1" in $2) exit 0 ;; *) exit 1 ;; esac' _ "$value" "$pattern"
      }

      exact_matches() {
        local rule="$1"
        local rule_argv
        rule_argv=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -c '.argv')
        [[ "$rule_argv" == "$args_json" ]]
      }

      prefix_matches() {
        local rule="$1"
        shift
        local prefix_json prefix_len min_args max_args candidate_prefix
        prefix_json=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -c '.prefix')
        prefix_len=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.prefix | length')
        min_args=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.minArgs // (.prefix | length)')
        max_args=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.maxArgs // -1')

        if (( $# < min_args )); then return 1; fi
        if (( max_args >= 0 && $# > max_args )); then return 1; fi
        if (( $# < prefix_len )); then return 1; fi

        candidate_prefix=$(printf '%s\0' "''${@:1:prefix_len}" | ${pkgs.jq}/bin/jq -Rsc 'split("\u0000")[:-1]')
        [[ "$candidate_prefix" == "$prefix_json" ]]
      }

      prefix_arg_glob_matches() {
        local rule="$1"
        shift
        local prefix_json prefix_len min_args max_args candidate_prefix target_arg
        prefix_json=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -c '.prefix')
        prefix_len=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.prefix | length')
        min_args=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.minArgs // (.prefix | length + 1)')
        max_args=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.maxArgs // -1')

        if (( $# < min_args )); then return 1; fi
        if (( max_args >= 0 && $# > max_args )); then return 1; fi
        if (( $# < prefix_len )); then return 1; fi

        candidate_prefix=$(printf '%s\0' "''${@:1:prefix_len}" | ${pkgs.jq}/bin/jq -Rsc 'split("\u0000")[:-1]')
        if [[ "$candidate_prefix" != "$prefix_json" ]]; then return 1; fi

        target_arg=$(${pkgs.jq}/bin/jq -r --argjson argv "$args_json" '.argIndex as $i | $argv[$i] // empty' <<<"$rule")
        mapfile -t allowed_globs < <(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.allowed[]? // empty')
        for pattern in "''${allowed_globs[@]:-}"; do
          if match_glob "$target_arg" "$pattern"; then return 0; fi
        done

        die "argument outside allowlist: $target_arg"
      }

      help_matches() {
        local rule="$1"
        shift
        local allow_any allow_top_level max_depth
        allow_any=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.allowAnyCommand // false')
        allow_top_level=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.topLevel // false')
        max_depth=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.maxDepth // 64')

        if [[ "$#" -eq 1 && ( "$1" == "help" || "$1" == "--help" ) ]]; then return 0; fi
        if [[ "$#" -ge 2 && "$#" -le $max_depth ]]; then
          if [[ "''${!#}" == "--help" ]]; then
            if [[ "$allow_any" == "true" ]]; then return 0; fi
            if [[ "$#" -eq 2 && "$allow_top_level" == "true" ]]; then return 0; fi
          fi
        fi
        return 1
      }

      rule_matches() {
        local rule="$1"
        shift
        local rule_kind
        rule_kind=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.kind')

        case "$rule_kind" in
          exact) exact_matches "$rule" ;;
          prefix) prefix_matches "$rule" "$@" ;;
          prefixArgGlob) prefix_arg_glob_matches "$rule" "$@" ;;
          help) help_matches "$rule" "$@" ;;
          *) die "unknown rule kind in policy: $rule_kind" ;;
        esac
      }

      for rule in "''${deny_rules[@]:-}"; do
        [[ -z "$rule" ]] && continue
        if rule_matches "$rule" "''${argv[@]}"; then
          die "command denied by policy"
        fi
      done

      for rule in "''${allow_rules[@]:-}"; do
        [[ -z "$rule" ]] && continue
        if rule_matches "$rule" "''${argv[@]}"; then
          exec "$openclaw_bin" "''${argv[@]}"
        fi
      done

      die "command not permitted by policy"
    '';
  };
in
{
  options.services.openclawCliGateway = {
    enable = lib.mkEnableOption "a socket-activated OpenClaw CLI gateway";

    package = lib.mkOption {
      type = lib.types.package;
      description = "OpenClaw CLI package used by the gateway.";
    };

    agentUser = lib.mkOption {
      type = lib.types.str;
      default = "openclaw";
      description = "Agent-side user allowed to connect to the socket.";
    };

    gatewayUser = lib.mkOption {
      type = lib.types.str;
      default = "openclaw-gw";
      description = "System user that runs the gateway service.";
    };

    gatewayGroup = lib.mkOption {
      type = lib.types.str;
      default = "openclaw-gw";
      description = "Primary group for the gateway service.";
    };

    clientCommandName = lib.mkOption {
      type = lib.types.str;
      default = "openclaw-agent-cli";
      description = "Installed client command name for the agent-facing gateway entrypoint.";
    };

    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/openclaw-cli-gw/openclaw.sock";
      description = "Unix socket path for the OpenClaw CLI gateway.";
    };

    policyFile = lib.mkOption {
      type = lib.types.str;
      default = "${stateConfigDir}/agent-cli-policy.json";
      description = "Runtime path for the generated gateway policy file.";
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Additional non-secret environment variables exported by the gateway before invoking the CLI.";
    };

    credentialEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Credential-backed environment variables exported by the gateway from systemd credentials.";
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf json.type;
      default = {};
      description = "Named gateway policy profiles keyed by profile id.";
    };

    agentBindings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Map of agent id to gateway profile id.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.gatewayUser} = {
      isSystemUser = true;
      group = cfg.gatewayGroup;
      description = "OpenClaw CLI gateway user";
    };

    users.groups.${cfg.gatewayGroup} = {};

    system.activationScripts.openclaw-cli-gateway-policy = ''
      mkdir -p ${lib.escapeShellArg stateConfigDir}
      cp -f ${lib.escapeShellArg (toString policyFile)} ${lib.escapeShellArg policyPath}
      chown ${cfg.gatewayUser}:${cfg.gatewayGroup} ${lib.escapeShellArg policyPath}
      chmod 0640 ${lib.escapeShellArg policyPath}
    '';

    environment.systemPackages = [ clientScript ];

    systemd.sockets.openclaw-cli-gateway = {
      description = "OpenClaw CLI Gateway Socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = cfg.socketPath;
        SocketUser = cfg.gatewayUser;
        SocketGroup = cfg.agentUser;
        SocketMode = "0660";
        Accept = true;
        RemoveOnStop = true;
      };
    };

    systemd.services."openclaw-cli-gateway@" = {
      description = "OpenClaw CLI Gateway Instance";
      serviceConfig = {
        ExecStart = "${gatewayScript}/bin/openclaw-cli-gateway";
        User = cfg.gatewayUser;
        Group = cfg.gatewayGroup;
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        MemoryDenyWriteExecute = true;
        TimeoutStartSec = "30s";
        TimeoutStopSec = "5s";
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentialEnv;
      };
    };
  };
}
