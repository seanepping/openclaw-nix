{ lib, pkgs }:

pkgs.writeShellApplication {
  name = "openclaw-agent-cli";
  runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.jq ];
  text = ''
    set -euo pipefail

    POLICY_PATH="''${OPENCLAW_AGENT_CLI_POLICY_PATH:?OPENCLAW_AGENT_CLI_POLICY_PATH must be set}"

    die() {
      echo "$*" >&2
      exit 2
    }

    if [[ ! -r "$POLICY_PATH" ]]; then
      die "policy file not readable: $POLICY_PATH"
    fi

    mapfile -t policy_env < <(${pkgs.jq}/bin/jq -r '
      .env // {} | to_entries[] | @base64
    ' "$POLICY_PATH")

    for entry in "''${policy_env[@]:-}"; do
      [[ -z "$entry" ]] && continue
      key=$(printf '%s' "$entry" | ${pkgs.coreutils}/bin/base64 -d | ${pkgs.jq}/bin/jq -r '.key')
      value=$(printf '%s' "$entry" | ${pkgs.coreutils}/bin/base64 -d | ${pkgs.jq}/bin/jq -r '.value')
      export "$key=$value"
    done

    openclaw_bin=$(${pkgs.jq}/bin/jq -r '.openclawBin' "$POLICY_PATH")
    [[ -n "$openclaw_bin" && "$openclaw_bin" != "null" ]] || die "policy missing openclawBin"
    [[ -x "$openclaw_bin" ]] || die "openclaw binary not executable: $openclaw_bin"

    agent_id="''${OPENCLAW_AGENT_ID:-main}"
    profile=$(${pkgs.jq}/bin/jq -r --arg agent "$agent_id" '.agentBindings[$agent] // empty' "$POLICY_PATH")
    [[ -n "$profile" ]] || die "no wrapper policy bound for agent: $agent_id"

    mapfile -t allowed_exact < <(${pkgs.jq}/bin/jq -c --arg profile "$profile" '.profiles[$profile].commands.exact[]? // empty' "$POLICY_PATH")
    mapfile -t config_globs < <(${pkgs.jq}/bin/jq -r --arg profile "$profile" '.profiles[$profile].commands.configGet.allowedPaths[]? // empty' "$POLICY_PATH")

    args_json=$(printf '%s\n' "$@" | ${pkgs.jq}/bin/jq -R . | ${pkgs.jq}/bin/jq -s .)

    for candidate in "''${allowed_exact[@]:-}"; do
      if [[ "$candidate" == "$args_json" ]]; then
        exec "$openclaw_bin" "$@"
      fi
    done

    if [[ "$#" -eq 3 && "$1" == "config" && "$2" == "get" ]]; then
      path="$3"
      for pattern in "''${config_globs[@]:-}"; do
        case "$path" in
          $pattern)
            exec "$openclaw_bin" "$@"
            ;;
        esac
      done
      die "config path outside allowlist: $path"
    fi

    die "command not permitted by policy"
  '';
}
