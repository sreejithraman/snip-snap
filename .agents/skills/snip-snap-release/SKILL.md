---
name: snip-snap-release
description: Prepare Snip Snap betas, promote a tested beta to stable, or recover a failed release delivery. Use when asked to release Snip Snap or investigate its publishing alerts.
---

# Snip Snap releases

Work from the repository root. Read [the release policy](../../../docs/adr/0011-version-and-release-policy.md) and the relevant flow in [the automation guide](../../../docs/release-automation-plan.md). Use the checked-in scripts and GitHub workflows for release mechanics. Infer the GitHub repository from `git remote -v`.

Select the path requested by the user. Investigating an alert authorizes inspection; publishing, promotion, or merging requires the corresponding user instruction. Carry existing authorization forward. Report workflow and release links, the source commit, marketing version, build number, and any incomplete step.

## Prepare a beta

1. Inspect `release.json`, `Config/Shared.xcconfig`, current public `main`, and remote stable tags. The planned marketing version must agree with Xcode and be newer than every published stable tag. Use `release_policy_load_manifest`, `release_policy_require_project_versions`, and `release_policy_require_new_version` from `scripts/release-policy.sh` under zsh to check it. The shared prepare job enforces these checks before either platform starts.
2. If a new version is needed, use `scripts/set-release.sh MAJOR.MINOR.PATCH`. Choose a patch for fixes or small polish and a minor for features before 1.0, following the release policy. Prepare the version change for review; merge only within the user's authorization. The merge starts a new beta candidate. Never hand-edit the build number.
3. Follow the candidate and delivery runs for that commit with `gh run list` and `gh run view`. A stale candidate is skipped; follow the newest tested `main`. For an unchanged current commit needing a fresh delivery, dispatch `beta-candidate.yml` on `main` within the user's authorization. The delivery workflow cannot be dispatched directly.
4. Verify both platform jobs and publishing finish successfully. Confirm the exact iOS build and its What to Test notes, the GitHub prerelease and release evidence, the Sparkle beta item, and the beta Homebrew cask match the delivery's version and build. Use [the release checklist](../../../docs/release-checklist.md) for signed release gates; before CloudKit work, read [the iCloud guide](../../../docs/agents/icloud-sync.md).

## Promote stable

1. Resolve the exact tested beta version and build from its release evidence. Check that delivery succeeded and satisfy the applicable [release checklist](../../../docs/release-checklist.md). Preserve the tested files and build number.
2. When promotion is authorized, dispatch `promote-stable.yml` on `main` with explicit `version` and `build` inputs. Follow the run and verify the stable GitHub assets, default Sparkle item, and stable Homebrew cask against the beta evidence and checksums.
3. Report the Apple handoff separately: select that existing TestFlight build and use the stable iOS release notes for What's New. App Store submission or release is a separate action; use the app-store-connect skill when available and requested.
4. After verifying publication, inspect the planned version on current `main`. If it is already newer, report that the next beta is ready. Otherwise prepare a follow-up PR for the next planned marketing version using `scripts/set-release.sh`, choosing the version from the planned work and release policy. This step prepares reviewable work and does not itself authorize merging. Report the PR and its merge status: the release is published, but the next beta remains blocked until a newer planned version reaches `main`.

## Recover a failed delivery

1. Read the failed run and job logs with `gh run view RUN_ID --log-failed`. Record which steps succeeded, the tested commit, version, build, and retained artifacts. An overall failure may still include a successful TestFlight upload.
2. If the failure says the version must be newer than an existing stable tag, prepare the next version through the beta path. Merge the change within authorization and follow the new delivery. Rerunning the old delivery uses its old commit and version, so it cannot repair this failure.
3. For a resumable publishing failure, verify the retained files and release evidence match the original commit, version, build, checksums, and published notes. Then use `gh run rerun RUN_ID --failed` within authorization to retry failed jobs. A rerun keeps its build number. Successful uploads and published files must be reused unchanged.
4. If files or notes differ, or the required original artifacts are unavailable, stop that retry and explain what is missing. Prepare a fresh tested candidate when a new delivery is needed; never replace a published asset, tag, or build number with different content.
