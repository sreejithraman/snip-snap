# Maintainer release gate

- [ ] Confirm the signed Mac archive uses the production CloudKit container and environment.
- [ ] Run the maintainer-only signed Cloud Dev fake-versus-real transport contract.
- [ ] Run the [Production schema preflight](../CloudKit/README.md#opt-in-production-release-preflight) for the release target and save its passing report; set `SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED=YES` to enforce it in beta publishing scripts.

# TestFlight gate

1. [ ] Confirm the Apple agreements and App Store Connect roles are current.
2. [ ] Confirm the main app and Share extension App IDs use the same App Group.
3. [ ] Confirm only the main app uses the production CloudKit container.
4. [ ] Confirm the main app has Push Notifications enabled and the signed archive has the production push entitlement.
5. [ ] Review any required additive CloudKit rollout, retain retired fields, and manually promote only the reviewed changes. Rerun the Production schema preflight; do not automatically deploy unrelated Development changes.
6. [ ] Record the export-compliance answer without guessing it.
7. [ ] Review both privacy manifests against the final archive and linked code.
8. [ ] Run `scripts/testflight.sh archive` from the checked release commit.
9. [ ] Save the archive, dSYMs, commit, version, build, and upload result.
10. [ ] Add the processed build to the internal TestFlight group with clear What to Test notes.

# Physical iPhone release check

Run this short check once with a release-like signed build:

1. [ ] Sync a text snip and one attachment between the Mac and iPhone.
2. [ ] Confirm attachment metadata arrives before its payload and opening the attachment fetches it.
3. [ ] Close Snip Snap, then save one snip through the Share extension.
4. [ ] Edit the same snip’s text differently on the Mac and iPhone while both devices are offline, then resolve the conflict through the recovery comparison.
5. [ ] Relaunch both apps and confirm the final data remains correct.
