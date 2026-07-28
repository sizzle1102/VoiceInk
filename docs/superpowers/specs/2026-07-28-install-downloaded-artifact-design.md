# Install Downloaded VoiceInk Artifact

## Goal

Provide a safe local command for signing and installing a VoiceInk GitHub
Actions artifact that has already been downloaded.

The supported entry points are:

```bash
make install
make install ZIP=/path/to/VoiceInk-app.zip
scripts/install-downloaded-app.sh
scripts/install-downloaded-app.sh /path/to/VoiceInk-app.zip
```

With no explicit argument, the script reads:

```text
<repository>/artifacts/VoiceInk-app.zip
```

The entire `artifacts/` directory is ignored by Git so downloaded application
bundles cannot be committed accidentally. The installer never modifies or
deletes the input archive.

## Scope

The command installs an existing artifact only. It does not:

- dispatch or download a GitHub Actions build;
- synchronize Git branches;
- create a signing certificate;
- reset macOS privacy permissions;
- remove successful timestamped backups.

Those responsibilities remain with the existing updater or the user.

## Components

### Installer script

Add `scripts/install-downloaded-app.sh`. It accepts zero or one positional ZIP
path and supports the existing local-install environment conventions:

- `VOICEINK_SIGN_IDENTITY`, defaulting to `VoiceInk Local Code Signing`;
- `VOICEINK_APP_DESTINATION`, defaulting to `/Applications/VoiceInk.app`;
- `VOICEINK_RELAUNCH`, defaulting to `1`.

The script resolves its repository root from its own location, not from the
caller's current directory. This makes both direct invocation and `make
install` behave consistently.

### Make target

Add `install` to the Makefile. With `ZIP` set, the target forwards that path as
the script's single argument. Without `ZIP`, it invokes the script without an
argument and therefore uses the repository-local default.

### Documentation and ignore rule

Add `artifacts/` to `.gitignore` and document both invocation forms in
`BUILDING.md` and `make help`.

## Installation flow

1. Validate required commands, the input file, and the configured signing
   identity before touching the installed application.
2. Create a temporary staging directory.
3. Unpack the outer GitHub artifact ZIP and require exactly one top-level
   `*.app.zip`.
4. Unpack the nested ZIP and require `VoiceInk.app` with bundle identifier
   `com.prakashjoshipax.VoiceInk`.
5. Clear extended attributes in staging.
6. Sign recursively with the configured persistent identity using
   `codesign --force --deep --sign`. Do not enable Hardened Runtime.
7. Run `codesign --verify --deep --strict --verbose=2` before installation.
8. Quit the current VoiceInk process and fail without changing the installation
   if it cannot be stopped.
9. Move an existing destination to
   `VoiceInk.app.backup.<YYYYMMDDHHMMSS>`.
10. Copy the signed staged bundle with `ditto`, clear extended attributes at the
    destination, and strictly verify it again.
11. If copying or post-install verification fails, remove only the incomplete
    destination and restore the timestamped backup.
12. Relaunch VoiceInk unless `VOICEINK_RELAUNCH=0`.
13. Remove temporary staging files. Retain the successful backup.

No command uses `codesign --options runtime`, because library validation can
prevent the locally signed bundle from loading `VoiceInk.debug.dylib`.

## Errors and safety

- Archive validation and signing failures occur before the installed app is
  moved.
- The source ZIP is read-only from the installer's perspective.
- Destructive cleanup is limited to the validated temporary directory or an
  incomplete configured application destination.
- The backup is restored when installation does not complete successfully.
- Paths are quoted throughout and may contain spaces.
- An inaccessible signing private key produces the original `codesign` error
  and aborts before replacement.

## Testing

Add a shell regression test that uses temporary directories and fake macOS
commands where system state must not be changed. The tests cover:

- the default archive path is `<repository>/artifacts/VoiceInk-app.zip`;
- an explicit ZIP path overrides the default;
- nested artifact extraction reaches `VoiceInk.app`;
- signing uses the configured identity and never passes `--options runtime`;
- the installed bundle is verified before relaunch;
- a failed post-install verification restores the previous application;
- the Makefile exposes both the default and `ZIP=...` invocation forms.

Existing updater tests continue to run unchanged.
