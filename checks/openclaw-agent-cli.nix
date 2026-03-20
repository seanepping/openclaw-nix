{ pkgs }:

pkgs.runCommand "openclaw-agent-cli-check" {
  buildInputs = [ pkgs.bash pkgs.jq pkgs.coreutils ];
} ''
  set -euo pipefail

  fake_openclaw="$PWD/fake-openclaw"
  cat > "$fake_openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'OPENCLAW %s\n' "$*"
EOF
  sed -i "1s|/usr/bin/env bash|${pkgs.bash}/bin/bash|" "$fake_openclaw"
  chmod +x "$fake_openclaw"

  policy="$PWD/policy.json"
  cat > "$policy" <<EOF
{
  "openclawBin": "$fake_openclaw",
  "env": {},
  "profiles": {
    "readonly": {
      "allowRules": [
        { "kind": "exact", "argv": ["status", "--deep"] },
        { "kind": "prefix", "prefix": ["docs"] },
        { "kind": "prefixArgGlob", "prefix": ["config", "get"], "argIndex": 2, "allowed": ["gateway", "gateway.*"] },
        { "kind": "help", "allowAnyCommand": true }
      ],
      "denyRules": [
        { "kind": "prefix", "prefix": ["config", "set"] }
      ]
    }
  },
  "agentBindings": {
    "main": "readonly"
  }
}
EOF

  export OPENCLAW_AGENT_CLI_POLICY_PATH="$policy"

  wrapper=${pkgs.callPackage ../pkgs/openclaw-agent-cli.nix {}}/bin/openclaw-agent-cli

  "$wrapper" status --deep | tee status.out
  grep -F 'OPENCLAW status --deep' status.out

  "$wrapper" docs cron | tee docs.out
  grep -F 'OPENCLAW docs cron' docs.out

  "$wrapper" config get gateway | tee config.out
  grep -F 'OPENCLAW config get gateway' config.out

  if "$wrapper" config set gateway.port 9999 >deny.out 2>&1; then
    echo "expected deny rule to fail" >&2
    exit 1
  fi
  grep -F 'command denied by policy' deny.out

  touch "$out"
''
