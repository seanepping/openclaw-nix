# openclaw CLI gateway socket boundary research

Date: 2026-03-20

## Goal

Determine the safest and clearest socket permission model for the OpenClaw CLI gateway so the agent can connect directly without broadening local access unnecessarily.

## Research findings

### 1. `SocketUser`, `SocketGroup`, and `SocketMode` are the intended control points for filesystem socket permissions

Relevant documentation and references consistently describe these settings as the mechanism for controlling ownership and access mode on Unix-domain sockets created by systemd socket units.

Implication:
- the gateway should use a deliberate socket group and mode instead of inferring from a username or accepting defaults accidentally

### 2. Unix-domain socket access is controlled by both the socket node and its directory path

General Unix socket behavior and systemd socket guidance imply that the containing directory and the socket file permissions both matter.

Implication:
- the socket directory itself should be created with explicit ownership/mode expectations
- a correct socket file mode alone is not enough if the directory permissions are overly broad or mismatched

### 3. A dedicated group boundary is preferable to guessing from the agent user name

Systemd socket configuration supports group ownership directly, and operator guidance around other socket-activated daemons commonly treats socket groups as the stable access boundary.

Implication:
- the gateway module should expose an explicit option such as `agentGroup` or `socketGroup`
- the gateway should not derive the socket group from `agentUser` implicitly

### 4. `Accept=true` remains consistent with this permission model

The socket file is owned and permissioned by the socket unit. The service instances created for each accepted connection do not change the socket node ownership model.

Implication:
- choosing `Accept=true` does not conflict with an explicit socket group design
- the socket boundary can be designed independently from the service execution model

## Recommended design direction

### Explicit options

The gateway module should expose at least:

- `agentUser`
  - the agent-side runtime user expected to invoke the client command
- `socketGroup`
  - the group allowed to connect to the gateway socket
- `socketMode`
  - the socket node permissions, default likely `0660`
- `socketDir`
  - if we want the directory path separately configurable from the socket file path

### Default boundary

Reasonable default posture:

- gateway service user owns the socket user side
- dedicated gateway group owns the service side
- socket group is a deployment-provided group that the agent runtime belongs to
- socket mode stays `0660`
- socket directory is not world-accessible

### Things to avoid

- inferring socket group from the agent user string
- world-readable or world-writable socket modes
- reusing a broad existing group just because it is convenient
- assuming the socket file alone defines the boundary while ignoring directory permissions

## Questions still needing host-specific answers

These are not architectural unknowns anymore; they are deployment questions.

### Q1. Which exact group should the real agent runtime belong to for socket access?

Goal:
- choose a group boundary that is narrow, legible, and reusable for this host

Desired output:
- one group name to use in the consumer repo for the socket boundary

### Q2. Should the agent user's primary group be reused, or should there be a dedicated socket-access group?

Current leaning:
- prefer a dedicated group if the operational cost is acceptable

Desired output:
- a concrete decision for the first deployment

### Q3. Does the chosen runtime path need an explicit directory creation rule beyond what the socket unit already implies?

Goal:
- ensure `/run/openclaw-cli-gw` is created with the right ownership and not left to accidental defaults

Desired output:
- either rely on systemd socket path creation with explicit settings or add a clear tmpfiles/runtime-dir rule

## Recommendation summary

- Add an explicit socket access group option to the module
- Treat the socket directory and socket file permissions as part of the security boundary
- Keep `Accept=true`
- Make the consumer repo choose the actual group boundary explicitly rather than letting the reusable module guess
