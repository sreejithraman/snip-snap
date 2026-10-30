# Project workflow

Run commands from the repository root. [Build and signing setup](../building.md)
owns the commands, prerequisites, optional signing, and device setup.

## Checks and app access

- For contributor builds and tests, follow [Build and test](../building.md#build-and-test).
  That section also owns iOS UI-check selection and cadence.
- For optional Cloud Dev or physical-device checks, follow
  [Cloud Dev and physical-device builds](../building.md#cloud-dev-and-physical-device-builds).
- For release acceptance, use the [release checklist](../release-checklist.md).

The Mac delivery adapter is exposed by `scripts/run.sh describe --json` for
`showroom`. It starts and verifies this worktree's isolated Dev app.

## Review and delivery

The default standalone PR target and review base is `main` (`origin/main`
locally). A dependent PR targets its intended parent branch.

The required gate, `Tests and iOS compile check`, aggregates the Mac/shared and
iOS test jobs in [ci.yml](../../.github/workflows/ci.yml).

Merges into `main` that affect the watched paths in
[beta-candidate.yml](../../.github/workflows/beta-candidate.yml) start the beta
candidate pipeline. The [release ADR](../adr/0011-version-and-release-policy.md)
defines the source, versioning, and promotion policy.
