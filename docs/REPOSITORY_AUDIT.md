# Repository and local installation audit — 2026-11-11

## Git state

At the start of the audit, `chore/remove-chinese-ui` matched its live GitHub tracking branch at `ed9436e`. It was three commits ahead of `origin/main` (`7b65485`), with PR #45 open. The working copy additionally contained version 1.9.2/build 20 in `Resources/Info.plist` and an untracked Finder text clipping. The version change is preserved in this revision.

The local `backup/local-main-20261110` branch contains a different merge history and is retained. It must not be treated as disposable build output. No tracked environment files, indexes, node_modules or build products were found. GitHub Actions was enabled, but the API reported zero workflow runs at audit time; an enabled workflow is not evidence of passing CI.

## Raycast failure

The installed extension's source map declared bridge protocol **4**, with Stash, index-status and content commands. Its recorded source path was inside the removed temporary `build/raycast-pr/` checkout. The current tracked extension and installed app both declare protocol **2**. The extension therefore rejected the app as incompatible; it was not missing from Git.

`./build.sh raycast` now archives the old installed extension, installs dependencies, checks TypeScript and builds the compatible local extension. The previous compiled extension and its source maps are preserved under ignored `.local-archive/raycast/`. This does not port protocol-4-only commands into the protocol-2 app.

The validation-only npm build now explicitly uses `ray build -e dist -o dist`. The former `-e dist` selected the environment but still wrote into Raycast's installed extensions directory.

## Production installation and cleanup

- A shared signing resolver honors configured identities and otherwise attempts to reuse the installed app's certificate. Production refuses ad-hoc signing and unavailable identities.
- The installer verifies the new signature against the installed app's designated requirement before requesting exit. A signature mismatch cancels installation.
- AppKit requests normal termination, allowing the app to save its index, without Apple Events Automation permission. It waits up to 30 seconds and cancels if termination fails.
- A clean staged bundle replaces the old bundle on the same volume. The previous bundle is retained until the new app finishes launching. A replacement or launch failure triggers restoration.
- Settings, indexes and signing material are preserved. macOS still controls privacy grants; these changes preserve code identity rather than reset or bypass TCC.
- `scripts/clean.sh --dry-run` previews generated output; `--quick` removes generated bundles, Raycast output and website caches; `--full` additionally removes Swift caches. The old automatic force-ejection of arbitrary `/Volumes/dmg.*` mounts and deletion of legacy Sift user data were removed from the build/install path.
- The Chinese README is preserved in `docs/archive/` and its website test reference was updated. The Finder clipping is retained in ignored `.local-archive/obsolete/`.

## Validation

- Production installation: version 1.9.2/build 20 successfully replaced the running app and finished launching from `/Applications/Oil Find.app`. Strict signature validation and the installed app’s designated requirement passed. The active Raycast JavaScript declares protocol 2; its directory contains only the current command, manifest and assets.
- Shell syntax and `git diff --check`: passed.
- Installation lifecycle: 4 tests passed, covering clean replacement, signature rejection, quit failure and launch rollback.
- Existing open-core and uninstall checks: 5 tests passed.
- Raycast TypeScript, isolated distribution build and local extension installation: passed.
- Website: 205 tests passed; TypeScript passed.
- Full local Swift suite: completed with 7 failing test cases (14 failed assertions), in files not changed by this audit. These remain unresolved; the repository is not fully green.

Failing Swift cases:

1. `AITopicTests.testWatchImportsNewSessionAppendRenameAndDeletionWithoutManualRefresh`
2. `AITopicTests.testWatchRemovesArchivedTopicsAndRestoresUnarchivedTopicsWithoutManualRefresh`
3. `M26UITests.testQuickLookKeepsSearchFocusCaretAndIgnoresHeldKeys`
4. `MultipleSelectionTests.testShiftArrowsAndSelectAllBuildAMultipleSelectionThatDragsAsMove`
5. `WorkBuddyTopicTests.testWatchUpdatesDatabaseArchivesAndNewMessages`
6. `M17Tests.testCoverageCountsSamplesPersistenceCompactionAndIncrementalExclusion` — expected `pending`, received `missing`.
7. `M21CoreTests.testAPFSDeviceHistoryOfflineRemountAndEject`

Some cases depend on FSEvents, APFS history and window state. Their root causes have not been established by this audit; they should not all be dismissed as environment failures.
