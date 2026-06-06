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

## Cycle 4

### Questions

1. Can the current gateway module be used without `services.openclaw`, or does it only pretend to be decoupled?
2. Is the current client command name likely to confuse migration and testing?
3. Is the current socket path naming specific and stable enough?
4. Does the first implementation make it obvious which process owns policy enforcement?
5. Is the current service template name and socket name clear enough for operators reading `systemctl` output?

### Answers

1. Not fully yet.
   - It still reaches into `services.openclaw` defaults for state and home.
   - That can be convenient, but it weakens the independence claim unless documented or made optional in a more deliberate way.
   - The gateway module should either require those values explicitly or expose its own options with fallback behavior clearly documented.

2. Yes, likely.
   - Reusing `openclaw-agent-cli` for the gateway client risks confusion with the earlier local wrapper implementation.
   - During migration and testing, it would be cleaner to use a distinct client name or provide an explicit compatibility toggle.

3. Mostly, but it can be clearer.
   - `/run/openclaw-cli-gw/openclaw.sock` is descriptive enough.
   - The directory ownership and lifecycle still need to be part of the design, not just the path string.

4. Not clearly enough yet.
   - The current code mixes request parsing, policy evaluation, credential export, and CLI execution in one gateway script.
   - That is acceptable for a prototype, but the trust boundary is harder to audit when too much happens inline.

5. Good enough for now, but worth polishing.
   - `openclaw-cli-gateway` is understandable.
   - The instance template and socket names are readable enough, but public docs should show the exact unit names operators will use.

### More questions

6. Should the gateway module expose explicit `stateDir` and `configPath` options instead of inferring from `services.openclaw`?
7. Should the client command name default to something migration-specific until the gateway becomes the only path?
8. Should the socket and service units include more explicit descriptions and grouping for operator UX?
9. Is the policy file path name specific enough to the gateway mechanism?

### Answers

6. Yes.
   - Explicit options would make the module truly reusable and reduce hidden coupling.
   - Defaults can still follow `services.openclaw` when present, but they should not be the only path.

7. Probably yes.
   - A distinct temporary name reduces ambiguity while both ideas exist in memory and docs.
   - Once the gateway becomes authoritative, the client name can collapse back to the canonical one.

8. Yes, a bit.
   - Operators should be able to identify the socket/service quickly in logs and systemctl output.
   - Better descriptions are low-cost clarity.

9. Barely.
   - The path should probably make the mechanism obvious, not just the command purpose.
   - That helps avoid stale-file or mixed-mechanism confusion later.

## Cycle 5

### Questions

1. Is the current JSON request shape sufficient for future growth?
2. Do we need request metadata beyond `argv` and optional `agentId`?
3. Should the gateway support different profiles without exposing profile selection directly to the agent?
4. Is the current rule engine expressive enough for the first gateway pass?
5. Is the response model still underdefined in a way that blocks implementation confidence?

### Answers

1. Yes, for the first pass.
   - `argv` plus optional `agentId` is enough to exercise the policy model.
   - We do not need to over-design the protocol early.

2. Not immediately.
   - Extra metadata like request IDs, timeouts, or session labels can come later.
   - They are not necessary for proving the boundary and rule model.

3. Yes.
   - Agent-to-profile binding should remain deployment-managed.
   - The agent should not be able to ask for a more powerful profile just by naming it.
   - `agentId` is acceptable as a lookup key if it maps only to deployment-owned bindings.

4. Yes, for the first pass.
   - `exact`, `prefix`, `prefixArgGlob`, and `help` are enough to prove the gateway model.
   - More validators can wait.

5. Yes.
   - This is still one of the biggest unsettled pieces.
   - We need to pick either a fully structured response envelope or a clearly documented passthrough contract.
   - The current halfway posture weakens confidence.

### More questions

6. Should success responses always be JSON even for human-oriented commands like `status --deep`?
7. Should failure responses include stderr separately, or only a human-readable error field?
8. Should the client unwrap JSON for interactive use, or stay dumb and pass it through?
9. Does picking structured JSON now make later tooling easier enough to justify the extra effort?

### Answers

6. Probably yes, if we want a stable contract.
   - The client can always pretty-print or unwrap later.
   - The gateway protocol itself benefits from consistency more than convenience.

7. Yes, ideally.
   - Separate `stderr` and `error` fields give more clarity.
   - That makes policy denial distinct from CLI failure.

8. The client should stay mostly dumb.
   - It should serialize requests and surface responses, not become another policy or formatting layer.
   - Minimal pretty-printing may be acceptable, but the boundary should stay thin.

9. Yes.
   - It is extra work up front, but it pays down ambiguity and makes tests cleaner.

## Cycle 6

### Questions

1. Is `Accept=true` still the simplest good choice if we adopt structured JSON responses?
2. Are there any hidden problems with using socket stdin/stdout directly for JSON framing?
3. What does the gateway need to guarantee about line endings, buffering, and large outputs?
4. Is there a risk that long-running commands like `logs --follow` do not fit the one-request response model cleanly?
5. Does the first gateway pass need to support streaming commands at all?

### Answers

1. Yes.
   - Structured JSON does not conflict with `Accept=true`.
   - One request per connection remains a good model.

2. Some, but manageable.
   - If the gateway uses newline-delimited JSON requests and response envelopes, framing can stay simple.
   - We must avoid partial writes and mixed stderr/stdout framing confusion.

3. The gateway must choose a clear model.
   - Either fully buffered command execution into a JSON response envelope
   - or streaming passthrough with a different protocol shape
   - trying to do both in the same first pass is risky.

4. Yes.
   - `logs --follow` is inherently streaming and open-ended.
   - That does not fit neatly into a single buffered JSON response envelope.

5. Probably not.
   - The first gateway pass should likely avoid streaming commands.
   - If we want `logs --follow` later, it may need either a passthrough mode or a distinct streaming protocol.

### More questions

6. Should `logs --follow` be removed from the first gateway policy target set?
7. Should the first gateway pass focus on finite-output commands only?
8. Is a future `stream = true` request mode worth planning for now?
9. Does dropping streaming commands materially reduce usefulness for the first pass?

### Answers

6. Yes, probably.
   - It is the most obvious protocol-complicating command in the current policy set.

7. Yes.
   - Finite-output commands make protocol, tests, and failure handling much simpler.

8. Not yet.
   - It is worth noting as future work, but should not complicate the first pass.

9. Somewhat, but acceptably.
   - We lose a useful debugging path, but gain a much cleaner first implementation.
   - `status --deep`, `doctor`-like diagnostics, `docs`, `help`, and finite `cron` commands still provide plenty of value.

## Cycle 7

### Questions

1. Does allowing `doctor` make sense in the gateway first pass given its interactive nature?
2. Are there other commands in the likely allowlist that become awkward over a structured request/response protocol?
3. Should the first gateway pass explicitly target only non-interactive commands?
4. Does the client need timeout control for commands like docs search or cron help?
5. Should the gateway reject commands that try to become interactive or TTY-bound?

### Answers

1. No, not in the first pass.
   - `doctor` can prompt, change permissions, and generally act like an interactive TUI.
   - That is not a good fit for the first finite-output socket gateway model.

2. Yes.
   - Any command that expects an interactive terminal, prompt flow, or follow-style streaming will be awkward.
   - `logs --follow` and `doctor` are the clearest examples.

3. Yes.
   - That boundary should be explicit.
   - The gateway should start with non-interactive, finite-output commands only.

4. Yes, but a fixed timeout may be enough initially.
   - The client can start with one reasonable timeout and evolve later.

5. Yes.
   - The gateway should fail closed on commands that require a TTY or become interactive in unsupported ways.

### More questions

6. Should the design doc explicitly call out non-interactive-only scope for the first pass?
7. Should the policy examples remove `logs --follow` and `doctor` now?
8. Should the gateway expose a finite `logs` form only if the upstream CLI supports one reliably?
9. Does this change which consumer rules are worth prototyping first?

### Answers

6. Yes.
   - That would materially clarify the initial scope.

7. Yes.
   - Leaving them in examples suggests a capability the first implementation should not claim.

8. Yes.
   - Only if the installed OpenClaw version has a stable finite form worth supporting.

9. Yes.
   - `status --deep`, `agents list --bindings`, `config get`, `docs`, `help`, and likely parts of `cron` become the best early targets.

## Cycle 8

### Questions

1. Is there enough value left in the first gateway pass if we remove streaming and interactive commands?
2. Does the consumer policy need a different “gateway-safe” profile from the earlier wrapper-safe profile?
3. Should the public design separate gateway-safe command examples from future/advanced command examples?
4. Is the implementation currently too optimistic about command support relative to this narrower scope?
5. Does the current PR need a scope correction before more code is added?

### Answers

1. Yes.
   - There is still plenty of value in finite-output status, config inspection, docs search, help exploration, and non-interactive cron usage.

2. Yes.
   - Reusing the old wrapper policy wholesale would import assumptions that do not fit the gateway protocol well.
   - A gateway-safe starter profile should be narrower and more deliberate.

3. Yes.
   - That would help readers distinguish “first safe implementation” from “possible later expansion.”

4. Yes.
   - The current implementation direction and examples still imply broader support than is wise for the first pass.

5. Yes.
   - Before more code lands, the scope should be corrected in docs and implementation assumptions.

### More questions

6. Should the PR be tightened around a “finite-output non-interactive gateway” goal explicitly?
7. Should the review bar require that every example command in docs be actually intended for the first pass?
8. Does narrowing scope increase confidence enough to resume implementation work safely?

### Answers

6. Yes.
   - That framing would remove ambiguity and reduce accidental overreach.

7. Yes.
   - Otherwise the docs overpromise.

8. Yes.
   - Narrowing scope improves implementation confidence materially.

## Cycle 9

### Questions

1. After all this, what are the remaining unresolved questions that actually block good implementation?
2. Which questions are now answered well enough that they no longer need attention?
3. What should happen before another round of human review?

### Answers

1. The remaining blockers are:
   - explicit socket access group option and boundary
   - a single chosen response contract
   - explicit non-interactive/finite-output scope in docs and code
   - clear gateway-specific policy path and naming
   - at least initial test scaffolding

2. Answered well enough for now:
   - privilege escalation in the agent path is unacceptable
   - socket activation is the right architecture direction
   - `LoadCredential=` is the right credential mechanism for this design
   - JSON argv requests are preferable to shell strings
   - allow/deny rule semantics remain the right policy model

3. Before another human review:
   - narrow the scope explicitly
   - tighten names/options/boundaries
   - make protocol decisions concrete
   - add at least one meaningful automated test

### More questions

4. Are there any more important unanswered architectural questions right now?
5. If not, what does that imply about the next work item?

### Answers

4. No more major architectural questions stand out right now.
   - The remaining work is mostly implementation tightening and scope enforcement, not architectural discovery.

5. That implies the next work item should be implementation refinement, not further speculative design expansion.

## Cycle 10

### Questions

1. Can I still find more meaningful unanswered architectural questions?
2. Are the remaining concerns now mostly implementation details and quality gates?
3. What confidence level does this review cycle support now?

### Answers

1. No.
   - At this point, additional questions would mostly rephrase already identified concerns.
   - The architecture is sufficiently explored for the next step.

2. Yes.
   - The remaining work is about making the implementation match the clarified scope and boundaries.
   - The biggest missing pieces are protocol finalization, boundary cleanup, and tests.

3. Confidence is now higher on the path, though still not at merge-ready implementation confidence.
   - Architecture confidence: high
   - Scope confidence: high
   - Current implementation confidence: medium
   - Review readiness confidence: improved, but still dependent on another round of tightening and test coverage
