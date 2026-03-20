# openclaw CLI gateway review notes

Date: 2026-03-20

This document captures iterative self-review of the socket-activated OpenClaw CLI gateway design and implementation.

## Cycle 1

### Questions

1. Is this actually the right replacement path for the earlier wrapper approach?
2. Is the socket/user/group boundary correct as currently drafted?
3. Is the request/response protocol clear enough to be stable?
4. Is the gateway-side policy engine safe enough to live in the secret-bearing process?
5. Is the current module coupling to `services.openclaw` acceptable?

### Answers

1. It is the right architectural direction so far.
   - It preserves direct agent usability.
   - It removes the need for privilege escalation from the agent runtime.
   - It keeps secrets out of the agent process.
   - It uses the same allow/deny rule model we already proved useful.
   - It is still only the right replacement if the service boundary is implemented cleanly and tested.

2. No, not yet.
   - The current use of `SocketGroup = cfg.agentUser` is too loose and likely wrong in practice.
   - A user name is not the same thing as a deliberate group boundary.
   - We need an explicit configuration surface for which group is allowed to connect to the socket.
   - We also need to confirm how that maps to the real agent service user/groups on the host.

3. No, not yet.
   - The client sends JSON argv, which is correct.
   - But the response model is inconsistent: denied requests return JSON errors while allowed requests stream raw stdout/stderr.
   - We should choose one model and document it clearly.
   - The simplest path is likely structured JSON for both success and failure, but passthrough may be easier in the short term.
   - If passthrough is chosen, we still need explicit exit-code semantics and a documented contract.

4. Not confidently yet.
   - The rule model itself is fine.
   - The concern is that the gateway script currently embeds a lot of shell logic in the secret-bearing process.
   - That increases review surface and makes mistakes more costly.
   - We should either simplify the rule engine there or isolate its behavior more clearly.
   - The current first cut is too large to trust without stronger tests.

5. Maybe, but it needs to be explicit.
   - Reusing `services.openclaw` defaults for state/home is reasonable if the gateway is conceptually part of the same OpenClaw deployment.
   - It becomes a problem if the gateway claims to be reusable but silently depends on another module.
   - The module should either document that dependency clearly or accept explicit values without assuming the base service module is present.

### More questions

6. Should the gateway module require the base OpenClaw service module, or remain independently usable?
7. Should the gateway own the policy file path, or should it share the same path as the old wrapper system?
8. Should the client command keep the name `openclaw-agent-cli`, or should that name be reserved until the gateway fully replaces the wrapper?
9. What is the minimum test surface needed before this is worth another human review?

### Answers

6. It should remain independently usable where possible.
   - Hard dependency on `services.openclaw` would reduce reuse and make the public module more awkward.
   - It is still fine to consume defaults from `services.openclaw` when present.
   - The option/model should work even if those values are provided explicitly instead.

7. It should own a fresh, clearly named policy path.
   - Reusing the old wrapper policy path risks stale-file confusion and mixed-mechanism migrations.
   - A gateway-specific policy path makes testing and migration more legible.

8. Probably not yet.
   - Keeping `openclaw-agent-cli` for the client path is tempting because it preserves the agent-facing command shape.
   - But during transition it may hide whether a host is using the old wrapper or the gateway client.
   - A temporary distinct client name could reduce confusion until the gateway is the settled path.

9. At minimum:
   - module parse/eval checks
   - package build for the client/gateway scripts
   - one VM test proving allowed command, denied command, and secret non-exposure to the agent user
   - one test for socket permission boundary

## Cycle 2

### Questions

1. Is `LoadCredential=` definitely the right secret mechanism for the gateway?
2. Should the gateway return raw stdout/stderr, structured JSON, or both?
3. Is `Accept=true` still the right choice after thinking about testing and protocol shape?
4. What are the most dangerous failure modes of the current draft?
5. What should the socket directory ownership/mode story be?

### Answers

1. Yes, it is still the best fit so far.
   - It aligns with the already working OpenClaw service secret pattern.
   - It avoids persistent agent-readable secret files.
   - It scopes secrets to the service invocation.
   - It is slightly more complex than `EnvironmentFile`, but the security boundary is cleaner.

2. Structured JSON is the better long-term answer.
   - It gives the client a stable parseable contract.
   - It distinguishes policy denial from execution failure cleanly.
   - It avoids muddled client behavior around stdout vs stderr vs exit codes.
   - If passthrough output is needed for UX, it should still be wrapped in a structured response envelope.

3. Yes, probably.
   - `Accept=true` keeps the implementation small.
   - Each request runs in a fresh service instance.
   - It avoids maintaining a long-lived daemon loop.
   - The fork-per-request overhead is fine for this use case.

4. The worst failure modes are:
   - socket access too broad, letting the wrong local user invoke the gateway
   - request parsing bugs that reinterpret argv incorrectly
   - service logs revealing sensitive details from env or request handling
   - gateway script growing into a generic command broker
   - policy drift between design docs and actual gateway behavior

5. It needs to be explicit, not accidental.
   - The socket directory path and socket file should be created with known ownership and mode.
   - The boundary should be controlled by a dedicated configurable group, not by guessing from a username.
   - The current draft is not explicit enough here yet.

### More questions

6. Should there be a dedicated `agentGroup` option for socket access?
7. Should the gateway unit write nothing except request output to stdout?
8. Should denied requests use a distinct exit code from CLI execution failures?
9. How much of the rule engine should be shared with the earlier wrapper code vs rewritten cleanly?

### Answers

6. Yes.
   - The socket permission model should use an explicit group option.
   - That is cleaner, more reusable, and easier to reason about in deployment docs.

7. Yes.
   - stdout should be reserved for the response payload.
   - debug noise should not mix with the client protocol.
   - journald should hold service-side diagnostics.

8. Yes.
   - Denial should have a clear non-zero exit code distinct from CLI execution failure.
   - That makes automation and debugging much easier.

9. Shared semantics, not necessarily shared shell code.
   - The rule kinds and their meaning should remain aligned.
   - But copying/pasting large chunks of shell from the wrapper may not be the cleanest long-term implementation.
   - The gateway-side version should be minimized and reviewed on its own merits.

## Cycle 3

### Questions

1. What should be true before this is ready for another human review?
2. What should be removed or clarified from the current implementation before then?
3. Which implementation decisions are still reversible vs already solid?
4. What should the public docs explain more clearly?
5. What are the migration concerns from the existing wrapper world?

### Answers

1. Before another human review, the following should be true:
   - explicit socket access group option exists
   - request/response contract is chosen and implemented consistently
   - policy path naming is clarified for the gateway
   - the module does not silently depend on `services.openclaw` without documenting it
   - at least one VM/integration test exists
   - secret leakage review has been done on failure and logging paths

2. The current implementation should be tightened by:
   - replacing implicit socket group assumptions
   - removing ambiguous mixed response behavior
   - trimming or restructuring gateway script logic where possible
   - making the naming relationship to the old wrapper clearer

3. Mostly solid decisions:
   - socket-activated service boundary
   - `LoadCredential=`
   - JSON argv request model
   - allow/deny rule engine
   - separate gateway user

   Still reversible:
   - exact option names
   - response format
   - socket/client command naming
   - whether to share defaults from `services.openclaw`

4. Public docs should explain:
   - why this exists instead of a local privileged launcher
   - what the trust boundary is
   - what the request protocol looks like
   - what each rule kind does
   - how socket access is controlled
   - what secrets the gateway sees vs what the agent sees

5. Migration concerns:
   - stale old wrapper policy files should not be reused silently
   - client command naming should avoid making it unclear which mechanism is active
   - consumer repos should move in a deliberate branch/PR, not ad hoc local edits
   - old wrapper docs and examples should eventually be retired or clearly marked superseded

### More questions

6. Is this implementation close enough that consumer work should start now?
7. Is the current PR mergeable as-is if someone only reviews the idea, not the edge cases?
8. What confidence level do these answers support right now?

### Answers

6. No.
   - Consumer work should wait until the reusable module settles further.
   - Otherwise the fleet repo will churn around moving semantics.

7. No.
   - The idea is sound, but the current implementation is not yet crisp enough around boundary conditions.
   - It still needs another round of tightening before it is fair to ask for a real review.

8. Current confidence is moderate on direction, not on implementation readiness.
   - Direction confidence: high
   - Current implementation confidence: medium-low
   - Review readiness confidence: below the threshold for another human pass right now
