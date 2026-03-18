{ lib, pkgs }:

pkgs.writeShellApplication {
  name = "openclaw-agent-cli";
  runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.jq ];
  text = ''
    set -euo pipefail

    POLICY_PATH="''${OPENCLAW_AGENT_CLI_POLICY_PATH:-/etc/openclaw/agent-cli-policy.json}"

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

    mapfile -t allowed_exact < <(${pkgs.jq}/bin/jq -c '.commands.exact[]? // empty' "$POLICY_PATH")
    mapfile -t config_globs < <(${pkgs.jq}/bin/jq -r '.commands.configGet.allowedPaths[]? // empty' "$POLICY_PATH")

    args_json=$(printf '%s\n' "$@" | ${pkgs.jq}/bin/jq -R . | ${pkgs.jq}/bin/jq -s .)

    for candidate in "''${allowed_exact[@]:-}"; do
      if [[ "$candidate" == "$args_json" ]]; then
        exec "$openclaw_bin" "$@"
      fi
    done

    if [[ "$#" -eq 3 && "$1" == "config" && "$2" == "get" ]]; then
      path="$3"
      for pattern in "''${config_globs[@]:-}"; do
        if [[ "$path" == $pattern ]]; then
          exec "$openclaw_bin" "$@"
        fi
      done
      die "config path outside allowlist: $path"
    fi

    die "command not permitted by policy"
  '';
}
