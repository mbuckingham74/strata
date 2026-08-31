# Engineering Workflow

This is a personal hobby application. Optimize for understandable code, visible user value, and proportional use of time, compute, and tokens. High assurance is appropriate only when the actual risk justifies it.

## One Thing at a Time

* Perform only the objective explicitly requested.
* Do not add adjacent improvements, cleanup, refactoring, hardening, or future work.
* Do not begin a second task until the user explicitly requests it.
* Do not overwhelm the user with multiple decisions or next steps.
* If a decision is required, ask one concise question and stop.

## Scope

* Make the smallest coherent change that satisfies the request.
* Prefer existing patterns and straightforward implementations.
* Do not introduce abstractions, coordinators, protocols, state machines, generalized infrastructure, or speculative flexibility unless the current requirement demonstrably needs them.
* Do not redesign working code merely because another design appears cleaner.
* If completing the task requires materially expanding its scope, stop and obtain approval.
* Preserve unrelated user changes.

## Prompt Length and Context Discipline

Prompts must be as concise as possible while remaining unambiguous. Conciseness is determined by relevance, not by an arbitrary line or word limit.

Include only:

* the requested outcome;
* the allowed change surface;
* invariants that directly affect this task;
* proportional verification;
* stop conditions; and
* commit or push authority.

Do not include:

* completed milestone history unless it changes a current decision;
* information the agent can directly obtain from the repository;
* repeated versions of the same requirement;
* exhaustive prohibition lists when a clear allowlist is sufficient;
* command transcripts or exhaustive report templates;
* unrelated architecture background; or
* speculative future requirements.

State every requirement once. Reference files, commits, and existing documentation instead of reproducing their contents.

Before using a prompt, remove every sentence that would not change the agent’s implementation, verification, or authority. A task prompt describes the current task; it does not retell the project.

## Verification

Verification must be proportional to the change.

Before running a check, determine:

1. What changed that could invalidate existing evidence?
2. What concrete failure could this check detect?

If neither question has a meaningful answer, do not run the check.

Default verification rules:

* Run focused tests for the behavior changed.
* Use static inspection for documentation, naming, path, metadata, and project-configuration changes.
* A read-only audit does not invalidate previous test evidence.
* Do not repeat a passing test suite when relevant production code has not changed since that run.
* Do not test untouched subsystems merely because their tests exist.
* Do not run Python regression tests when Python or its contract was untouched.
* Do not run real model inference unless the worker, protocol, model integration, launch path, or output validation changed.
* Do not run a full regression suite by default.
* Do not run verification solely to repeat evidence already obtained by another agent.

A full regression, real integration run, universal build, or other machine-disruptive verification requires explicit user approval before it begins. Reserve these checks for meaningful integration, release, or broad behavioral changes.

Feature work: add/update tests for the feature and run focused verification. A full regression is not required to commit/push each task.

Milestone gate: run the full regression once after the milestone’s planned features are complete, before closing the milestone.
Previously obtained evidence remains valid until a relevant change invalidates it.

## Agents and Handoffs

* Use one capable agent for a bounded task whenever practical.
* Match model capability and reasoning effort to the actual difficulty of the task.
* Do not assign a second agent merely to repeat checks already completed successfully.
* A handoff or independent review must add a specific new capability, risk assessment, or evidence.
* Do not create separate implementation, audit, QA, and commit stages by default.
* The implementing agent may commit after the required focused verification when authorized.
* Do not stage, commit, push, or modify remote state without explicit authority.

## Reporting

Keep successful reports concise:

* outcome;
* files or behavior changed;
* focused verification performed;
* remaining blocker, if any; and
* Git state when relevant.

Do not provide command transcripts, exhaustive test inventories, repeated assurances, or milestone history unless requested.

Give detailed evidence only for a failure, blocker, destructive action, or disputed finding.

## Stop Conditions

Stop and ask before proceeding when:

* the request is materially ambiguous;
* scope would expand;
* verification would be disproportionately expensive;
* a machine-disruptive check appears necessary;
* unrelated changes would be overwritten;
* new architecture is being considered; or
* the work would exceed the user’s stated authority or budget.

The user’s current explicit instruction overrides this policy.


## Xcode build artifacts

- Use Xcode's default DerivedData unless a task specifically requires isolation.
- If isolation is required, use a path outside the repository, e.g. `/tmp/StrataDerivedData`.
- Never use repo-local `build/`, `DerivedData/`, `.build/`, or similar directories for Xcode output.
- Do not stop work merely because the known ignored `build/` directory exists.

