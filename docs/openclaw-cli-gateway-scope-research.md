# openclaw CLI gateway first-pass scope research

Date: 2026-03-20

## Goal

Define which command shapes belong in the first socket-gateway implementation and which should be deferred.

## Findings

### 1. Finite-output, non-interactive commands are the right first-pass target

Why:
- they fit cleanly into a one-request/one-response socket model
- they simplify timeout handling and testing
- they reduce ambiguity around TTY behavior and service lifecycle

### 2. Interactive and streaming commands complicate the protocol disproportionately

Examples:
- `logs --follow`
- interactive `doctor`
- prompt-driven or TUI-like flows

Implication:
- these should not be considered first-pass gateway targets

### 3. High-value first-pass candidates still exist without interactive commands

Good candidates:
- `status --deep`
- `agents list --bindings`
- `config get <path>` with policy narrowing as needed
- `docs <query>`
- help exploration via `--help` and `help`
- likely a subset of `cron` if the specific forms are finite-output and non-interactive

### 4. Some commands need follow-up research before inclusion

Specifically:
- `cron`
  - useful for autonomy
  - but individual subcommands need to be checked for output shape and interactivity
- `security audit`
  - potentially useful, but needs validation for output behavior and side effects
- `doctor`
  - not suitable for first pass because of interactive and semi-remediation behavior

## Recommended first-pass allow examples

Examples appropriate for v1 policy discussion:

```nix
allowRules = [
  {
    kind = "exact";
    argv = [ "status" "--deep" ];
  }
  {
    kind = "exact";
    argv = [ "agents" "list" "--bindings" ];
  }
  {
    kind = "prefixArgGlob";
    prefix = [ "config" "get" ];
    argIndex = 2;
    allowed = [ "gateway" "gateway.*" "agents" "agents.*" ];
  }
  {
    kind = "prefix";
    prefix = [ "docs" ];
  }
  {
    kind = "help";
    allowAnyCommand = true;
  }
];
```

## Commands to defer explicitly

- `logs --follow`
- `doctor`
- any TTY-bound flows
- commands that open browsers or login prompts
- command shapes that require a streaming response contract

## Questions that still need concrete research

### Q1. Which `cron` subcommands are finite-output and non-interactive in the current OpenClaw CLI?

Goal:
- decide whether `cron` belongs in v1 and which command shapes are acceptable

Desired output:
- a short allowlist recommendation for `cron`

### Q2. Does `security audit` produce stable finite output with no interactive prompts in the installed CLI version?

Goal:
- decide if it is suitable for the gateway first pass

Desired output:
- yes/no recommendation with command examples

### Q3. Are there any other high-value non-interactive commands we should include early?

Goal:
- avoid under-scoping the gateway unnecessarily

Desired output:
- a small shortlist of additional commands worth validating

## Recommendation summary

- First gateway pass should explicitly target finite-output, non-interactive commands only
- `status`, `agents list`, scoped `config get`, `docs`, and `help` are strong starting points
- `cron` needs command-level follow-up research
- `doctor` and `logs --follow` should be deferred
