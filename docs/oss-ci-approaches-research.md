# OSS approaches to Apple app CI

Reviewed on 2026-09-05. Sources are public workflow files and the scripts they call, pinned to the commits read. This is a small sample, not a survey of all OSS. Workflow source shows intended work; it does not prove run times, cache hit rates, or branch protection settings. No SnipSnap workflow changed during this review.

## Findings

The clearest patterns in this sample are separate jobs for independent checks, canceling stale test runs, and sharing scripts or workflow definitions. A light PR matrix followed by a broad main matrix is a valid choice, but it is not a rule these projects all follow. Several use the same checks before and after merge.

| Project | What its source does | What SnipSnap can take from it |
| --- | --- | --- |
| Nuke, a Swift library | Five macOS job groups plus a separate Linux lint job; same checks on PRs and main; cancels stale runs. | Split work into groups of similar duration. Its simulator script is worth testing against our long iOS overhead. |
| Alamofire, a Swift library | Broad platform/Xcode matrix on PRs and master/hotfix pushes; path allowlist, cancellation, job timeouts. | Bound wasted work. Its library support matrix is broader than a small app needs. |
| CodeEdit, a Mac app | PR lint runs before Mac tests. A manual prerelease calls those same workflows before deploy. | Share definitions and gate release on tests. It does not support a claim that all OSS runs checks in parallel. |
| isowords, an iOS app and server | Independent macOS and Linux jobs on PRs and main; cancels stale runs. | Separate work that has no data dependency. The macOS job itself still runs client, preview builds, and server checks in sequence. |
| UTM, a Mac/iOS/visionOS app | Large platform/architecture matrices, cached native dependencies, archive artifacts passed to packaging jobs. | Reuse compatible build output across steps. Its scope and native dependencies make its full setup a poor template for SnipSnap. |

Sources and details follow.

## Nuke: balanced jobs and explicit simulator control

Nuke's CI groups Apple work into `ios-core`, `ios-ui`, `tvos`, `macos`, and `platforms`, with lint in a separate Linux job. It runs the same checks for PRs and main, cancels stale runs, appends an older-Xcode check to the short Mac group, and uploads failed result bundles. This workflow has no explicit Actions cache step. [Workflow source](https://github.com/kean/Nuke/blob/e7864feddd11572fc2eafe3a1f10e311d29bc5ae/.github/workflows/ci.yml)

Its script selects a simulator by UDID, boots it, and waits for boot to finish before tests. It keeps that selection for later calls within the same script. Tests use `-collect-test-diagnostics never`, `-parallel-testing-enabled NO`, and `-retry-tests-on-failure`; the script reports tests that passed only on retry as flaky. Compile-only checks use generic destinations. A comment attributes prior post-test hangs of up to 600 seconds to simulator diagnostics; that is the maintainer's explanation, not timing measured in this review. [CI script](https://github.com/kean/Nuke/blob/e7864feddd11572fc2eafe3a1f10e311d29bc5ae/.scripts/ci.sh)

For SnipSnap, compare simulator boot, test execution, and result collection separately before adopting these flags. Test explicit boot plus an exact UDID first, then test parallel execution and diagnostics as separate variables. The local `xcodebuild -help` says `-collect-test-diagnostics` controls verbose diagnostics, such as sysdiagnose, on failure; setting it to `never` loses that evidence. Keep result bundles and logs. Retries can add time and hide instability unless reported. This source gives us a concrete experiment, not proof of what caused SnipSnap's delays on successful runs.

## Alamofire: broad PR coverage with clear limits

Alamofire runs its broad platform/Xcode matrix on PRs and pushes to master/hotfix branches. It uses a path allowlist for workflows, `Package.swift`, `Source/**`, and `Tests/**`, cancels stale runs, and sets 10-minute Apple test job timeouts, with 20 minutes for CodeQL. It mixes hosted and self-hosted runners. [Workflow source](https://github.com/Alamofire/Alamofire/blob/0455bfb650893e86ad07ace16e5f2d36dadf46f4/.github/workflows/ci.yml)

This is evidence against calling a broad PR matrix inherently excessive. The right scope depends on what the project promises to support. SnipSnap should retain checks for its supported app targets without copying a library's whole compatibility matrix.

## CodeEdit: shared definitions, sequential checks

CodeEdit's PR workflow calls SwiftLint, then calls its test workflow through `needs: swiftlint`. The test workflow uses a self-hosted Mac and runs the app test script with `arm`; that script runs an arm64 Mac `xcodebuild clean test`. [PR workflow](https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/.github/workflows/CI-pull-request.yml), [test workflow](https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/.github/workflows/tests.yml), [test script](https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/.github/scripts/test_app.sh)

The manual prerelease workflow calls lint and tests again, then deploys only after they pass. This reuses definitions, not the result of an earlier PR run. Its source does not establish our proposed removal of duplicate main tests as an OSS norm. [Prerelease workflow](https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/.github/workflows/CI-pre-release.yml)

## isowords: parallel platform jobs, one iPhone simulator

The checked-in CI has independent macOS and Ubuntu jobs, runs on PRs and main, and cancels stale runs by ref. The macOS job runs `make test`; the Makefile runs iOS client tests on one iPhone simulator, builds preview apps, and tests the server. Ubuntu tests the server in a Swift container. No path filter or Actions cache step appears in this CI file. [Workflow source](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/.github/workflows/ci.yml), [Makefile](https://github.com/pointfreeco/isowords/blob/c727d3a7c49cf0c98f2fa4f24c562f81e30165f7/Makefile)

The file still names Xcode 15.3 and older runner images. Treat its job structure as an example, not its tool versions as current guidance or proof that it runs successfully today.

## UTM: cache dependencies and pass archives to packaging

UTM's workflow builds native dependency sysroots across platform/architecture matrices, caches them with keys derived from build scripts and patches, then builds app archives. Packaging jobs download archive artifacts from earlier jobs in that run. Signed Mac packaging runs for releases or an explicit test-release request; App Store uploads require a release event. These are same-run artifact handoffs, not reuse of a prior PR's test result. [Build workflow](https://github.com/utmapp/UTM/blob/b6f7475be54f9cb542c46b131319454b83489ced/.github/workflows/build.yml)

The workflow has push path exclusions for Markdown and `LICENSE`, but its `pull_request` trigger has no such exclusions. It is not an example of skipping docs-only PR builds. The workflow defaults to self-hosted Mac runners in the upstream repository and can select hosted runners elsewhere. [Build workflow](https://github.com/utmapp/UTM/blob/b6f7475be54f9cb542c46b131319454b83489ced/.github/workflows/build.yml)

## GitHub rules that affect the design

- Reusable workflows share job definitions through `workflow_call`; each call still runs work. Avoid confusing less YAML with fewer builds. [Reuse workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- A whole workflow skipped through path or branch filters can leave a required check pending. A stable final check should run even when app jobs skip, inspect their results, and fail when required work fails. [Required status checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)
- A `workflow_run` handoff can start protected delivery after validation. It needs an explicit success check and the tested commit SHA; the event's default SHA is not necessarily that commit. Keep SnipSnap's existing separation between cancelable candidate checks and delivery that must finish. [GitHub workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run), [existing repo review](github-actions-beta-concurrency-research.md)

## Proposed SnipSnap plan

1. Split PR checks into two parallel jobs: Mac/shared package and iOS. Preserve core tests, then inspect the iOS test build for the Share extension and privacy manifests. The current extra build also checks x86_64 and an iPhone-only device family; removing it from PRs moves that extra compile coverage to Beta candidate. This trades earlier detection of those failures for a shorter PR run. [Test script](../scripts/test.sh), [build matrix](../scripts/build-matrix.sh)
2. Measure iOS boot, tests, and result collection. Compare Nuke's explicit boot and XCTest settings in controlled runs; keep useful failure output.
3. Use one main validator. A simple fit is to make PR CI PR-only and leave the existing Beta candidate as the sole main validator. Share scripts or workflow definitions, and retain protected beta/stable delivery. This is two purposes, not a requirement for exactly two YAML files.
4. Skip app jobs for docs/feed-only changes while preserving a stable required result. Start with narrow exclusions; build/test configuration and unknown files should still trigger checks.
5. Keep broader compile coverage after merge only where the team accepts discovering those failures later. The examples do not establish a universal rule to move all compatibility checks out of PRs.

Parallel jobs can reduce elapsed PR time while using similar or greater runner minutes because setup repeats. Removing a duplicate build can save both. Cache only after measuring restore/upload cost; these sources do not prove that caching DerivedData would help SnipSnap. No new duration target follows from this research without actual before/after runs.
