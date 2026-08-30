# Maintainer release gate

- [ ] Run the maintainer-only signed Cloud Dev fake-versus-real transport contract.

# Physical iPhone release check

Run this short check once with a release-like signed build:

1. [ ] Sync a text snip and one attachment between the Mac and iPhone.
2. [ ] Confirm attachment metadata arrives before its payload and opening the attachment fetches it.
3. [ ] Close Snip Snap, then save one snip through the Share extension.
4. [ ] Edit the same snip’s text differently on the Mac and iPhone while both devices are offline, then resolve the conflict through the recovery comparison.
5. [ ] Relaunch both apps and confirm the final data remains correct.
