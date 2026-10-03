import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'sync-upstream.sh'
REAL_GIT = shutil.which('git')


class SyncUpstreamTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='voiceink-sync-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.upstream = self.root / 'upstream.git'
        self.origin = self.root / 'origin.git'
        self.upwork = self.root / 'upwork'
        self.work = self.root / 'work'
        for remote in (self.upstream, self.origin):
            self.git(self.root, 'init', '--bare', '--initial-branch=main', str(remote))
        self.git(self.root, 'clone', str(self.upstream), str(self.upwork))
        self.identity(self.upwork)
        (self.upwork / 'app.txt').write_text('upstream version 1\n')
        self.git(self.upwork, 'add', 'app.txt')
        self.git(self.upwork, 'commit', '-m', 'Initial upstream')
        self.old_main = self.git(self.upwork, 'rev-parse', 'HEAD')
        self.git(self.upwork, 'push', 'origin', 'main')
        self.git(self.upwork, 'push', str(self.origin), 'main')
        self.git(self.root, 'clone', str(self.origin), str(self.work))
        self.identity(self.work)
        self.git(self.work, 'remote', 'add', 'upstream', str(self.upstream))
        self.git(self.work, 'switch', '-c', 'fork')
        (self.work / 'custom.txt').write_text('personal customization\n')
        self.git(self.work, 'add', 'custom.txt')
        self.git(self.work, 'commit', '-m', 'Personal patch')
        self.git(self.work, 'push', 'origin', 'fork')
        self.old_fork = self.ref('fork')

    def git(self, cwd, *args):
        result = subprocess.run([REAL_GIT, '-C', str(cwd), *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            self.fail(f'git {args}: {result.stderr}')
        return result.stdout.strip()

    def identity(self, cwd):
        self.git(cwd, 'config', 'user.name', 'Fixture Author')
        self.git(cwd, 'config', 'user.email', 'fixture@example.invalid')
        self.git(cwd, 'config', 'commit.gpgsign', 'false')

    def ref(self, branch):
        return self.git(self.origin, 'rev-parse', f'refs/heads/{branch}')

    def advance(self):
        (self.upwork / 'app.txt').write_text('upstream version 2\n')
        self.git(self.upwork, 'add', 'app.txt')
        self.git(self.upwork, 'commit', '-m', 'Next upstream')
        self.git(self.upwork, 'push', 'origin', 'main')
        return self.git(self.upwork, 'rev-parse', 'HEAD')

    def run_sync(self, env=None):
        self.assertTrue(SCRIPT.is_file(), 'The rebase-based upstream sync script is missing')
        merged_env = dict(os.environ)
        for key in ('VOICEINK_REMOTE', 'VOICEINK_UPSTREAM_REMOTE', 'VOICEINK_MIRROR_BRANCH', 'VOICEINK_FORK_BRANCH', 'VOICEINK_UPSTREAM_BRANCH'):
            merged_env.pop(key, None)
        merged_env.update(env or {})
        return subprocess.run(['bash', str(SCRIPT)], cwd=self.work, env=merged_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def assert_unchanged(self):
        self.assertEqual(self.ref('main'), self.old_main)
        self.assertEqual(self.ref('fork'), self.old_fork)

    def test_successful_rebase_preserves_patch_and_advances_clean_mirror(self):
        upstream = self.advance()
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.ref('main'), upstream)
        new_fork = self.ref('fork')
        self.assertNotEqual(new_fork, self.old_fork)
        self.assertEqual(self.git(self.origin, 'rev-parse', f'{new_fork}^'), upstream)
        self.assertEqual(self.git(self.origin, 'show', f'{new_fork}:custom.txt'), 'personal customization')
        self.assertEqual(self.git(self.origin, 'show', f'{new_fork}:app.txt'), 'upstream version 2')
        self.assertEqual(self.git(self.origin, 'rev-list', '--count', '--merges', f'main..fork'), '0')

    def test_unchanged_upstream_keeps_existing_fork_sha(self):
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_unchanged()

    def test_conflict_aborts_without_publishing_either_branch(self):
        (self.work / 'app.txt').write_text('custom conflicting version\n')
        self.git(self.work, 'add', 'app.txt')
        self.git(self.work, 'commit', '-m', 'Conflicting patch')
        self.git(self.work, 'push', 'origin', 'fork')
        self.old_fork = self.ref('fork')
        self.advance()
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('CONFLICT', result.stdout)
        self.assert_unchanged()
        self.assertEqual(self.git(self.work, 'status', '--porcelain'), '')

    def test_contaminated_mirror_is_rejected(self):
        self.git(self.origin, 'update-ref', 'refs/heads/main', self.old_fork)
        self.old_main = self.old_fork
        self.advance()
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_unchanged()

    def test_fork_outside_mirror_ancestry_is_rejected(self):
        tree = self.git(self.work, 'rev-parse', 'HEAD^{tree}')
        self.old_fork = self.git(self.work, 'commit-tree', tree, '-m', 'Unrelated root')
        self.git(self.work, 'push', 'origin', f'{self.old_fork}:refs/fixture/unrelated')
        self.git(self.origin, 'update-ref', 'refs/heads/fork', self.old_fork)
        self.advance()
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_unchanged()

    def test_merge_commits_in_patch_stack_are_rejected(self):
        self.git(self.work, 'switch', '-c', 'feature')
        (self.work / 'feature.txt').write_text('feature\n')
        self.git(self.work, 'add', 'feature.txt')
        self.git(self.work, 'commit', '-m', 'Feature patch')
        self.git(self.work, 'switch', 'fork')
        self.git(self.work, 'merge', '--no-ff', '-m', 'Merge feature', 'feature')
        self.git(self.work, 'push', 'origin', 'fork')
        self.old_fork = self.ref('fork')
        self.advance()
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_unchanged()

    def test_dirty_checkout_is_rejected_without_publishing(self):
        self.advance()
        (self.work / 'app.txt').write_text('unfinished local work\n')
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_unchanged()
        self.assertEqual((self.work / 'app.txt').read_text(), 'unfinished local work\n')

    def test_concurrent_fork_push_is_preserved_and_main_update_is_atomic(self):
        self.advance()
        tree = self.git(self.work, 'rev-parse', 'HEAD^{tree}')
        concurrent = self.git(self.work, 'commit-tree', tree, '-p', self.old_fork, '-m', 'Concurrent personal patch')
        self.git(self.work, 'push', 'origin', f'{concurrent}:refs/fixture/concurrent')
        bindir = self.root / 'bin'
        bindir.mkdir()
        shim = bindir / 'git'
        shim.write_text('''#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == push && ! -e "$RACE_MARKER" ]]; then
  touch "$RACE_MARKER"
  "$REAL_GIT" --git-dir="$RACE_ORIGIN" update-ref refs/heads/fork "$RACE_SHA"
fi
exec "$REAL_GIT" "$@"
''')
        shim.chmod(0o755)
        result = self.run_sync({'PATH': f'{bindir}:{os.environ["PATH"]}', 'REAL_GIT': REAL_GIT, 'RACE_MARKER': str(self.root / 'raced'), 'RACE_ORIGIN': str(self.origin), 'RACE_SHA': concurrent})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.root / 'raced').exists(), result.stdout)
        self.assertEqual(self.ref('main'), self.old_main)
        self.assertEqual(self.ref('fork'), concurrent)


if __name__ == '__main__':
    unittest.main()
