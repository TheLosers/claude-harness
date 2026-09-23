"""Exercise hook decisions only; payload commands are never executed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOKS = ROOT / "modules/gates/hooks"


class HooksTest(unittest.TestCase):
    def setUp(self):
        # Keep read-first fixtures outside /tmp, which the hook deliberately exempts.
        self.tmp = tempfile.TemporaryDirectory(prefix=".hook-test-", dir=ROOT / "tests")
        self.base = Path(self.tmp.name)
        self.state = self.base / "state"
        self.state.mkdir()
        self.conf = self.base / "gates.conf"
        self.conf.write_text(
            f"STATE_DIR='{self.state}'\nLOG_FILE='{self.base / 'events.jsonl'}'\n"
            "PROD_DB_HOSTS='prod-db\\.example\\.com'\n"
        )
        self.env = {**os.environ, "CLAUDE_HARNESS_CONF": str(self.conf)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_hook(self, hook, payload, env=None):
        raw = payload if isinstance(payload, str) else json.dumps(payload)
        return subprocess.run(
            ["/bin/bash", str(HOOKS / hook)], input=raw, text=True,
            capture_output=True, env=env or self.env, check=False,
        )

    def bash(self, command):
        return self.run_hook("bash-guard.sh", {"tool_name": "Bash", "cwd": str(self.base),
                                               "tool_input": {"command": command}})

    def assert_denied(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")

    def assert_allowed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('"permissionDecision": "deny"', result.stdout)

    def marker(self, name, target="any"):
        path = self.state / (name + "-approved")
        path.write_text(target)
        return path

    def edit(self, path, new, old="", tool="Edit", transcript=None):
        payload = {"tool_name": tool, "tool_input": {"file_path": str(path),
                   "new_string": new, "old_string": old, "content": new}}
        if transcript:
            payload["transcript_path"] = str(transcript)
        return self.run_hook("edit-guard.sh", payload)

    def test_db_read_allowed(self):
        self.assert_allowed(self.bash("psql -h dev-db.example.com -c 'SELECT 1'"))

    def test_db_write_denied(self):
        self.assert_denied(self.bash("psql -c 'DELETE FROM widgets'"))

    def test_production_read_denied_even_with_marker(self):
        marker = self.marker("db-write")
        self.assert_denied(self.bash("psql -h prod-db.example.com -c 'SELECT 1'"))
        self.assertTrue(marker.exists())

    def test_marker_consumed_once(self):
        marker = self.marker("db-write", "widgets")
        command = "psql -c 'DELETE FROM widgets'"
        self.assert_allowed(self.bash(command))
        self.assertFalse(marker.exists())
        self.assert_denied(self.bash(command))

    def test_expired_marker_denied(self):
        marker = self.marker("db-write")
        old = time.time() - 1200
        os.utime(marker, (old, old))
        self.assert_denied(self.bash("psql -c 'DELETE FROM widgets'"))

    def test_wrong_target_denied(self):
        self.marker("db-write", "other_table")
        self.assert_denied(self.bash("psql -c 'DELETE FROM widgets'"))

    def test_pr_review_read_allowed(self):
        self.assert_allowed(self.bash("gh api repos/example/demo/pulls/42/reviews"))

    def test_pr_review_write_denied(self):
        self.assert_denied(self.bash("gh pr review 42 --approve"))

    def test_pr_api_write_denied(self):
        self.assert_denied(self.bash("gh api repos/example/demo/pulls/42/reviews -f body=review"))

    def test_pr_merge_denied(self):
        self.assert_denied(self.bash("gh pr merge 42"))

    def test_pr_number_boundary(self):
        self.marker("pr-merge", "42")
        self.assert_denied(self.bash("gh pr merge 142"))
        self.assert_allowed(self.bash("gh pr merge 42"))

    def test_browser_name_denied(self):
        self.assert_denied(self.bash("pkill 'Google Chrome'"))

    def test_non_browser_kill_allowed(self):
        self.assert_allowed(self.bash("pkill example-test-worker"))

    def test_browser_approved(self):
        marker = self.marker("browser-kill")
        self.assert_allowed(self.bash("pkill 'Google Chrome'"))
        self.assertFalse(marker.exists())

    def test_multiple_pids_checked_separately(self):
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        fake_ps = bin_dir / "ps"
        fake_ps.write_text("#!/bin/sh\n[ \"$2\" = 22222 ] && printf 'Google Chrome\\n'\n")
        fake_ps.chmod(0o755)
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env.get("PATH", "/usr/bin:/bin")
        self.assert_denied(self.bash("kill 11111 22222"))

    def test_invalid_number_marker_denied(self):
        self.marker("pr-merge", ".*")
        self.assert_denied(self.bash("gh pr merge 42"))

    def test_review_approval_consumed(self):
        marker = self.marker("pr-review", "42")
        self.assert_allowed(self.bash("gh pr review 42 --approve"))
        self.assertFalse(marker.exists())

    def test_review_approval_still_checks_merge(self):
        self.marker("pr-review", "42")
        self.assert_denied(self.bash("gh pr review 42 --approve; gh pr merge 42"))

    def test_merge_approval_still_checks_browser(self):
        self.marker("pr-merge", "42")
        self.assert_denied(self.bash("gh pr merge 42; pkill 'Google Chrome'"))

    def test_disabled_gate(self):
        with self.conf.open("a") as stream:
            stream.write("DISABLED_GATES='pr-merge'\n")
        self.assert_allowed(self.bash("gh pr merge 42"))

    def test_skip_added_denied(self):
        self.assert_denied(self.edit(self.base / "example.test.ts", "it.skip('case', () => {})"))

    def test_skip_removed_allowed(self):
        self.assert_allowed(self.edit(self.base / "example.test.ts", "it('case', () => {})", "it.skip('case', () => {})"))

    def test_read_first_missing_denied(self):
        (self.base / "existing.ts").write_text("export const value = 1;\n")
        self.assert_denied(self.edit(self.base / "new.ts", "export {};", tool="Write"))

    def test_empty_folder_allowed(self):
        self.assert_allowed(self.edit(self.base / "new.ts", "export {};", tool="Write"))

    def test_existing_file_write_allowed(self):
        existing = self.base / "existing.ts"
        existing.write_text("export {};\n")
        self.assert_allowed(self.edit(existing, "export {};", tool="Write"))

    def test_nested_read_not_same_directory(self):
        (self.base / "existing.ts").write_text("export {};\n")
        transcript = self.base / "transcript.jsonl"
        transcript.write_text(json.dumps({"type": "tool_use", "name": "Read", "input": {
            "file_path": str(self.base / "nested" / "existing.ts")}}) + "\n")
        self.assert_denied(self.edit(self.base / "new.ts", "export {};", tool="Write", transcript=transcript))

    def test_multiple_skip_patterns_denied(self):
        for name, content in (("example_test.py", "@pytest.mark.skip"),
                              ("ExampleTest.kt", "@Disabled"),
                              ("example.spec.js", "xdescribe('case', () => {})")):
            with self.subTest(name=name):
                self.assert_denied(self.edit(self.base / name, content))

    def test_read_first_spaced_json_allowed(self):
        existing = self.base / "existing.ts"
        existing.write_text("export {};\n")
        transcript = self.base / "transcript.jsonl"
        transcript.write_text(json.dumps({"message": {"content": [
            {"type": "tool_use", "name": "Read", "input": {"file_path": str(existing)}}
        ]}}) + "\n")
        self.assert_allowed(self.edit(self.base / "new.ts", "export {};", tool="Write", transcript=transcript))

    def test_approval_does_not_skip_later_gate(self):
        self.marker("db-write")
        self.assert_denied(self.bash("psql -c 'DELETE FROM widgets'; gh pr merge 42"))

    def test_malformed_payload_blocks(self):
        for hook in ("bash-guard.sh", "edit-guard.sh"):
            with self.subTest(hook=hook):
                result = self.run_hook(hook, "not json")
                self.assertEqual(result.returncode, 2)

    def test_missing_jq_blocks(self):
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        (bin_dir / "cat").symlink_to("/bin/cat")
        for hook in ("bash-guard.sh", "edit-guard.sh"):
            with self.subTest(hook=hook):
                result = self.run_hook(hook, {}, {**self.env, "PATH": str(bin_dir)})
                self.assertEqual(result.returncode, 2)

    def test_invalid_payload_shapes_block(self):
        for hook, key in (("bash-guard.sh", "command"), ("edit-guard.sh", "file_path")):
            for value in (None, 42, [], {}, ""):
                with self.subTest(hook=hook, value=value):
                    self.assertEqual(self.run_hook(hook, {"tool_input": {key: value}}).returncode, 2)


if __name__ == "__main__":
    unittest.main()
