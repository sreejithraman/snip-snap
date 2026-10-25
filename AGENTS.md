# Build and run paths

- Run every real-app check through `scripts/run.sh`. It claims an isolated Dev slot and gives the app a Dev name, bundle ID, data store, and badge.
- Use `scripts/build.sh` only for compile checks. Treat app bundles in DerivedData or `/tmp` as build output and leave them unopened.
- Use `scripts/release.sh` for production builds.

# Open-source baseline

- Contributor baseline: a clean checkout and the documented tools, with no maintainer account, signing key, paid service, or machine-specific setting. Keep normal build and test paths usable within this baseline.
- Put machine-specific values in ignored local state or environment variables. Keep credentials, personal paths, machine IDs, and team IDs out of tracked files.
- License gate: before adding a dependency or asset, verify that its license permits use and redistribution, then add every required notice.

## Agent skills

### Project workflow

Before implementation, acceptance checks, review, or PR preparation, read
[the workflow guide](docs/agents/workflow.md).

### Issue tracker

For ticket work, read [the GitHub issue guide](docs/agents/issue-tracker.md).

### Triage labels

Before changing triage labels, read [the label mapping](docs/agents/triage-labels.md).

### Domain docs

Before exploring or naming domain concepts, read [the domain guide](docs/agents/domain.md).

### Releases

When preparing a beta, promoting stable, or recovering a failed delivery, use [the project release skill](.agents/skills/snip-snap-release/SKILL.md).

### iCloud sync

Before diagnosing or changing iCloud sync, running live CloudKit checks, or
reporting sync test coverage, read [the iCloud guide](docs/agents/icloud-sync.md).
