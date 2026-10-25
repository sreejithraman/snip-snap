# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations and infer the repo from `git remote -v`.

## Conventions

- Create, read, edit, label, comment on, and close issues with `gh issue` commands.
- Do not treat pull requests as a request queue.
- When a skill says to publish to the issue tracker, create a GitHub issue.
- When a skill says to fetch a ticket, read its full body, comments, and labels.
- Apply the label named by `docs/agents/triage-labels.md`.

## Blocking links

Use GitHub's native issue dependencies when available. Create tickets that block other work first, then link each blocked ticket to the database IDs of its blockers. If the repository does not support native dependencies, add a `Blocked by: #<number>` line to the ticket body.

A ticket is ready only when all blockers have closed.

## Claim and complete work

Before starting a ticket, read any linked spec.
Respect an existing assignee. Claim an unassigned ticket with
`gh issue edit <number> --add-assignee @me`.

Follow the [project workflow](workflow.md) for implementation, acceptance, and
PR preparation. Link the issue from the PR. When the requested outcome is
delivered, record the result and verification evidence on the issue, then close
it unless the linked PR already closed it. If blocked, leave it open and record
the blocker and the next action.
