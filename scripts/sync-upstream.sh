#!/usr/bin/env bash
set -euo pipefail

# main is a clean upstream mirror; fork contains only our linear patch stack.
REMOTE="${VOICEINK_REMOTE:-origin}"
UPSTREAM_REMOTE="${VOICEINK_UPSTREAM_REMOTE:-upstream}"
MIRROR_BRANCH="${VOICEINK_MIRROR_BRANCH:-main}"
FORK_BRANCH="${VOICEINK_FORK_BRANCH:-fork}"
UPSTREAM_BRANCH="${VOICEINK_UPSTREAM_BRANCH:-main}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "$MIRROR_BRANCH" != "$FORK_BRANCH" ]] || fail 'Mirror and fork must be separate branches'
for branch in "$MIRROR_BRANCH" "$FORK_BRANCH" "$UPSTREAM_BRANCH"; do
  git check-ref-format "refs/heads/$branch" || fail "Invalid branch: $branch"
done

root="$(git rev-parse --show-toplevel)"
cd "$root"
[[ -z "$(git status --porcelain)" ]] || fail 'Run upstream sync in a clean checkout'

git fetch --no-tags "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
git fetch --no-tags "$REMOTE" "$MIRROR_BRANCH" "$FORK_BRANCH"

mirror_sha="$(git rev-parse "$REMOTE/$MIRROR_BRANCH")"
fork_sha="$(git rev-parse "$REMOTE/$FORK_BRANCH")"
upstream_sha="$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"

git merge-base --is-ancestor "$mirror_sha" "$upstream_sha" ||
  fail "$REMOTE/$MIRROR_BRANCH is not an ancestor of upstream; refusing to rewrite the mirror"
git merge-base --is-ancestor "$mirror_sha" "$fork_sha" ||
  fail "$REMOTE/$FORK_BRANCH is not based on the upstream mirror"
[[ "$(git rev-list --count --merges "$mirror_sha..$fork_sha")" == 0 ]] ||
  fail 'The fork patch stack contains merge commits; prepare a linear stack first'

if [[ "$mirror_sha" == "$upstream_sha" ]]; then
  echo "Upstream mirror and fork are already up to date at $upstream_sha and $fork_sha"
  exit 0
fi

git checkout --detach "$fork_sha"
if ! git rebase --onto "$upstream_sha" "$mirror_sha"; then
  git rebase --abort
  fail 'Upstream conflicts with the fork patches; neither remote branch was updated'
fi

new_fork_sha="$(git rev-parse HEAD)"
# Both leases name the exact refs we read. The atomic push prevents advancing
# main alone if a concurrent change or repository protection rejects fork.
git push --atomic \
  --force-with-lease="refs/heads/$MIRROR_BRANCH:$mirror_sha" \
  --force-with-lease="refs/heads/$FORK_BRANCH:$fork_sha" \
  "$REMOTE" \
  "$upstream_sha:refs/heads/$MIRROR_BRANCH" \
  "$new_fork_sha:refs/heads/$FORK_BRANCH"

echo "Synced $MIRROR_BRANCH to $upstream_sha and $FORK_BRANCH to $new_fork_sha"
