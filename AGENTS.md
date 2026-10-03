# VoiceInk fork workflow

- `main` is an exact upstream mirror. Put personal changes on `fork` or on a
  `codex/*` branch created from the current `fork`.
- `fork` is the GitHub default branch and the source of the local app artifacts.
  Pull requests target `fork`, never `main` or the upstream repository.
- Keep the personal patch stack linear: rebase a feature onto the current
  `fork`, integrate with `git merge --ff-only`, then push. Do not introduce
  merge commits into `fork`.
- Upstream updates use `scripts/sync-upstream.sh` in a clean checkout. It checks
  mirror ancestry, rebases the patch stack and publishes both refs atomically
  with explicit SHA leases. Resolve conflicts in a separate branch and validate
  the result before publishing.
- Preserve unrelated local work. Remote sync may rewrite `fork` SHAs; fetch and
  inspect the graph before updating a local checkout or feature branch.
- Run the shell tests under `tests/` for installer or sync changes. The upstream
  Swift UI tests live under `Tests/VoiceInkUITests/`.
- Preserve the upstream app sources and build behavior unless a task explicitly
  requires a personal app modification. The current personal changes cover
  Actions builds, upstream sync and local artifact installation.
