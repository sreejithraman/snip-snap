# Build and run paths

- Run every real-app check through `scripts/run.sh`. It claims an isolated Dev slot and gives the app a Dev name, bundle ID, data store, and badge.
- Use `scripts/build.sh` only for compile checks. Treat app bundles in DerivedData or `/tmp` as build output and leave them unopened.
- Use `scripts/release.sh` for production builds.

# Open-source baseline

- Contributor baseline: a clean checkout and the documented tools, with no maintainer account, signing key, paid service, or machine-specific setting. Keep normal build and test paths usable within this baseline.
- Put machine-specific values in ignored local state or environment variables. Keep credentials, personal paths, machine IDs, and team IDs out of tracked files.
- License gate: before adding a dependency or asset, verify that its license permits use and redistribution, then add every required notice.
