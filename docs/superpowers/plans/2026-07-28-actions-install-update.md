# VoiceInk Actions Install and Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `make install` install the latest available successful Actions artifact and make `make update-install` remotely sync upstream, auto-merge the sync PR, build the resulting `main`, and install that exact build.

**Architecture:** Move reusable GitHub API, artifact, signing, and transactional installation functions into a side-effect-free shell library. Keep `install-app.sh` and `update-build-sign-install.sh` as small orchestrators, and extend `sync-upstream.yml` with request correlation and an opt-in auto-merge path.

**Tech Stack:** Bash 3.2-compatible shell, GNU Make, GitHub Actions YAML, GitHub REST API via `curl`, GitHub CLI inside Actions, macOS `codesign`, `security`, `ditto`, `plutil`, and shell regression tests.

## Global Constraints

- Default branch is `main`.
- Default build workflow is `build-local-app.yml`.
- Default sync workflow is `sync-upstream.yml`.
- Default artifact is `VoiceInk-app`.
- Default cache is `<repository>/artifacts/VoiceInk-app.zip`.
- Default signing identity is `VoiceInk Local Code Signing`.
- Default destination is `/Applications/VoiceInk.app`.
- Required bundle identifier is `com.prakashjoshipax.VoiceInk`.
- Never pass `codesign --options runtime`.
- Never include local commits or working-tree state in remote sync or build.
- Never overwrite a user-supplied `ZIP=...` archive.
- Preserve the old application until the signed replacement passes strict verification.
- Do not bypass GitHub repository protections with administrator privileges.

---

### Task 1: Extract the reusable local installation library

**Files:**
- Create: `scripts/lib/voiceink-install-common.sh`
- Create: `tests/voiceink-install-common-test.sh`
- Modify: `scripts/update-build-sign-install.sh`
- Modify: `tests/update-build-sign-install-signing-test.sh`
- Modify: `tests/update-build-sign-install-test.sh`

**Interfaces:**
- Produces: `voiceink_log`, `voiceink_die`, `voiceink_require_command`, `voiceink_repo_root`, `voiceink_read_token`, `voiceink_infer_github_repo`, `voiceink_github_api`, `voiceink_github_download`, `voiceink_assert_signing_identity`, `voiceink_artifact_download_url`, `voiceink_extract_artifact_zip`, `voiceink_sign_app`, `voiceink_quit_existing_app`, and `voiceink_install_app`.
- `voiceink_extract_artifact_zip ARCHIVE WORKDIR BUNDLE_ID` prints the staged `VoiceInk.app` path.
- `voiceink_sign_app APP_PATH SIGN_IDENTITY` signs and strictly verifies the staged bundle.
- `voiceink_install_app APP_PATH DESTINATION BUNDLE_ID PROCESS_NAME RELAUNCH` performs backup, copy, post-install verification, rollback, and optional relaunch.

- [ ] **Step 1: Write the failing common-library test**

Create `tests/voiceink-install-common-test.sh` that sources the missing library,
replaces `xattr`, `codesign`, `osascript`, `pgrep`, `pkill`, and `open` with
recording functions, and asserts:

```bash
voiceink_sign_app "$TEST_APP/VoiceInk.app" "VoiceInk Local Code Signing"

rg -Fx -- "--sign" "$CALLS"
rg -Fx -- "VoiceInk Local Code Signing" "$CALLS"
if rg -Fx -- "--options" "$CALLS"; then
  echo "must not enable hardened runtime" >&2
  exit 1
fi
```

Add a destination test where the second `codesign --verify` call fails. Assert
that `voiceink_install_app` returns non-zero, the old destination marker is
restored, and no `open` call is recorded.

- [ ] **Step 2: Run the new test and verify RED**

Run:

```bash
bash tests/voiceink-install-common-test.sh
```

Expected: FAIL because `scripts/lib/voiceink-install-common.sh` does not exist.

- [ ] **Step 3: Implement the common library**

Move the matching implementations from the updater into
`scripts/lib/voiceink-install-common.sh`. Add bundle validation after nested ZIP
extraction:

```bash
actual_bundle_id="$(plutil -extract CFBundleIdentifier raw \
  "$app_path/Contents/Info.plist")"
[[ "$actual_bundle_id" == "$bundle_id" ]] ||
  voiceink_die "Unexpected bundle identifier: $actual_bundle_id"
```

Implement transactional post-install verification. If copying, `xattr`, or
verification fails, delete only the incomplete configured destination and move
the timestamped backup back into place.

- [ ] **Step 4: Make the updater sourceable**

Source the library relative to the updater's own path and replace the
unconditional final call with:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

Move option parsing into `parse_args` so sourcing does not consume the caller's
arguments. Update existing tests to source the real updater rather than a
temporary copy created with `sed '$d'`.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run:

```bash
bash tests/voiceink-install-common-test.sh
bash tests/update-build-sign-install-signing-test.sh
bash tests/update-build-sign-install-test.sh
```

Expected: all three scripts print their pass message and exit 0.

- [ ] **Step 6: Commit Task 1**

```bash
git add scripts/lib/voiceink-install-common.sh \
  scripts/update-build-sign-install.sh \
  tests/voiceink-install-common-test.sh \
  tests/update-build-sign-install-signing-test.sh \
  tests/update-build-sign-install-test.sh
git commit -m "refactor: share VoiceInk install workflow"
```

---

### Task 2: Add latest-artifact and local-ZIP installation modes

**Files:**
- Modify: `scripts/lib/voiceink-install-common.sh`
- Create: `scripts/install-app.sh`
- Create: `tests/install-app-test.sh`
- Modify: `.gitignore`
- Modify: `Makefile`

**Interfaces:**
- Consumes: Task 1 common-library signing and installation functions.
- Produces: `voiceink_find_latest_available_artifact REPO WORKFLOW BRANCH ARTIFACT WORKDIR`, which prints `RUN_ID<TAB>HEAD_SHA<TAB>DOWNLOAD_URL`.
- Produces: `voiceink_download_artifact_zip DOWNLOAD_URL DESTINATION`, which replaces the cache atomically only after a complete download.
- Produces: `scripts/install-app.sh [ZIP]`.

- [ ] **Step 1: Write the failing latest-artifact selection test**

In `tests/install-app-test.sh`, source `scripts/install-app.sh`, override
`voiceink_github_api` so the workflow-runs request returns three successful runs
newest-first, and artifact requests return:

```text
run 30: VoiceInk-app expired=true
run 29: unrelated artifact expired=false
run 28: VoiceInk-app expired=false
```

Assert that:

```bash
IFS=$'\t' read -r run_id head_sha download_url < <(
  voiceink_find_latest_available_artifact \
    "sizzle1102/VoiceInk" "build-local-app.yml" "main" \
    "VoiceInk-app" "$TEST_WORKDIR"
)
[[ "$run_id" == "28" ]]
[[ "$head_sha" == "sha-28" ]]
[[ "$download_url" == "https://api.example/artifacts/28.zip" ]]
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
bash tests/install-app-test.sh
```

Expected: FAIL because `scripts/install-app.sh` and
`voiceink_find_latest_available_artifact` do not exist.

- [ ] **Step 3: Implement latest artifact discovery and atomic caching**

Query:

```text
GET /repos/{repo}/actions/workflows/{workflow}/runs
    ?branch={branch}&status=success&per_page=30
```

For each returned run in API order, query its artifacts and select the first
matching artifact with `expired == false`. Download to
`artifacts/.VoiceInk-app.zip.download.<pid>` and rename it to
`artifacts/VoiceInk-app.zip` only after `curl` succeeds.

- [ ] **Step 4: Implement `scripts/install-app.sh` orchestration**

With one argument, set `archive_path` to that path and do not read a GitHub
token or call a GitHub function. With no argument, discover and download the
latest artifact. In both modes:

```bash
app_path="$(voiceink_extract_artifact_zip \
  "$archive_path" "$workdir" "$BUNDLE_ID")"
voiceink_sign_app "$app_path" "$SIGN_IDENTITY"
voiceink_install_app \
  "$app_path" "$APP_DESTINATION" "$BUNDLE_ID" \
  "$APP_PROCESS_NAME" "$RELAUNCH"
```

Reject more than one positional argument with exit status 2.

- [ ] **Step 5: Add Make and ignore integration**

Add:

```make
.PHONY: install

install:
	@if [ -n "$(ZIP)" ]; then \
		scripts/install-app.sh "$(ZIP)"; \
	else \
		scripts/install-app.sh; \
	fi
```

Add `artifacts/` to `.gitignore` and document both forms in `make help`.

- [ ] **Step 6: Extend tests for the local override**

Run the install orchestrator with a temporary ZIP path while recording helper
calls. Assert that the call log contains no GitHub API or download operation,
that the supplied path reaches extraction unchanged, and that a sentinel cache
file remains byte-identical.

- [ ] **Step 7: Run focused tests and verify GREEN**

Run:

```bash
bash tests/install-app-test.sh
make -n install
make -n install ZIP="/tmp/VoiceInk app.zip"
git check-ignore -v --no-index artifacts/VoiceInk-app.zip
```

Expected: shell tests pass, both Make invocations call `scripts/install-app.sh`
with the documented shape, and `.gitignore` owns the cache path.

- [ ] **Step 8: Commit Task 2**

```bash
git add .gitignore Makefile scripts/install-app.sh \
  scripts/lib/voiceink-install-common.sh tests/install-app-test.sh
git commit -m "feat: install latest VoiceInk artifact"
```

---

### Task 3: Move upstream synchronization and exact-build orchestration to Actions

**Files:**
- Modify: `.github/workflows/sync-upstream.yml`
- Modify: `scripts/update-build-sign-install.sh`
- Create: `tests/update-build-sign-install-remote-test.sh`
- Create: `tests/sync-upstream-workflow-test.sh`

**Interfaces:**
- Consumes: Task 1 common library and Task 2 atomic artifact cache.
- Produces: `voiceink_dispatch_workflow REPO WORKFLOW REF REQUEST_ID INPUT_JSON OUTPUT_FILE`.
- Produces: `voiceink_wait_for_workflow_run REPO WORKFLOW BRANCH REQUEST_ID EXPECTED_SHA WORKDIR`, which prints the completed run ID.
- Produces: `voiceink_remote_branch_sha REPO BRANCH WORKDIR`, which prints the GitHub branch head SHA.
- Extends `sync-upstream.yml` inputs with `request_id: string` and
  `auto_merge: boolean`.

- [ ] **Step 1: Write the failing remote-orchestration test**

Source the updater, replace remote helpers with functions that append to
`$CALLS`, and run `main --no-relaunch`. Return `sync-run-1` from the sync wait,
`merged-main-sha` from `voiceink_remote_branch_sha`, and `build-run-2` from the
build wait.

Assert the exact ordered subsequence:

```text
dispatch:sync-upstream.yml:main:auto_merge=true
wait:sync-upstream.yml:sync-request
remote-sha:main
dispatch:build-local-app.yml:main:request_id=build-request
wait:build-local-app.yml:build-request:merged-main-sha
download:build-run-2
sign
install
```

Add a second case where the sync wait fails and assert no build dispatch,
download, signing, or installation record exists.

- [ ] **Step 2: Run the remote test and verify RED**

Run:

```bash
bash tests/update-build-sign-install-remote-test.sh
```

Expected: FAIL because the updater still calls local `sync_from_upstream`.

- [ ] **Step 3: Add request correlation and opt-in merge to the sync workflow**

Add:

```yaml
run-name: Sync upstream ${{ inputs.request_id || github.run_number }}

on:
  workflow_dispatch:
    inputs:
      request_id:
        description: Unique id used by local automation to find this run
        required: false
        type: string
      auto_merge:
        description: Merge the generated sync PR
        required: false
        default: false
        type: boolean
```

After creating or updating the PR, obtain its number and head SHA. When
`inputs.auto_merge` is true, run:

```bash
gh pr merge "$pr_number" \
  --repo "$GH_REPO" \
  --merge \
  --match-head-commit "$sync_head_sha" \
  --delete-branch
```

Do not pass `--admin` or `--auto`. A protection rule or required review must
make the workflow fail rather than silently weaken repository policy.

- [ ] **Step 4: Write and run the workflow contract test**

Create `tests/sync-upstream-workflow-test.sh` asserting that the workflow
contains the `request_id` and `auto_merge` inputs, `--match-head-commit`, and
`--merge`, while rejecting `--admin`.

Run:

```bash
bash tests/sync-upstream-workflow-test.sh
```

Expected: PASS after the workflow change.

- [ ] **Step 5: Replace local sync with remote workflow orchestration**

Delete calls to local fetch, checkout, merge, and push. Generate distinct
request IDs:

```bash
sync_request_id="sync-install-$(date -u '+%Y%m%dT%H%M%SZ')"
build_request_id="build-install-$(date -u '+%Y%m%dT%H%M%SZ')"
```

Dispatch and wait for sync unless `--skip-sync`, read remote `main` SHA,
dispatch the build, and require the matching build run's `head_sha` to equal
that SHA. Download only from the returned build run ID and update
`artifacts/VoiceInk-app.zip` atomically.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run:

```bash
bash tests/update-build-sign-install-remote-test.sh
bash tests/sync-upstream-workflow-test.sh
bash tests/update-build-sign-install-test.sh
bash tests/update-build-sign-install-signing-test.sh
```

Expected: all four scripts pass and no test executes a real GitHub, Git,
Keychain, `/Applications`, or GUI mutation.

- [ ] **Step 7: Commit Task 3**

```bash
git add .github/workflows/sync-upstream.yml \
  scripts/update-build-sign-install.sh \
  tests/update-build-sign-install-remote-test.sh \
  tests/sync-upstream-workflow-test.sh
git commit -m "feat: sync and build VoiceInk through Actions"
```

---

### Task 4: Document and verify the complete workflow

**Files:**
- Modify: `BUILDING.md`
- Modify: `docs/superpowers/specs/2026-07-28-actions-install-update-design.md`
- Test: all shell tests under `tests/`

**Interfaces:**
- Consumes: Tasks 1-3 final CLI behavior.
- Produces: user-facing instructions for `make install`,
  `make install ZIP=...`, and `make update-install`.

- [ ] **Step 1: Update user documentation**

Document:

```bash
make install
make install ZIP="/path/to/VoiceInk-app.zip"
make update-install
```

Explain that `install` reuses an existing successful build, while
`update-install` syncs and merges upstream remotely, builds the resulting
`main`, and installs that exact build. State that artifacts expire after one
day and `make update-install` is the recovery when no downloadable success
remains.

- [ ] **Step 2: Run all repository shell tests**

Run:

```bash
for test_script in tests/*.sh; do
  bash "$test_script"
done
```

Expected: every test exits 0.

- [ ] **Step 3: Run static verification**

Run:

```bash
bash -n scripts/lib/voiceink-install-common.sh
bash -n scripts/install-app.sh
bash -n scripts/update-build-sign-install.sh
git diff --check
git status --short --untracked-files=all
```

Expected: shell syntax and whitespace checks pass. The downloaded
`artifacts/VoiceInk-app.zip` is ignored and absent from status.

- [ ] **Step 4: Run safe dry runs**

Run:

```bash
make -n install
make -n install ZIP="/tmp/VoiceInk app.zip"
scripts/update-build-sign-install.sh --dry-run
```

Expected: Make prints the correct installer calls. The updater validates local
configuration and reports the remote sync/build plan without dispatching a
workflow or touching `/Applications`.

- [ ] **Step 5: Inspect the final diff**

Run:

```bash
git diff --stat HEAD
git diff -- . ':!docs/superpowers/plans/*'
```

Confirm that only the workflows, installer/updater scripts, tests, Makefile,
ignore rule, and documentation described in the spec changed.

- [ ] **Step 6: Commit Task 4**

```bash
git add BUILDING.md \
  docs/superpowers/specs/2026-07-28-actions-install-update-design.md
git commit -m "docs: explain VoiceInk install commands"
```

- [ ] **Step 7: Report the remaining live boundary**

Do not dispatch sync, merge a PR, replace `/Applications/VoiceInk.app`, or
launch the GUI during automated verification. Report that the first real
`make install` and `make update-install` remain user-authorized live smoke
tests.
