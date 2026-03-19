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

    mapfile -t allow_rules < <(${pkgs.jq}/bin/jq -c --arg profile "$profile" '.profiles[$profile].allowRules[]? // empty' "$POLICY_PATH")
    mapfile -t deny_rules < <(${pkgs.jq}/bin/jq -c --arg profile "$profile" '.profiles[$profile].denyRules[]? // empty' "$POLICY_PATH")

    args_json=$(printf '%s\0' "$@" | ${pkgs.jq}/bin/jq -Rsc 'split("\u0000")[:-1]')

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
      local prefix_json prefix_len min_args max_args candidate_prefix
      prefix_json=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -c '.prefix')
      prefix_len=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.prefix | length')
      min_args=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.minArgs // (.prefix | length)')
      max_args=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.maxArgs // -1')

      if (( $# < min_args )); then
        return 1
      fi

      if (( max_args >= 0 && $# > max_args )); then
        return 1
      fi

      if (( $# < prefix_len )); then
        return 1
      fi

      candidate_prefix=$(printf '%s\0' "''${@:1:prefix_len}" | ${pkgs.jq}/bin/jq -Rsc 'split("\u0000")[:-1]')
      [[ "$candidate_prefix" == "$prefix_json" ]]
    }

    prefix_arg_glob_matches() {
      local rule="$1"
      local prefix_json prefix_len min_args max_args candidate_prefix target_arg
      prefix_json=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -c '.prefix')
      prefix_len=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.prefix | length')
      min_args=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.minArgs // (.prefix | length + 1)')
      max_args=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.maxArgs // -1')

      if (( $# < min_args )); then
        return 1
      fi

      if (( max_args >= 0 && $# > max_args )); then
        return 1
      fi

      if (( $# < prefix_len )); then
        return 1
      fi

      candidate_prefix=$(printf '%s\0' "''${@:1:prefix_len}" | ${pkgs.jq}/bin/jq -Rsc 'split("\u0000")[:-1]')
      if [[ "$candidate_prefix" != "$prefix_json" ]]; then
        return 1
      fi

      target_arg=$(${pkgs.jq}/bin/jq -r --argjson argv "$args_json" '.argIndex as $i | $argv[$i] // empty' <<<"$rule")
      mapfile -t allowed_globs < <(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.allowed[]? // empty')
      for pattern in "''${allowed_globs[@]:-}"; do
        if match_glob "$target_arg" "$pattern"; then
          return 0
        fi
      done

      die "argument outside allowlist: $target_arg"
    }

    help_matches() {
      local rule="$1"
      local allow_any allow_top_level max_depth
      allow_any=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.allowAnyCommand // false')
      allow_top_level=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.topLevel // false')
      max_depth=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.maxDepth // 64')

      if [[ "$#" -eq 1 && ( "$1" == "help" || "$1" == "--help" ) ]]; then
        return 0
      fi

      if [[ "$#" -ge 2 && "$#" -le $max_depth ]]; then
        if [[ "''${!#}" == "--help" ]]; then
          if [[ "$allow_any" == "true" ]]; then
            return 0
          fi
          if [[ "$#" -eq 2 && "$allow_top_level" == "true" ]]; then
            return 0
          fi
        fi
      fi

      return 1
    }

    rule_matches() {
      local rule="$1"
      local rule_kind
      rule_kind=$(printf '%s' "$rule" | ${pkgs.jq}/bin/jq -r '.kind')

      case "$rule_kind" in
        exact)
          exact_matches "$rule"
          ;;
        prefix)
          prefix_matches "$rule" "$@"
          ;;
        prefixArgGlob)
          prefix_arg_glob_matches "$rule" "$@"
          ;;
        help)
          help_matches "$rule" "$@"
          ;;
        *)
          die "unknown rule kind in policy: $rule_kind"
          ;;
      esac
    }

    for rule in "''${deny_rules[@]:-}"; do
      [[ -z "$rule" ]] && continue
      if rule_matches "$rule" "$@"; then
        die "command denied by policy"
      fi
    done

    for rule in "''${allow_rules[@]:-}"; do
      [[ -z "$rule" ]] && continue
      if rule_matches "$rule" "$@"; then
        exec "$openclaw_bin" "$@"
      fi
    done

    die "command not permitted by policy"
  '';
}
