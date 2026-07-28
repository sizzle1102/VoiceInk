# Building VoiceInk

This guide provides detailed instructions for building VoiceInk from source.

## Prerequisites

Before you begin, ensure you have:
- macOS 14.4 or later
- Xcode (latest version recommended)
- Swift (latest version recommended)
- Git (for cloning repositories)

## Quick Start with Makefile (Recommended)

The easiest way to build VoiceInk is using the included Makefile, which automates the entire build process including building and linking the whisper framework.

### Simple Build Commands

```bash
# Clone the repository
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk

# Build everything (recommended for first-time setup)
make all

# Or for development (build and run)
make dev
```

### Available Makefile Commands

- `make check` or `make healthcheck` - Verify all required tools are installed
- `make whisper` - Clone and build whisper.cpp XCFramework automatically
- `make setup` - Prepare the whisper framework for linking
- `make build` - Build the VoiceInk Xcode project
- `make local` - Build for local use (no Apple Developer certificate needed)
- `make run` - Launch the built VoiceInk app
- `make dev` - Build and run (ideal for development workflow)
- `make all` - Complete build process (default)
- `make clean` - Remove build artifacts and dependencies
- `make help` - Show all available commands

### How the Makefile Helps

The Makefile automatically:
1. **Manages Dependencies**: Creates a dedicated `~/VoiceInk-Dependencies` directory for all external frameworks
2. **Builds Whisper Framework**: Clones whisper.cpp and builds the XCFramework with the correct configuration
3. **Handles Framework Linking**: Sets up the whisper.xcframework in the proper location for Xcode to find
4. **Verifies Prerequisites**: Checks that git, xcodebuild, and swift are installed before building
5. **Streamlines Development**: Provides convenient shortcuts for common development tasks

This approach ensures consistent builds across different machines and eliminates manual framework setup errors.

---

## Building for Local Use (No Apple Developer Certificate)

If you don't have an Apple Developer certificate, use `make local`:

```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

This builds VoiceInk with ad-hoc signing using a separate build configuration (`LocalBuild.xcconfig`) that requires no Apple Developer account.

### How It Works

The `make local` command uses:
- `LocalBuild.xcconfig` to override signing and entitlements settings
- `VoiceInk.local.entitlements` (stripped-down, no CloudKit/keychain groups)
- `LOCAL_BUILD` Swift compilation flag for conditional code paths

Your normal `make all` / `make build` commands are completely unaffected.

### Install or Update Through GitHub Actions

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

Install the newest successful `main` artifact that is still available:

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

This dispatches `sync-upstream.yml`, merges `Beingpax/VoiceInk:main` into the
fork's `sync/upstream-main` branch, creates or updates the sync pull request,
and automatically merges it without bypassing repository protection rules.
After sync succeeds, the local updater reads the resulting remote `main` SHA,
dispatches `build-local-app.yml`, verifies that the matching run built that
exact SHA, downloads its artifact, signs it locally, and installs it.

The update command does not merge or push through the local Git checkout.
Local commits and working-tree changes cannot enter the sync or build.

Useful overrides:

```bash
VOICEINK_SIGN_IDENTITY="Your Certificate Name" make install
scripts/update-build-sign-install.sh --skip-sync
scripts/update-build-sign-install.sh --skip-install
scripts/update-build-sign-install.sh --dry-run
```

`--skip-sync` builds the current remote `main`. `--skip-install` keeps the
temporary work directory so the signed application can be inspected.

### Weekly Update

Install a weekly user LaunchAgent:

```bash
scripts/install-weekly-updater-launchagent.sh install
```

The LaunchAgent runs the same updater used by `make update-install` every
604800 seconds while your user session is active. It therefore performs the
remote sync, automatic PR merge, new Actions build, local signing, and
installation. Logs are written to
`~/Library/Logs/VoiceInk/update-build-sign-install.*.log`.

Remove it with:

```bash
scripts/install-weekly-updater-launchagent.sh uninstall
```

---

## Manual Build Process (Alternative)

If you prefer to build manually or need more control over the build process, follow these steps:

### Building whisper.cpp Framework

1. Clone and build whisper.cpp:
```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
./build-xcframework.sh
```
This will create the XCFramework at `build-apple/whisper.xcframework`.

### Building VoiceInk

1. Clone the VoiceInk repository:
```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
```

2. Add the whisper.xcframework to your project:
   - Drag and drop `../whisper.cpp/build-apple/whisper.xcframework` into the project navigator, or
   - Add it manually in the "Frameworks, Libraries, and Embedded Content" section of project settings

3. Build and Run
   - Build the project using Cmd+B or Product > Build
   - Run the project using Cmd+R or Product > Run

## Development Setup

1. **Xcode Configuration**
   - Ensure you have the latest Xcode version
   - Install any required Xcode Command Line Tools

2. **Dependencies**
   - The project uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for transcription
   - Ensure the whisper.xcframework is properly linked in your Xcode project
   - Test the whisper.cpp installation independently before proceeding

3. **Building for Development**
   - Use the Debug configuration for development
   - Enable relevant debugging options in Xcode

4. **Testing**
   - Run the test suite before making changes
   - Ensure all tests pass after your modifications

## Troubleshooting

If you encounter any build issues:
1. Clean the build folder (Cmd+Shift+K)
2. Clean the build cache (Cmd+Shift+K twice)
3. Check Xcode and macOS versions
4. Verify all dependencies are properly installed
5. Make sure whisper.xcframework is properly built and linked

For more help, please check the [issues](https://github.com/Beingpax/VoiceInk/issues) section or create a new issue.
