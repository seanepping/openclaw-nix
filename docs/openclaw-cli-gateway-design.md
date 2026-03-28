# openclaw CLI gateway design

Date: 2026-03-19

## Goal

Expose a policy-limited subset of the OpenClaw CLI to the agent without giving the agent direct access to secrets, secret files, or privileged execution paths.

## Why this exists

The current agent runtime cannot rely on privilege escalation. It runs with `NoNewPrivileges=true`, which blocks the usual helper patterns based on `sudo`, `runuser`, setuid, or security wrappers.

The OpenClaw CLI still needs secrets for useful commands such as deeper status checks, channel-aware diagnostics, and scheduled jobs.

So the secret-bearing execution path must live outside the agent process while still remaining callable by the agent.

## Design summary

Use a socket-activated gateway service.

- the agent calls a local client command
- the client connects to a Unix socket
- systemd accepts the connection and starts a fresh service instance
- the gateway service loads credentials with `LoadCredential=`
- the gateway validates the requested argv against allow/deny rules
- if allowed, it execs the OpenClaw CLI with preserved argv
- stdout/stderr are returned over the socket
- the service exits after the request completes

This preserves direct agent usability while keeping secrets entirely outside the agent runtime.

## Architecture

```text
agent runtime
  -> openclaw-agent-cli (client)
  -> unix socket /run/openclaw-cli-gw/openclaw.sock
  -> systemd Accept=true socket activation
  -> openclaw-cli-gw@.service instance
  -> load credentials into $CREDENTIALS_DIRECTORY
  -> evaluate allowRules / denyRules
  -> exec openclaw argv...
  -> return output over socket
```

## Security properties

- the agent process never receives secrets in its environment
- the agent process cannot read secret files directly
- the gateway service owns the secret-bearing execution path
- the visible agent command is non-privileged and directly invocable by the agent
- each request runs in a fresh service instance
- policy is deployment-owned and immutable at runtime
- the gateway service can be sandboxed independently from the agent service

## What moves where

### `openclaw-nix`

Owns the reusable mechanism:

- gateway client command
- socket unit and service template
- policy file generation
- gateway-side rule evaluation implementation
- generic options for credentials, policy path, runtime paths, and users
- integration tests for the gateway behavior

### consumer repo

Owns deployment-specific policy and credentials:

- which secrets are mapped into the gateway
- which agent ids bind to which profiles
- which allow/deny rules exist for that host
- which gateway package/output is consumed

## Request protocol

Do not pass a shell command string.

The client sends a structured JSON request over the socket.

Example:

```json
{
  "argv": ["status", "--deep"],
  "agentId": "main"
}
```

Notes:

- `argv` is the only required field for the first pass
- `agentId` can be optional if the client and policy use a single default profile
- no shell parsing or string splitting should happen in the gateway
- argv should be exec'd directly as argv

## Response shape

The simplest response shape is structured JSON with passthrough output.

Example success:

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
  "error": "command denied by policy"
}
```

If direct stdout/stderr passthrough is simpler for early implementation, that is acceptable, but the gateway should still use distinct non-zero exit codes for denial vs execution failure.

## Policy model

Reuse the rule model already developed for the wrapper.

Each profile has:

- `allowRules`
- `denyRules`

Supported rule kinds:

- `exact`
- `prefix`
- `prefixArgGlob`
- `help`

### `exact`

Allow or deny one exact argv vector.

Example:

```nix
{
  kind = "exact";
  argv = [ "status" "--deep" ];
}
```

### `prefix`

Allow or deny any argv beginning with a prefix.

Fields:

- `prefix` (required)
- `minArgs` (optional, defaults to `prefix.length`)
- `maxArgs` (optional, unset by default)

Example:

```nix
{
  kind = "prefix";
  prefix = [ "cron" ];
}
```

### `prefixArgGlob`

Allow or deny a prefix, but constrain one argument position with glob matching.

Fields:

- `prefix` (required)
- `argIndex` (required)
- `allowed` (required)
- `minArgs` (optional, defaults to `prefix.length + 1`)
- `maxArgs` (optional, unset by default)

Example:

```nix
{
  kind = "prefixArgGlob";
  prefix = [ "config" "get" ];
  argIndex = 2;
  allowed = [ "gateway" "gateway.*" ];
}
```

### `help`

Allow CLI exploration without opening normal command execution.

Fields:

- `allowAnyCommand` (optional)
- `topLevel` (optional)
- `maxDepth` (optional)

Recommended default:

```nix
{
  kind = "help";
  allowAnyCommand = true;
}
```

## Rule evaluation order

1. parse request JSON
2. resolve agent/profile binding
3. evaluate `denyRules`
4. evaluate `allowRules`
5. if matched, exec the CLI with argv preserved
6. if no allow rule matches, deny

This keeps the model simple and predictable.

## Credentials model

Use `LoadCredential=` on the gateway service.

Why:

- secrets become available only inside the service invocation
- no persistent secret files readable by the agent user
- aligns with the already working OpenClaw service credential pattern

The gateway script reads from `$CREDENTIALS_DIRECTORY/<name>` and exports only the configured env vars for the child CLI process.

## Socket and service shape

### socket unit

- Unix domain socket under `/run/openclaw-cli-gw/openclaw.sock`
- `Accept=true`
- socket mode restricted to the agent user/group boundary

### service template

- one instance per connection
- `StandardInput=socket`
- `StandardOutput=socket`
- `StandardError=journal`
- sandboxing enabled
- credentials loaded with `LoadCredential=`
- fixed OpenClaw CLI target path from Nix

## Sandboxing goals

The gateway service should use a strong sandbox, for example:

- `NoNewPrivileges=true`
- `ProtectSystem=strict`
- `ProtectHome=true`
- `PrivateTmp=true`
- `PrivateDevices=true`
- `ProtectKernelTunables=true`
- `ProtectKernelModules=true`
- `ProtectControlGroups=true`
- `RestrictNamespaces=true`
- `RestrictSUIDSGID=true`
- `MemoryDenyWriteExecute=true`

These can be tuned if the real CLI runtime needs additional access.

## Failure modes to design for

- stale or malformed JSON request
- socket missing or inactive
- credentials missing from the gateway instance
- denied command due to policy
- OpenClaw CLI returns non-zero
- gateway timeout on long-running commands
- accidental log leakage of sensitive env or request details

The implementation should fail closed.

## Non-goals

Not part of the first gateway pass:

- generic command execution for arbitrary binaries
- policy-defined command rewriting
- fully generic policy validators beyond current rule kinds
- remote access over TCP
- multiple concurrent protocol versions
- agent-managed credential mutation

## Testing

### Dev-time checks

- `nix build` for the client/gateway package outputs
- NixOS module parse/eval checks
- focused VM test for socket activation and policy enforcement

### Integration test goals

- agent user can call the client successfully for allowed commands
- denied commands fail cleanly
- secrets are present in the gateway context
- secrets are absent from the agent environment
- agent cannot read secret files directly
- socket permissions restrict unrelated users
- help exploration works

## Recommended next step

Implement this as a fresh follow-up from the merged wrapper baseline rather than incrementally bending the current privileged-launch wrapper further.
