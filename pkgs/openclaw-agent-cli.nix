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

    mapfile -t profile_rules < <(${pkgs.jq}/bin/jq -c --arg profile "$profile" '.profiles[$profile].rules[]? // empty' "$POLICY_PATH")

    args_json=$(printf '%s\0' "$@" | ${pkgs.jq}/bin/jq -Rsc 'split("\u0000")[:-1]')

    match_glob() {
      local value="$1"
      local pattern="$2"
      ${pkgs.bash}/bin/bash -O extglob -c 'case "$1" in $2) exit 0 ;; *) exit 1 ;; esac' _ "$value" "$pattern"
    }

    for rule in "''${profile_rules[@]:-}"; do
      [[ -z "$rule" ]] && continue

      rule_kind=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.kind')

      case "$rule_kind" in
        exact)
          rule_argv=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -c '.argv')
          if [[ "$rule_argv" == "$args_json" ]]; then
            exec "$openclaw_bin" "$@"
          fi
          ;;

        prefixArgGlob)
          prefix_json=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -c '.prefix')
          prefix_len=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.prefix | length')

          if [[ "$#" -eq $((prefix_len + 1)) ]]; then
            candidate_prefix=$(printf '%s\0' "''${@:1:prefix_len}" | ${pkgs.jq}/bin/jq -Rsc 'split("\u0000")[:-1]')
            if [[ "$candidate_prefix" == "$prefix_json" ]]; then
              target_arg=$(${pkgs.jq}/bin/jq -r --argjson argv "$args_json" '.argIndex as $i | $argv[$i] // empty' <<<"$rule")
              mapfile -t allowed_globs < <(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.allowed[]? // empty')
              for pattern in "''${allowed_globs[@]:-}"; do
                if match_glob "$target_arg" "$pattern"; then
                  exec "$openclaw_bin" "$@"
                fi
              done
              die "argument outside allowlist: $target_arg"
            fi
          fi
          ;;

        help)
          allow_top_level=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.topLevel // false')
          mapfile -t help_subcommands < <(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.subcommands[]? // empty')

          if [[ "$#" -eq 1 && ( "$1" == "help" || "$1" == "--help" ) ]]; then
            exec "$openclaw_bin" "$@"
          fi

          if [[ "$#" -eq 2 && "$2" == "--help" && "$allow_top_level" == "true" ]]; then
            exec "$openclaw_bin" "$@"
          fi

          if [[ "$#" -eq 3 && "$3" == "--help" ]]; then
            for subcommand in "''${help_subcommands[@]:-}"; do
              if [[ "$1" == "$subcommand" ]]; then
                exec "$openclaw_bin" "$@"
              fi
            done
          fi
          ;;

        *)
          die "unknown rule kind in policy: $rule_kind"
          ;;
      esac
    done

    die "command not permitted by policy"
  '';
}
