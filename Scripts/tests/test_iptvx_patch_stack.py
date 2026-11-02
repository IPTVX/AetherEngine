"""Regression tests for ordered fork maintenance, independent of Apple tooling."""

# Failure modes:
# - Both overlapping corrections are absent; the successor cannot apply first.
# - A partial/drifted successor hides an older snapshot or leaves partial edits.
# - Repeated apply mutates corrected sources, the host index, or unrelated files.
# - A missing snapshot or invalid path is silently accepted.

import contextlib
import difflib
import importlib.util
import io
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "iptvx-patch-stack.py"
SPEC = importlib.util.spec_from_file_location("patch_stack", SCRIPT)
stack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stack)


class PatchStackTests(unittest.TestCase):
    """Exercise real Git patch checks against minimal overlapping source fixtures."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="iptvx-stack-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        self.source = self.root / "source.txt"
        self.source.write_text("before\n")
        self.source.chmod(0o755)
        self.patches = [("OLD", "old.patch"), ("NEW", "new.patch")]
        self.write_patch("old.patch", "source.txt", "before\n", "delay\n")
        self.write_patch("new.patch", "source.txt", "delay\n", "delay + read-ahead\n")
        with (self.root / "new.patch").open("a") as patch:
            patch.write("diff --git a/regression.txt b/regression.txt\nnew file mode 100644\n--- /dev/null\n+++ b/regression.txt\n@@ -0,0 +1 @@\n+delivery regression\n")

    def write_patch(self, name, path, before, after):
        """Store a normal text patch whose contexts overlap its predecessor."""
        difference = "".join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile="a/" + path, tofile="b/" + path))
        (self.root / name).write_text(difference)

    def run_stack(self, apply=False):
        with contextlib.redirect_stdout(io.StringIO()):
            stack.apply_stack(self.root, self.patches, apply)

    def assert_unchanged(self, before):
        after = {str(p.relative_to(self.root)): (p.read_bytes(), stat.S_IMODE(p.stat().st_mode))
                 for p in self.root.rglob("*") if p.is_file() and ".git" not in p.parts}
        self.assertEqual(before, after)

    def snapshot(self):
        return {str(p.relative_to(self.root)): (p.read_bytes(), stat.S_IMODE(p.stat().st_mode))
                for p in self.root.rglob("*") if p.is_file() and ".git" not in p.parts}

    def test_single_active_patch_applies_without_withdrawn_successor(self):
        self.patches = self.patches[:1]
        (self.root / "new.patch").unlink()
        with self.assertRaisesRegex(stack.PatchFailure, "Missing correction: OLD"):
            self.run_stack()
        self.run_stack(apply=True)
        self.assertEqual(self.source.read_text(), "delay\n")
        self.assertFalse((self.root / "regression.txt").exists())
        corrected = self.snapshot()
        self.run_stack()
        self.run_stack(apply=True)
        self.assert_unchanged(corrected)

    def test_both_missing_check_is_read_only_then_apply_is_ordered_and_idempotent(self):
        before = self.snapshot()
        with self.assertRaisesRegex(stack.PatchFailure, "Missing correction: OLD, NEW"):
            self.run_stack()
        self.assert_unchanged(before)

        self.run_stack(apply=True)
        self.assertEqual(self.source.read_text(), "delay + read-ahead\n")
        self.assertEqual((self.root / "regression.txt").read_text(), "delivery regression\n")
        corrected = self.snapshot()
        self.run_stack()
        self.run_stack(apply=True)
        self.assert_unchanged(corrected)

    def test_old_applied_new_missing_is_completed_without_reapplying_old(self):
        self.source.write_text("delay\n")
        with self.assertRaisesRegex(stack.PatchFailure, "Missing correction: NEW"):
            self.run_stack()
        self.run_stack(apply=True)
        self.assertEqual(self.source.read_text(), "delay + read-ahead\n")
        self.run_stack()

    def test_overlapping_corrected_stack_checks_after_reverse_peeling(self):
        self.source.write_text("delay + read-ahead\n")
        (self.root / "regression.txt").write_text("delivery regression\n")
        direct = stack.git(self.root, "apply", "--reverse", "--check", str(self.root / "old.patch"))
        self.assertNotEqual(direct.returncode, 0)
        self.run_stack()

    def test_partial_successor_fails_without_mutation(self):
        self.source.write_text("delay + read-ahead\n")
        before = self.snapshot()
        with self.assertRaisesRegex(stack.PatchFailure, "Port required"):
            self.run_stack(apply=True)
        self.assert_unchanged(before)

    def test_later_conflict_does_not_apply_earlier_missing_patch(self):
        (self.root / "regression.txt").write_text("unexpected user edit\n")
        before = self.snapshot()
        with self.assertRaisesRegex(stack.PatchFailure, "Port required: NEW"):
            self.run_stack(apply=True)
        self.assert_unchanged(before)

    def test_drift_in_older_correction_is_not_accepted_as_an_applied_stack(self):
        self.source.write_text("unported upstream implementation\n")
        before = self.snapshot()
        with self.assertRaisesRegex(stack.PatchFailure, "Port required: OLD"):
            self.run_stack(apply=True)
        self.assert_unchanged(before)

    def test_missing_patch_fails_before_editing(self):
        (self.root / "new.patch").unlink()
        before = self.snapshot()
        with self.assertRaisesRegex(stack.PatchFailure, "Missing maintained patch"):
            self.run_stack(apply=True)
        self.assert_unchanged(before)

    def test_unrelated_files_permissions_and_host_index_are_preserved(self):
        unrelated = self.root / "user-untracked.txt"
        unrelated.write_bytes(b"user data\n")
        unrelated.chmod(0o640)
        stack.git(self.root, "add", "source.txt")
        index = (self.root / ".git/index").read_bytes()
        self.run_stack(apply=True)
        self.assertEqual(unrelated.read_bytes(), b"user data\n")
        self.assertEqual(stat.S_IMODE(unrelated.stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), 0o755)
        self.assertEqual((self.root / ".git/index").read_bytes(), index)
        self.run_stack()

    def test_deleted_file_is_not_lost_from_transactional_net_diff(self):
        (self.root / "removed.txt").write_text("obsolete\n")
        with (self.root / "new.patch").open("a") as patch:
            patch.write("diff --git a/removed.txt b/removed.txt\ndeleted file mode 100644\n--- a/removed.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-obsolete\n")
        self.run_stack(apply=True)
        self.assertFalse((self.root / "removed.txt").exists())
        self.run_stack()


if __name__ == "__main__":
    unittest.main()
