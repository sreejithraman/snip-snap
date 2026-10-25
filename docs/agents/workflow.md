# Project workflow

Run commands from the repository root. [Build and signing setup](../building.md)
owns the commands, prerequisites, optional signing, and device setup.

## Build, run, and check

- Use `scripts/build.sh` for compile checks and `scripts/run.sh` for real-app
  checks. The run path claims this worktree's isolated Dev slot. Keep the
  build-output bundles unopened, as required by [AGENTS.md](../../AGENTS.md).
- Use `scripts/test.sh` for the unsigned contributor test suite. The `--mac-only`
  and `--ios-only` groups match [CI](../../.github/workflows/ci.yml). The aggregate
  check, `Tests and iOS compile check`, requires both groups to pass.
- Follow the [iOS workflow checks](../building.md#build-and-test) through
  `scripts/run.sh --ios-simulator` for changed iOS interactions. Select the
  affected workflow tests and check the actual interaction in the Dev app.
- Keep the contributor path usable without signing credentials or a maintainer
  account. For optional Cloud Dev or physical-device checks, follow the
  [signing and device guide](../building.md#cloud-dev-and-physical-device-builds).
  Before sync work or sync coverage claims, read the
  [iCloud guide](icloud-sync.md).

## Acceptance and handoff

Use `tdd` for test-driven behavior changes and `verify` for acceptance through
the workflow the user will use. Compile and unit-test results cover only the
behavior those checks exercise. Report the tested revision, commands, outcomes,
evidence paths, and any missing device or service proof.

Use `showroom` to show work the user can inspect or try. For app changes, use
the isolated Dev app and identify its slot and access requirements. The run
entry point exposes the repo's delivery adapter with
`scripts/run.sh describe --json`; the shared skill owns its use. For docs,
link the changed files. Reuse [existing test recipes](../building.md) and the
[release checklist](../release-checklist.md) for their applicable scope.

In T3 Code, use the shared terminal, collaborative browser, and Device panel
when their tools are available. Discover live capabilities before relying on
them. If a needed integration is missing, name the gap and provide a practical
fallback the user can access.

## Review and delivery

For a standalone change, target `main` and review the full change from its
merge-base with `origin/main`. For a dependent PR, use its intended parent
branch as the base. Include committed, staged, unstaged, and new files in local
review scope. Honor an explicitly supplied review base.

Use `review-fix-loop` for independent assessment and fixes before handing off
behavior or agent-procedure changes. When `pr` will review the same complete
scope before publication, let it own that loop once. Use `pr` for a single PR,
`gh-stack` for dependent layers, and `merge` when landing is requested. Preserve
an existing stack's parent relationships. Inspect the installed `gh stack`
version and help before relying on its supported operations. CI's required
test gate is defined in [ci.yml](../../.github/workflows/ci.yml).

For parallel work or ticket dependencies, use `orchestration` and its shared
model policy when available. Use `goal-swarm` only for an explicit goal or
swarm request. These routes refer to shared skills; their installation and
host configuration are separate from this repo's documentation.

For betas, stable promotion, or failed delivery recovery, use the
[project release skill](../../.agents/skills/snip-snap-release/SKILL.md).
Follow the [release ADR](../adr/0011-version-and-release-policy.md); release
builds use `scripts/release.sh`. Merges into `main` that affect the watched paths
in [beta-candidate.yml](../../.github/workflows/beta-candidate.yml) start the beta
candidate pipeline. Setup or PR preparation alone does not authorize merging
or publishing.
