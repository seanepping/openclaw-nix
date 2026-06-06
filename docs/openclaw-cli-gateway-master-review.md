# openclaw CLI gateway master review

Date: 2026-03-20

This document condenses the iterative review notes into a single reference list of questions, answers, blockers, and required research/testing.

## Core questions and answers

### 1. Is the socket-activated gateway the right replacement path for the earlier wrapper approach?

Yes.

Why:
- preserves direct agent usability without requiring privilege escalation from the agent runtime
- keeps secrets out of the agent process and filesystem view
- matches the already proven need for a policy-gated OpenClaw CLI surface
- aligns with the first lesson: do not build the agent path around a privilege boundary it cannot cross

### 2. Is socket activation with `Accept=true` the right architecture?

Yes, for the first pass.

Why:
- one request per service instance keeps the design simple
- avoids maintaining a long-running custom daemon
- gives per-request isolation
- systemd handles lifecycle and activation

Caveat:
- this fits finite-output commands much better than long-running streaming commands

### 3. Should the gateway use `LoadCredential=` or `EnvironmentFile`?

`LoadCredential=` is preferred.

Why:
- credentials remain scoped to the service invocation
- avoids persistent readable secret files for the agent user
- matches the existing secure OpenClaw service pattern better than runtime-readable file copies

### 4. Should the request protocol use shell strings or structured argv?

Structured argv.

Why:
- avoids shell parsing ambiguity
- preserves argument boundaries
- supports the rule engine directly
- avoids injection footguns from string reconstruction

Recommended request shape:

```json
{
  "agentId": "main",
  "argv": ["status", "--deep"]
}
```

### 5. Should the gateway reuse the existing rule engine semantics?

Yes.

Use the same policy model:
- `allowRules`
- `denyRules`
- rule kinds:
  - `exact`
  - `prefix`
  - `prefixArgGlob`
  - `help`

Why:
- keeps policy semantics consistent across approaches
- preserves useful work already done on policy modeling
- scales better than command-specific shell branching

### 6. Should the gateway policy stay deployment-owned?

Yes.

Why:
- policy is non-secret
- should be deterministic from Nix config
- should be replaced on each switch, unlike seeded runtime state such as `openclaw.json`

### 7. Should the client command be non-privileged and directly invocable by the agent?

Yes.

Why:
- this is a hard requirement derived from the first lesson
- if the command requires root or `sudo`, it fails the actual agent-usable requirement

### 8. Should the gateway support the full CLI immediately?

No, not in the first implementation pass.

The architecture should support future growth, but the first pass should target:
- finite-output
- non-interactive
- policy-bounded commands

### 9. Should streaming and interactive commands be included in the first gateway pass?

Probably not.

Commands that should be treated as out of scope for the first pass:
- `logs --follow`
- interactive `doctor`
- other TTY- or prompt-driven flows

Why:
- they complicate the response protocol
- they complicate service lifecycle semantics
- they complicate tests

### 10. Should help exploration remain first-class?

Yes.

Why:
- it is a safe discovery surface across CLI versions
- it enables operator-approved exploration without opening broader execution
- it supports the goal of growing agent CLI usage over time

Recommended rule:

```nix
{
  kind = "help";
  allowAnyCommand = true;
}
```

### 11. Should broad prefix rules be allowed?

Yes, with care.

Recommended model:
- `prefix` is the generic backbone
- `minArgs` defaults to `prefix.length`
- `maxArgs` is unset unless explicitly needed
- let the underlying CLI validate normal arguments
- use `prefixArgGlob` only when a specific argument truly needs policy narrowing

### 12. Should deny rules exist?

Yes.

Why:
- they are useful when the allowed command surface becomes broad
- they act as a second guardrail for clearly destructive shapes
- they use the same rule kinds as `allowRules`

### 13. Should the gateway be generic for arbitrary binaries?

No.

Why:
- that would drift into a generic command broker
- increases security risk and scope dramatically
- the first target is specifically the OpenClaw CLI

### 14. Should the gateway module be independent of `services.openclaw`?

Mostly yes, or at least explicit.

Current conclusion:
- the gateway may use `services.openclaw` defaults when present
- but it should expose explicit options for state/config paths rather than silently depending on another module

### 15. Should the response protocol be structured JSON?

Yes, preferably.

Why:
- clean distinction between policy denial and CLI failure
- easier automation and testing
- more stable protocol contract than mixed stdout/stderr passthrough

Example response shape:

```json
{
  "ok": true,
  "exitCode": 0,
  "stdout": "...",
  "stderr": ""
}
```

Example denial:

```json
{
  "ok": false,
  "error": "command denied by policy",
  "exitCode": 2
}
```

### 16. Should the client stay simple?

Yes.

Why:
- it should serialize argv and send the request
- it should not duplicate policy or command logic
- formatting or pretty-printing should remain secondary to a stable transport boundary

### 17. Should socket access be controlled by a dedicated group?

Yes.

Why:
- user names are not a sufficient permission boundary
- an explicit configurable group is clearer and more reusable
- this is one of the most important unresolved implementation details

### 18. Should old wrapper paths, names, and files be reused during migration?

Only carefully, and preferably not silently.

Why:
- stale files and old naming caused real confusion already
- gateway-specific naming/pathing should make the active mechanism obvious

## Current blockers

These are the main blockers before the implementation should be considered ready for another serious review.

1. Explicit socket access boundary
- Need a dedicated option for the socket access group.
- Need to stop inferring from usernames.

2. Response contract not finalized
- Need to choose one model and implement it consistently.
- Prefer structured JSON for both success and failure.

3. First-pass scope not enforced tightly enough
- Need to explicitly narrow to finite-output, non-interactive commands.
- Need to remove examples/assumptions that imply support for streaming or interactive commands.

4. Module coupling needs cleanup
- Need explicit `stateDir` / `configPath` style options, or clearly documented fallback behavior.

5. Gateway script review surface is still too large
- Need to minimize or at least tighten the secret-bearing script implementation.
- Need a clearer separation between transport handling and rule evaluation if possible.

6. No meaningful automated test path yet
- Need at least one VM/integration test before treating the implementation as review-ready.

## Research still needed

1. Socket/user/group boundary on the real host
- confirm the correct agent-side group to grant socket access to
- ensure it maps cleanly to the real agent runtime identity

2. Best structured response model
- decide whether the gateway should always buffer command output into JSON
- or whether a limited framed passthrough mode is needed later for larger outputs

3. Non-interactive command set for first pass
- confirm which OpenClaw commands are finite-output and safe enough for the first gateway rollout
- especially reassess `cron` command shapes and whether they stay finite/non-interactive

4. Public module naming and migration naming
- decide whether the client should keep a compatibility name or use a clearer temporary gateway-specific name during migration

## Testing still needed

### Minimum before next serious review

1. Build/eval checks
- module parse/eval
- package builds for client and gateway scripts

2. VM/integration test
- allowed command succeeds
- denied command fails cleanly
- agent user cannot read secrets directly
- secrets are visible only inside the gateway service context
- socket permissions reject unrelated users

3. Protocol test
- malformed JSON request fails closed
- denial returns distinct structured response/exit code

4. Scope test
- non-interactive finite-output commands work
- unsupported interactive or streaming commands fail in a predictable way

## Current confidence summary

- Architecture confidence: high
- Policy model confidence: high
- Secret-boundary confidence: high in principle, pending implementation tightening
- Current implementation confidence: medium
- Review readiness confidence: not yet at the threshold for another full human review

## Recommended next implementation priorities

1. tighten socket access boundary with explicit group option
2. choose and implement one structured response contract
3. narrow first-pass scope to finite-output, non-interactive commands only
4. reduce ambiguity around module coupling and naming
5. add initial VM/integration tests
