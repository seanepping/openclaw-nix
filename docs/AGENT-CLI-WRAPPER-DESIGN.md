# Agent CLI Wrapper Design

Date: 2026-03-18

## Goal

Provide a reusable, Nix-managed way to expose a narrow OpenClaw CLI surface to agents without allowlisting the raw `openclaw` binary.

This belongs in `openclaw-nix` because it is packaging and module machinery, not fleet-specific policy.

## Review Status

This document now has a first visual implementation companion:

- `pkgs/openclaw-agent-cli.nix`

That packaged helper is intentionally incomplete, but it is concrete enough to review the shape:

- single helper binary
- Nix-provided policy file path
- exact argv allowlist support
- constrained `config get` path allowlist support
- no raw shell passthrough

## Design Split

### `openclaw-nix` owns

- module options for enabling an agent-facing wrapper
- generation/installation of the wrapper executable
- generation/installation of a policy file the wrapper reads
- stable runtime paths for the wrapper and policy
- integration points for host exec-approval configuration
- reusable docs and examples

### Fleet repo (`loonar-float-nix`) owns

- which hosts enable the wrapper
- which shared policy profiles exist
- which agent ids bind to which policy profiles
- exact allowlisted OpenClaw subcommands and argument constraints for those profiles
- whether a host uses readonly-only or adds an ops/write profile

## Why Not Allowlist Raw `openclaw`

OpenClaw native exec approvals and allowlists are executable-path based. They are useful as an outer gate, but they do not give us enough argument-level control for a large multi-command CLI.

Allowlisting the raw `openclaw` binary broadly would trust too much surface area.

The safer model is:

1. native OpenClaw exec approvals gate host execution
2. only the dedicated wrapper executable is allowlisted for the agent
3. the wrapper enforces subcommand, flag, and path policy from a Nix-generated policy file

## What The Readonly Test Taught Us

The first host-local wrapper PR exposed two important truths:

- the wrapper cannot assume direct read access to `/run/agenix/...` secrets
- the wrapper cannot assume the OpenClaw binary lives at `/run/current-system/sw/bin/openclaw`

On the tested host, the service works because:

- secrets are injected through `LoadCredential=`
- the service startup script reads from `$CREDENTIALS_DIRECTORY/...`
- the OpenClaw executable is invoked from its store path

That means the reusable wrapper design should:

- source the OpenClaw binary path from Nix
- avoid direct reads from raw agenix secret paths
- use a Nix-managed runtime env/credential mechanism rather than ad hoc host shell assumptions

## Interaction With OpenClaw Native Controls

We should treat these as complementary layers:

- **Exec approvals / per-agent allowlists:** outer gate on whether an executable may run at all
- **`tools.exec.safeBins`:** useful for stdin-only utilities, not for `openclaw`
- **Wrapper policy file:** inner gate on which `openclaw` actions are permitted

Current direction after review:

- `exec-approvals.json` should remain OpenClaw-owned, not Nix-owned
- the wrapper policy may still be Nix-generated and host-managed
- raw `openclaw` should stay off the agent's exec approval allowlist
- only the dedicated wrapper path should be allowlisted for the relevant agent ids

## Proposed Runtime Shape

### Executable path

The wrapper itself should be installed by Nix and exposed on the host as a normal command, for example:

- `/run/current-system/sw/bin/openclaw-agent-cli`

But the wrapped OpenClaw executable path must come from Nix-rendered configuration, not from assumptions about where the runtime package is linked on a given host. The readonly test showed that the real OpenClaw binary may live only at a store path.

### Policy path

Install a generated policy file alongside OpenClaw state, for example:

- `/var/lib/openclaw/.openclaw/agent-cli-policy.json`

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
    "HOME": "/var/lib/openclaw",
    "OPENCLAW_CONFIG_PATH": "/var/lib/openclaw/.openclaw/openclaw.json"
  },
  "profiles": {
    "readonly": {
      "commands": {
        "exact": [
          ["status", "--deep"],
          ["logs", "--lines", "200"],
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
  policyFile = "/var/lib/openclaw/.openclaw/agent-cli-policy.json";

  env = {
    HOME = "/var/lib/openclaw";
    OPENCLAW_CONFIG_PATH = "/var/lib/openclaw/.openclaw/openclaw.json";
  };

  profiles.readonly = {
    commands.exact = [
      [ "status" "--deep" ]
      [ "logs" "--lines" "200" ]
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

  agentBindings = {
    main = "readonly";
  };
};
```

The exact schema can be refined, but the important part is that policy stays declarative and host-supplied.

## Tracer Bullets

### Phase 1: Document and model

- [x] Record the outer/inner gate model in `openclaw-nix` docs.
- [x] Add a first packaged helper for visual review.
- [ ] Choose the first stable option schema for wrapper + policies.

### Phase 2: Reusable module machinery

- [ ] Add `services.openclaw.agentCliWrapper.*` options in `openclaw-nix`.
- [ ] Generate the policy file from Nix data.
- [ ] Generate/install the wrapper in `/run/current-system/sw/bin`.
- [ ] Support explicit env + runtime credential plumbing without `sudo`.

### Phase 3: Fleet integration

- [ ] Move emacagent policy data out of ad hoc shell snippets and into Nix policy config.
- [ ] Define shared profiles and bind `main` to a readonly profile.
- [ ] Remove the current broken host-local readonly wrappers instead of preserving them.

### Phase 4: Exec approvals alignment

- [ ] Document the expected exec-approval stance for the wrapper.
- [ ] Allowlist only the dedicated wrapper path for the relevant agent ids.
- [ ] Keep raw `openclaw` off the agent allowlist.
- [ ] Keep `exec-approvals.json` under OpenClaw's own management, not Nix.

### Phase 5: Verify and expand

- [ ] Test readonly wrapper behavior after deploy.
- [ ] Add `doctor` or `security audit` only if their behavior stays acceptably read-only.
- [ ] Design a separate narrow write profile for reminder/cron continuity work.

## Decision Heuristic

When choosing where a change belongs:

- if it is packaging, pathing, code generation, or reusable module behavior -> `openclaw-nix`
- if it is host policy, agent role policy, or deployment posture -> fleet repo

That rule should keep this from turning into another blob of one-off host shell glue.
