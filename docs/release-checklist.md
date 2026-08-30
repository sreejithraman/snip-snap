# iCloud Sync release checklist

## Automated gate

Run `scripts/test.sh` and `scripts/build-matrix.sh` from a clean checkout. The
matrix must build Mac, iPhone, iPad, and the embedded Share extension without
signing or private Apple settings.

The package suite fixes the public Snip Snap limits at 25 MiB per attachment
and 100 MiB total per snip. It tests the inclusive boundaries and one-byte
overflow, lists every incompatible file, blocks both setup and later sends,
and runs a generated 25 MiB upload, fresh-client download, hash check, bounded
cache install, and interrupted fetch retry. Run the failed-enable UI test on
both an iPhone and iPad Simulator.

## Physical iPhone

Run this short check once with a release-like signed build:

1. [ ] Sync a text snip and one attachment between the Mac and iPhone.
2. [ ] Confirm attachment metadata arrives before its payload and opening the attachment fetches it.
3. [ ] Save one item through the Share extension while the app is closed.
4. [ ] Make one offline same-text conflict and resolve it through the recovery comparison.
5. [ ] Relaunch both apps and confirm the final data remains correct.
