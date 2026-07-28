# VoiceInk Actions Install and Update

## Goal

Provide two safe local commands:

```bash
make install
make update-install
```

`make install` installs the newest available successful GitHub Actions build
without changing source code or starting a new build. `make update-install`
synchronizes the fork through GitHub Actions, automatically merges the sync PR,
starts a new build of the updated `main`, and installs exactly that build.

Both commands download an ad-hoc artifact, sign it with the persistent local
identity, preserve a timestamped backup, install it into `/Applications`, and
relaunch VoiceInk.

## Command interface

### Install an existing successful build

```bash
# Download and install the newest available successful main artifact.
make install

# Bypass GitHub and install a specific downloaded artifact.
make install ZIP=/path/to/VoiceInk-app.zip
```

Without `ZIP`, the command searches successful runs of
`build-local-app.yml` on `main` from newest to oldest and selects the first run
whose `VoiceInk-app` artifact has not expired. The downloaded outer ZIP is
written atomically to:

```text
<repository>/artifacts/VoiceInk-app.zip
```

The visible `artifacts/` directory is ignored by Git. A `ZIP` override is
read-only input and does not overwrite the repository cache.

### Synchronize, build, and install

```bash
make update-install
```

This command:

1. dispatches `sync-upstream.yml` with automatic merge enabled;
2. waits for the sync workflow to finish successfully;
3. reads the resulting `main` head SHA from GitHub;
4. dispatches `build-local-app.yml` for `main` with a unique request ID;
5. waits for the matching run and verifies that it built the expected SHA;
6. downloads that run's `VoiceInk-app` artifact;
7. signs and installs it locally.

The command no longer fetches, checks out, merges, commits, or pushes through
the local Git checkout. Local commits and working-tree state cannot enter the
sync or build.

## GitHub Actions synchronization

Extend `sync-upstream.yml` with a boolean `auto_merge` input for
`workflow_dispatch`. Scheduled runs keep `auto_merge: false` behavior and only
create or update the sync PR.

When `auto_merge: true`, the workflow:

1. starts from a clean `origin/main`;
2. merges `Beingpax/VoiceInk:main` into `sync/upstream-main`;
3. exits successfully if there are no upstream changes;
4. otherwise pushes the sync branch and creates or updates its PR;
5. confirms that the PR head still matches the SHA produced by this run;
6. merges the PR into `main` using a merge commit;
7. fails if GitHub refuses the merge because of a conflict, required review,
   failed protection rule, or insufficient token permission.

The workflow does not bypass repository protections with administrator
privileges. It has only the existing repository-scoped `contents: write` and
`pull-requests: write` permissions.

Changes made with `GITHUB_TOKEN` do not implicitly trigger another workflow.
That is intentional: the local updater explicitly dispatches
`build-local-app.yml` only after the sync workflow succeeds.

## Components

### Shared GitHub and installation library

Extract reusable shell functions from `scripts/update-build-sign-install.sh`
into a sourceable library. The library owns:

- GitHub repository inference and token discovery;
- workflow dispatch and bounded polling;
- successful-run and non-expired-artifact discovery;
- artifact download and nested ZIP extraction;
- signing identity validation;
- local signing, strict verification, backup, rollback, and relaunch.

Executable scripts keep argument parsing and orchestration. The library has no
top-level side effects.

### Installer script

Add `scripts/install-app.sh [ZIP]` as the installer entry point used by
`make install`:

- with a ZIP argument, it installs that local archive without network access;
- without a ZIP argument, it downloads the latest available successful
  `build-local-app.yml` artifact for `main`, caches it in `artifacts/`, and
  installs it.

It supports the existing environment conventions:

- `VOICEINK_BRANCH`, defaulting to `main`;
- `VOICEINK_WORKFLOW`, defaulting to `build-local-app.yml`;
- `VOICEINK_ARTIFACT_NAME`, defaulting to `VoiceInk-app`;
- `VOICEINK_SIGN_IDENTITY`, defaulting to
  `VoiceInk Local Code Signing`;
- `VOICEINK_APP_DESTINATION`, defaulting to
  `/Applications/VoiceInk.app`;
- `VOICEINK_RELAUNCH`, defaulting to `1`.

### Update script

Refactor `scripts/update-build-sign-install.sh` so it orchestrates the remote
sync and exact new build described above. Existing options that remain
meaningful, such as `--skip-sync`, `--skip-install`, `--keep-workdir`,
`--dry-run`, and `--no-relaunch`, keep their behavior. `--skip-sync` builds the
current remote `main`; it does not use the local checkout's HEAD.

### Makefile and documentation

Add `install` to `.PHONY`, preserve `update-install`, document `ZIP=...`, and
describe the distinction in `make help` and `BUILDING.md`.

## Local artifact validation and installation

Both install paths use the same flow:

1. Validate required commands, credentials when network access is needed, the
   input file, and the configured signing identity before touching the
   installed app.
2. Create a temporary staging directory.
3. Unpack the outer artifact ZIP and require exactly one top-level
   `*.app.zip`.
4. Unpack the nested ZIP and require `VoiceInk.app` with bundle identifier
   `com.prakashjoshipax.VoiceInk`.
5. Clear extended attributes in staging.
6. Sign recursively with
   `codesign --force --deep --sign <persistent identity>`.
7. Run `codesign --verify --deep --strict --verbose=2` before installation.
8. Quit the current VoiceInk process and fail without changing the installation
   if it cannot be stopped.
9. Move an existing destination to
   `VoiceInk.app.backup.<YYYYMMDDHHMMSS>`.
10. Copy the staged bundle with `ditto`, clear destination attributes, and
    strictly verify it again.
11. If copying or post-install verification fails, remove only the incomplete
    destination and restore the backup.
12. Relaunch unless `VOICEINK_RELAUNCH=0`.
13. Remove staging files and retain the successful backup.

No command uses `codesign --options runtime`, because library validation can
prevent the locally signed bundle from loading `VoiceInk.debug.dylib`.

## Failure boundaries

- Sync failure: do not dispatch a build or touch the installed application.
- Build failure or SHA mismatch: do not download or install an older artifact.
- Latest-install mode with no non-expired artifact: fail with instructions to
  use `make update-install`.
- Download or archive validation failure: keep the current installation.
- Signing failure: keep the current installation.
- Installation or post-install verification failure: restore the backup.
- Relaunch failure: report it without deleting the successfully installed app
  or its backup.
- The source ZIP is never modified or deleted.

## Testing

Use shell tests with temporary directories and fake external commands where
real GitHub, Keychain, `/Applications`, or GUI state must not change.

Tests cover:

- latest mode selects the newest successful run with a non-expired artifact;
- latest mode ignores expired artifacts and never silently selects a failed
  run;
- `ZIP=...` performs no GitHub request and does not overwrite the cache;
- the cache path is `<repository>/artifacts/VoiceInk-app.zip`;
- update mode waits for successful sync before dispatching the build;
- update mode verifies the built SHA and downloads from that exact run;
- sync failure prevents build dispatch;
- signing uses the configured identity without `--options runtime`;
- nested extraction and bundle-identifier validation;
- pre-install and post-install signature verification;
- failed post-install verification restores the previous app;
- both Make targets forward their documented arguments;
- existing updater cleanup and signing regressions remain covered.
