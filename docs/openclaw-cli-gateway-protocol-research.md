# openclaw CLI gateway protocol research

Date: 2026-03-20

## Goal

Decide how the client and socket-activated gateway should exchange requests and responses in a way that is secure, parseable, and compatible with the first implementation scope.

## Research findings

### 1. JSON argv requests remain the correct request format

The prior wrapper work and the gateway design both point to the same conclusion:
- shell command strings are too ambiguous
- argument boundaries must be preserved
- the gateway should never reconstruct or shell-parse a command string

Implication:
- requests should carry structured argv, not a human-formatted command line

Recommended request shape:

```json
{
  "agentId": "main",
  "argv": ["status", "--deep"]
}
```

### 2. Mixed response styles are a real source of confusion

Current implementation thinking still oscillates between:
- raw stdout/stderr passthrough for successful commands
- structured JSON for errors/denials

This weakens the protocol contract.

Implication:
- the gateway should pick one response model and use it consistently

### 3. Structured JSON responses are the stronger long-term contract

Why:
- parseable for automation
- easier to test
- clean distinction between denial, request parse failure, and underlying CLI failure
- stable enough to support future client formatting without changing the gateway boundary

Recommended response shape:

```json
{
  "ok": true,
  "exitCode": 0,
  "stdout": "...",
  "stderr": ""
}
```

Recommended denial shape:

```json
{
  "ok": false,
  "exitCode": 2,
  "error": "command denied by policy",
  "stderr": ""
}
```

### 4. Streaming commands do not fit neatly into the same contract

Commands like `logs --follow` challenge the buffered response model because they are open-ended and stream indefinitely.

Implication:
- first gateway pass should likely target finite-output commands only
- streaming support can be deferred or handled by a later protocol mode

### 5. The client should stay thin

The client should:
- serialize argv into the request shape
- send the request to the socket
- receive the response
- optionally pretty-print or unwrap for UX

The client should not:
- evaluate policy
- rewrite requests
- infer command semantics

## Recommended first-pass contract

### Request

- newline-delimited JSON request
- one request per connection
- required field: `argv`
- optional field: `agentId`

### Response

- newline-delimited JSON response envelope
- include:
  - `ok`
  - `exitCode`
  - `stdout`
  - `stderr`
  - optional `error`

### Exit codes

Recommended semantics:

- `0` for successful CLI execution
- `2` for policy denial or invalid request
- underlying CLI non-zero exit codes carried in the JSON payload and optionally used as the gateway process exit code too

## Questions still needing decisions

### Q1. Should the gateway process exit code always mirror the JSON `exitCode`?

Goal:
- keep shell usability and JSON parsing behavior aligned

Desired output:
- one documented exit-code policy

### Q2. Should the client unwrap successful JSON by default for human-facing commands?

Goal:
- balance parseability with operator usability

Desired output:
- decide whether the client prints raw JSON always or offers a default human-friendly mode

### Q3. Do we need a future streaming mode now, or should it be explicitly excluded from v1?

Current leaning:
- exclude from v1

Desired output:
- a clear statement in docs and implementation scope

## Recommendation summary

- Use JSON argv requests
- Use JSON response envelopes consistently
- Keep the client thin
- Exclude streaming commands from the first gateway pass
- Define a small, explicit exit-code contract
