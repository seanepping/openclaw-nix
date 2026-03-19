# agent CLI wrapper refactor plan

Date: 2026-03-19

## Goal

Refactor the OpenClaw agent CLI wrapper from command-specific shell branching into a small rule-driven policy engine that scales as the CLI grows.

This is a follow-up to the merged baseline implementation. The current wrapper works and has been validated live. The purpose of this refactor is to improve maintainability and make policy expansion data-driven instead of code-driven.

## Why refactor now

The current implementation already proved the important pieces:

- generated wrapper policy file
- installed helper command
- runtime env and credential wiring
- live readonly execution against the gateway
- bounded help exploration

What does not scale well is the validation structure itself. It still contains command-shaped branches for specific OpenClaw behavior, which will get brittle as the CLI evolves.

## Target shape

Keep the same outer module shape:

- `services.openclaw.agentCliWrapper`
- generated policy in OpenClaw state
- one installed helper command
- consumer-owned profiles and agent bindings

Change the internal policy model to a rule list.

## Proposed rule model

Each profile should define an ordered list of rules.

Example:

```json
{
  "profiles": {
    "readonly": {
      "rules": [
        {
          "kind": "exact",
          "argv": ["status", "--deep"]
        },
        {
          "kind": "exact",
          "argv": ["logs", "--follow"]
        },
        {
          "kind": "exact",
          "argv": ["agents", "list", "--bindings"]
        },
        {
          "kind": "prefixArgGlob",
          "prefix": ["config", "get"],
          "argIndex": 2,
          "allowed": [
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
        },
        {
          "kind": "help",
          "topLevel": true,
          "subcommands": ["status", "logs", "agents", "config"]
        }
      ]
    }
  }
}
```

## First rule kinds

Start with only a few rule kinds:

- `exact`
  - exact argv match
- `prefixArgGlob`
  - exact prefix plus one validated argument matched against allowed globs
- `help`
  - allow `help`, `--help`, `<cmd> --help`, and selected `<cmd> <subcmd> --help`

These should cover the current readonly wrapper needs without reopening the abstraction too widely.

## Explicit non-goals

Do not turn this into a generic sandbox/policy system yet.

Specifically out of scope for this pass:

- arbitrary regex-based command matching
- free-form shell fragments
- policy-defined command rewrites
- automatic CLI discovery from help output
- non-OpenClaw generic binary wrapping
- replacing OpenClaw exec approvals

## Migration approach

1. Preserve the current external module shape.
2. Introduce the rule list in the generated policy format.
3. Update the wrapper helper to evaluate ordered rules.
4. Translate the current readonly profile into rule entries.
5. Keep runtime behavior equivalent where possible.
6. Re-run live validation after the refactor.

## Validation plan

Development-time validation:

- `nix build .#packages.x86_64-linux.openclaw-agent-cli`
- `nix-instantiate --parse modules/openclaw-agent.nix`

Consumer validation after wiring:

- `nix-instantiate --parse hosts/<host>/configuration.nix`
- deploy and switch on the test host
- validate:
  - `openclaw-agent-cli status --deep`
  - `openclaw-agent-cli agents list --bindings`
  - `openclaw-agent-cli config get gateway`
  - `openclaw-agent-cli logs --follow`
  - allowed help forms
  - disallowed commands still fail cleanly

## Code changes expected

Likely touched files:

- `pkgs/openclaw-agent-cli.nix`
- `modules/openclaw-agent.nix`
- `docs/agent-cli-wrapper-design.md`

Possible consumer follow-up if schema changes require it:

- consumer host policy definitions in the fleet repo

## Review intent

This branch is planning-only. The next branch should contain the actual refactor implementation with minimal extra churn.
