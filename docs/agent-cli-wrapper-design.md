# Agent CLI Wrapper Design

Date: 2026-03-18

## Goal

Provide a reusable, Nix-managed way to expose a narrow OpenClaw CLI surface to agents without allowlisting the raw `openclaw` binary.

This belongs in `openclaw-nix` because it is packaging and module machinery, not fleet-specific policy.

## Scope

This document describes the wrapper shape and why it exists. It is not a task tracker.

## Design Split

### `openclaw-nix` owns

- module options for enabling an agent-facing wrapper
- generation/installation of the wrapper executable
- generation/installation of a policy file the wrapper reads
- stable runtime paths for the wrapper and policy
- integration points for host exec-approval configuration
- reusable docs and examples

### Package consumer configuration owns

- whether the wrapper is enabled for a given deployment
- which shared policy profiles exist
- which agent ids bind to which policy profiles
- exact allowlisted OpenClaw subcommands and argument constraints for those profiles
- whether a deployment uses readonly-only or adds an ops/write profile

## Why Not Allowlist Raw `openclaw`

OpenClaw native exec approvals and allowlists are executable-path based. They are useful as an outer gate, but they do not give us enough argument-level control for a large multi-command CLI.

Allowlisting the raw `openclaw` binary broadly would trust too much surface area.

The safer model is:

1. native OpenClaw exec approvals gate host execution
2. only the dedicated wrapper executable is allowlisted for the agent
3. the wrapper enforces subcommand, flag, and path policy from a Nix-generated policy file

## Runtime Constraints

Two runtime constraints shape this design:

- the wrapper cannot assume direct read access to raw secret files
- the wrapper cannot assume the OpenClaw executable is available at a globally linked path

That means the wrapper should:

- source the OpenClaw binary path from Nix
- avoid direct reads from raw secret paths
- use deployment-managed runtime env and credential wiring

## Interaction With OpenClaw Native Controls

We should treat these as complementary layers:

- **Exec approvals / per-agent allowlists:** outer gate on whether an executable may run at all
- **`tools.exec.safeBins`:** useful for stdin-only utilities, not for `openclaw`
- **Wrapper policy file:** inner gate on which `openclaw` actions are permitted

## Exec Approvals Boundary

- `exec-approvals.json` remains OpenClaw-owned, not Nix-owned
- the wrapper policy may still be Nix-generated and deployment-managed
- raw `openclaw` stays off the agent's exec approval allowlist
- only the dedicated wrapper path should be allowlisted for the relevant agent ids

## Proposed Runtime Shape

### Executable path

The wrapper itself should be installed by Nix and exposed on the host as a normal command, for example:

- `/run/current-system/sw/bin/openclaw-agent-cli`

But the wrapped OpenClaw executable path must come from Nix-rendered configuration, not from assumptions about where the runtime package is linked on a given host. The readonly test showed that the real OpenClaw binary may live only at a store path.

### Policy path

Install a generated policy file alongside OpenClaw state, under the runtime state directory managed by the package consumer.

Example path:

- `<openclaw-state-dir>/agent-cli-policy.json`

The wrapper reads this file at runtime. This keeps the policy near the rest of the OpenClaw runtime state while still allowing Nix to manage the file contents and ownership.

### Execution model

The wrapper should:

- set explicit `PATH` and other required env
- set `HOME` and `OPENCLAW_CONFIG_PATH` explicitly
- inject only the runtime env needed for the allowed commands
- validate argv against the generated policy
- exec the real OpenClaw binary only after policy acceptance

## Proposed Policy Shape

First cut JSON shape:

```json
{
  "openclawBin": "/nix/store/.../bin/openclaw",
  "env": {
    "HOME": "<openclaw-home>",
    "OPENCLAW_CONFIG_PATH": "<openclaw-state-dir>/openclaw.json"
  },
  "profiles": {
    "readonly": {
      "commands": {
        "exact": [
          ["status", "--deep"],
          ["logs", "--follow"],
          ["agents", "list", "--bindings"]
        ],
        "configGet": {
          "allowedPaths": [
            "gateway",
            "gateway.*",
            "agents",
            "agents.*",
            "channels",
            "channels.*",
            "models",
            "models.*",
            "skills",
            "skills.*"
          ]
        }
      }
    }
  },
  "agentBindings": {
    "main": "readonly"
  }
}
```

This keeps the first pass narrow, readable, and audit-friendly.

## Proposed Module Surface

Possible option shape:

```nix
services.openclaw.agentCliWrapper = {
  enable = true;

  packageName = "openclaw-agent-cli";
  policyFile = "${config.services.openclaw.stateDir}/.openclaw/agent-cli-policy.json";

  env = {
    HOME = config.services.openclaw.home;
    OPENCLAW_CONFIG_PATH = "${config.services.openclaw.stateDir}/.openclaw/openclaw.json";
  };

  profiles.readonly = {
    commands.exact = [
      [ "status" "--deep" ]
      [ "logs" "--follow" ]
      [ "agents" "list" "--bindings" ]
    ];

    commands.configGet.allowedPaths = [
      "gateway"
      "gateway.*"
      "agents"
      "agents.*"
      "channels"
      "channels.*"
      "models"
      "models.*"
      "skills"
      "skills.*"
    ];
  };

    commands.help = {
      topLevel = true;
      subcommands = [ "status" "logs" "agents" "config" ];
    };
  };

  agentBindings = {
    main = "readonly";
  };
};
```

The exact schema can be refined, but the important part is that policy stays declarative and host-supplied.

## Current Shape

The current implementation direction is:

- a single installed helper command
- a generated policy file in OpenClaw state
- profile-based command policy with agent bindings
- explicit runtime env export
- optional credential-backed env export
- explicit help-only discovery paths alongside strict action allowlists

## Decision Heuristic

When choosing where a change belongs:

- if it is packaging, pathing, code generation, or reusable module behavior -> `openclaw-nix`
- if it is host policy, agent role policy, or deployment posture -> fleet repo

That rule should keep this from turning into another blob of one-off host shell glue.
