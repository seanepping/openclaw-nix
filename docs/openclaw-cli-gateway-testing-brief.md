# openclaw CLI gateway testing brief

Date: 2026-03-20

## Goal

Define the minimum automated testing needed before the socket-activated gateway implementation should be considered ready for another serious review.

## Why this matters

The gateway crosses the most sensitive boundary in this feature:
- secrets become available inside the gateway service
- the agent gains a callable path into a secret-bearing execution context
- socket permissions become a local security boundary

That means implementation confidence should not rely on manual testing alone.

## Minimum test layers

### 1. Module build/eval tests

Purpose:
- catch broken module definitions and package outputs early

Needed:
- module parse/eval test
- package build for client and gateway scripts

### 2. NixOS VM integration test

Purpose:
- verify the actual socket/service/credential boundary in a realistic environment

Minimum scenarios:

1. allowed command succeeds for the agent user
2. denied command fails cleanly
3. agent user cannot read secret files directly
4. gateway service receives credentials and can export them to the child CLI process
5. unrelated user cannot access the socket
6. malformed JSON request fails closed
7. response contract is as documented

### 3. Scope/behavior test

Purpose:
- ensure the first-pass command set matches the intended finite-output, non-interactive scope

Scenarios:
- a finite-output exact allow command
- a `prefix` command such as `docs <query>`
- a `prefixArgGlob` config-get path
- a `help` exploration request
- one explicitly unsupported interactive or streaming command should fail predictably

## Useful test doubles

A mock `openclaw` binary should be used first.

The mock should:
- echo argv it receives
- indicate whether the expected secret env vars are present
- optionally simulate non-zero exit codes
- never require real external services

That lets the test prove the gateway boundary before real OpenClaw integration details are involved.

## Open questions for the test implementation

### Q1. Should the gateway client be tested via the installed command name or by invoking the underlying client script directly?

Desired answer:
- prefer the installed command name, because that is the real consumer-facing interface

### Q2. Should the first VM test validate journald behavior or leave logging review for manual inspection?

Desired answer:
- manual inspection is acceptable for first pass, but the test should at least ensure secrets are not printed in the normal client response

### Q3. Should there be a dedicated negative test for socket directory permissions as well as socket file permissions?

Desired answer:
- yes if practical, because the directory path is part of the boundary

## Success criteria before next review

The gateway implementation should not come back for another serious human review until:
- at least one meaningful VM/integration test exists
- the test proves secret non-exposure to the agent user
- the test proves policy denial behavior
- the test proves the chosen request/response contract
