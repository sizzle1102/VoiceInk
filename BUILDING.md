# Building VoiceInk

## Requirements

- macOS 15.0 or later
- Xcode with Command Line Tools
- Git

## Fork Branches

- `upstream/main` is the remote-tracking ref for `Beingpax/VoiceInk:main`.
- `main` mirrors upstream and contains no personal patches.
- `fork` is this repository's default branch and the source of personal builds.
- `codex/*` branches start from the current `fork`. Pull requests target `fork`.

Before integrating a feature, rebase it onto the current `fork`, then merge
locally with `git merge --ff-only` and push `fork`. This preserves a linear
patch stack; GitHub's merge-commit button must not be used for these branches.

Upstream sync rebases published `fork` commits and can change their SHAs.
Fetch before starting work, preserve any local commits or uncommitted changes,
and rebase feature branches onto the new `origin/fork`. The updater operates
remotely and does not alter local work.

GitHub's default branch is `fork` so the scheduled sync and manually dispatched
build workflows remain available while `main` stays a clean upstream mirror.
The former mixed `main` history is retained in `legacy/main-before-fork-20261003`.

## Local Build

```bash
git clone --branch fork https://github.com/sizzle1102/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

`make local` prepares `whisper.xcframework` in `~/VoiceInk-Dependencies`, builds Release in `.local-build`, and copies `VoiceInk.app` to `~/Downloads`.

It uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity or falls back to ad-hoc signing when none or multiple are found.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync or automatic updates. Ad-hoc builds may require macOS permissions again after rebuilding.

## Install or Update Through GitHub Actions

For personal installs, keep the signing certificate local and let GitHub Actions
produce the unsigned/ad-hoc artifact. The local scripts download the artifact,
sign it with the persistent local identity, preserve a timestamped backup, and
replace `/Applications/VoiceInk.app`.

One-time setup:

1. Create a local Keychain code signing certificate, for example
   `VoiceInk Local Code Signing`.
2. Authenticate GitHub CLI:

```bash
gh auth login
gh auth refresh -h github.com -s workflow
```

Alternatively, create a fine-grained GitHub token for your fork with Actions
read/write access and store it in Keychain:

```bash
security add-generic-password \
  -a "$USER" \
  -s "VoiceInk GitHub Token" \
  -w "YOUR_GITHUB_TOKEN" \
  -U
```

Install the newest successful `fork` artifact that is still available:

```bash
make install
```

GitHub retains `VoiceInk-app` for one day. If no successful artifact is still
available, use `make update-install` to produce a new one.

Install an artifact that was downloaded manually:

```bash
make install ZIP="/path/to/VoiceInk-app.zip"
```

The ZIP override does not access GitHub and does not overwrite the repository
cache at `artifacts/VoiceInk-app.zip`.

Run the complete update cycle:

```bash
make update-install
```

This dispatches `sync-upstream.yml`, which fast-forwards the clean `main`
mirror to `Beingpax/VoiceInk:main` and rebases our linear `fork` patches on top.
Both refs are published atomically with leases naming the SHAs read before
rebasing. A conflict, concurrent push or repository protection stops the sync
without partially updating the remote branches.

After sync succeeds, the local updater reads the resulting remote `fork` SHA,
dispatches `build-local-app.yml` on `fork`, verifies that the matching run built
that exact SHA, downloads its artifact, signs it locally, and installs it.

The update command does not merge or push through the local Git checkout.
Local commits and working-tree changes cannot enter the sync or build.

Useful overrides:

```bash
VOICEINK_SIGN_IDENTITY="Your Certificate Name" make install
scripts/update-build-sign-install.sh --skip-sync
scripts/update-build-sign-install.sh --skip-install
scripts/update-build-sign-install.sh --dry-run
```

`--skip-sync` builds the current remote `fork`. Set `VOICEINK_BRANCH` with
`--skip-sync` to build a different app branch. `--skip-install` keeps the
temporary work directory so the signed application can be inspected.

## Weekly Update

Install a weekly user LaunchAgent:

```bash
scripts/install-weekly-updater-launchagent.sh install
```

The LaunchAgent runs the same updater used by `make update-install` every
604800 seconds while your user session is active. It therefore performs the
upstream mirror update, fork rebase, new Actions build, local signing, and
installation. Logs are written to
`~/Library/Logs/VoiceInk/update-build-sign-install.*.log`.

Remove it with:

```bash
scripts/install-weekly-updater-launchagent.sh uninstall
```

## Other Commands

- `make check` — verify required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make install` — install the newest available `fork` artifact
- `make update-install` — sync upstream, rebase `fork`, build and install
- `make dev` — build and launch `VoiceInk Dev.app`
- `make run` — launch `~/Downloads/VoiceInk.app`, or the first app found in DerivedData
- `make release` — create the signed release package
- `make release-setup` — configure release notarization credentials
- `make clean` — remove `~/VoiceInk-Dependencies`
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).
