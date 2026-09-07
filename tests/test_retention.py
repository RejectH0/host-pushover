"""Backup retention uses temporary managed installations and closed network stubs."""
import os
import shutil
import subprocess
import unittest

from test_host_pushover import Fixture, ROOT, VERSION


class RetentionPermissionsTests(Fixture):
    @unittest.skipIf(os.geteuid() == 0, "Requires an unprivileged caller")
    def test_cleanup_including_preview_requires_root(self):
        target = self.target()
        for options in ((), ("--dry-run",)):
            result = self.command(target, "--prune-backups", *options, success=False)
            self.assertIn("requires root", result.stderr)
        self.assertEqual(self.requests(), [])
        self.assertFalse(self.state.exists())


@unittest.skipUnless(os.geteuid() == 0, "Isolated managed backup cleanup requires root")
class RetentionTests(Fixture):
    def managed(self):
        target = self.target()
        self.command(target, "--update", "--release-dir", self.release("2.0.0"))
        self.private = self.target_state(target) / "private"
        self.kept = self.private / (self.private / "rollback").read_text().splitlines()[0]
        self.stale = self.private / "backup-20000101T000000Z-1.sh"
        self.stale.write_bytes(self.kept.read_bytes())
        self.stale.chmod(0o600)
        return target

    def backup_contents(self):
        return {p.name: p.read_bytes() for p in self.private.glob("backup-*.sh")
                if p.is_file() and not p.is_symlink()}

    def test_successful_upgrade_retains_only_recorded_backup_and_rolls_back(self):
        target = self.managed()
        original = target.read_bytes()
        config = self.configure("system") / "config"
        before = (config.read_bytes(), config.stat())
        self.command(target, "--update", "--release-dir", self.release(VERSION))
        record = (self.private / "rollback").read_text().splitlines()
        self.assertEqual(self.backup_contents(), {record[0]: original})
        self.assertEqual(record[6], "2.0.0")
        self.assertEqual(config.read_bytes(), before[0])
        for key in ("st_uid", "st_gid", "st_mode", "st_mtime_ns"):
            self.assertEqual(getattr(config.stat(), key), getattr(before[1], key))
        self.command(target, "--rollback", "--dry-run")
        self.command(target, "--rollback")
        self.assertEqual(target.read_bytes(), original)
        # Cleanup after rollback cannot mistake old installation state for success.
        self.command(target, "--prune-backups", success=False)
        self.assertEqual(self.backup_contents(), {record[0]: original})

    def test_explicit_cleanup_is_offline_previews_and_retains_old_pointer(self):
        target = self.managed()
        marker = self.base / "configuration-executed"
        self.configure("system", extra=f'touch "{marker}"\n')
        os.utime(self.kept, (1, 1))
        os.utime(self.stale, (2000000000, 2000000000))
        before = self.backup_contents()
        record = (self.private / "rollback").read_bytes()
        result = self.command(target, "--prune-backups", "--dry-run")
        self.assertIn("would remove 1 superseded backup(s)", result.stdout)
        self.assertEqual(self.backup_contents(), before)
        self.command(target, "--prune-backups")
        self.assertEqual(self.backup_contents(), {self.kept.name: before[self.kept.name]})
        self.assertEqual((self.private / "rollback").read_bytes(), record)
        result = self.command(target, "--prune-backups")
        self.assertIn("Removed 0 superseded backup(s)", result.stdout)
        self.assertEqual(self.requests(), [])
        self.assertFalse(marker.exists())

    def test_unrelated_and_unsafe_entries_are_preserved(self):
        target = self.managed()
        external = self.base / "external.sh"
        external.write_bytes(self.kept.read_bytes())
        external.chmod(0o600)
        entries = [self.private / f"backup-20000101T000000Z-{i}.sh" for i in range(2, 8)]
        entries[0].symlink_to(external)
        os.link(external, entries[1])
        entries[2].mkdir()
        entries[3].write_bytes(self.kept.read_bytes())
        entries[3].chmod(0o644)
        entries[4].write_text("#!/bin/bash\n# unrelated script\n")
        entries[4].chmod(0o600)
        entries[5].write_bytes(self.kept.read_bytes() + b"\nif\n")
        entries[5].chmod(0o600)
        unrelated = self.private / "configuration.bak"
        unrelated.write_text("synthetic configuration archive\n")
        checker = (self.private / "checker.sh").read_bytes()
        result = self.command(target, "--prune-backups")
        self.assertIn("Removed 1 superseded backup(s)", result.stdout)
        self.assertTrue(all(p.exists() for p in entries))
        self.assertTrue(entries[0].is_symlink())
        self.assertEqual(external.read_bytes(), self.kept.read_bytes())
        self.assertTrue(unrelated.exists())
        self.assertEqual((self.private / "checker.sh").read_bytes(), checker)

    def test_invalid_recovery_or_installation_state_preserves_all_backups(self):
        target = self.managed()
        record = self.private / "rollback"
        cases = [
            (record, None),
            (record, b"invalid\n"),
            (record, record.read_bytes().replace(self.kept.name.encode(), b"../outside.sh")),
            (record, b"\n".join(record.read_bytes().splitlines()[:6]) + b"\n\n"),
            (self.kept, b"damaged backup\n"),
            (self.private / "installed-sha256", b"0" * 64 + b"\n"),
            (self.private / "checker.sh", b"damaged checker\n"),
            (target, target.read_bytes() + b"\n# local edit\n"),
        ]
        for path, replacement in cases:
            with self.subTest(path=path.name, missing=replacement is None):
                original = path.read_bytes()
                mode = path.stat().st_mode & 0o777
                if replacement is None:
                    path.unlink()
                else:
                    path.write_bytes(replacement)
                before = self.backup_contents()
                self.command(target, "--prune-backups", success=False)
                self.assertEqual(self.backup_contents(), before)
                path.write_bytes(original)
                path.chmod(mode)
        self.assertEqual(self.requests(), [])

    def test_failed_download_dry_run_and_scheduled_check_preserve_backups(self):
        target = self.managed()
        before = self.backup_contents()
        release = self.release(VERSION)
        (self.network / "fault").write_text("timeout")
        self.command(target, "--update", success=False)
        self.assertEqual(self.backup_contents(), before)
        (self.network / "fault").unlink()
        self.command(target, "--update", "--release-dir", release, "--dry-run")
        self.command(target, "--check-update", "--no-notify")
        self.assertEqual(self.backup_contents(), before)

    def failed_update_preserves_backups(self, function):
        target = self.managed()
        before = self.backup_contents()
        release = self.release(VERSION)
        self.script.write_text(self.script.read_text().replace('\nmain "$@"\n',
            '\n' + function + '() { return 1; }\nmain "$@"\n'))
        self.command(target, "--update", "--release-dir", release, success=False)
        after = self.backup_contents()
        self.assertGreater(len(after), len(before))
        for name, contents in before.items():
            self.assertEqual(after[name], contents)

    def test_failed_installation_preserves_all_previous_backups(self):
        self.failed_update_preserves_backups("hp_install_file")

    def test_failed_finalization_preserves_all_previous_backups(self):
        self.failed_update_preserves_backups("hp_finish_install")

    def test_failed_post_install_verification_preserves_all_previous_backups(self):
        self.failed_update_preserves_backups("hp_verify_managed_install")

    def test_cleanup_respects_the_update_lock(self):
        target = self.managed()
        before = self.backup_contents()
        lock = self.private / "lock"
        lock.mkdir(mode=0o700)
        result = self.command(target, "--prune-backups", success=False)
        self.assertIn("holds the lock", result.stderr)
        self.assertEqual(self.backup_contents(), before)

    def test_generated_bootstrap_supports_cleanup_and_preview(self):
        target = self.managed()
        output = self.base / "bundle"
        subprocess.run(["python3", str(ROOT / "scripts/build-release.py"), "--output", str(output)],
                       check=True, capture_output=True)
        bootstrap = output / "upgrade-host-pushover.sh"
        self.command(target, "--prune-backups", "--dry-run", script=bootstrap)
        self.assertTrue(self.stale.exists())
        self.command(target, "--prune-backups", script=bootstrap)
        self.assertFalse(self.stale.exists())
        self.assertTrue(self.kept.exists())

    def test_cleanup_error_retains_recovery_and_reports_verified_installation(self):
        target = self.managed()
        original = target.read_bytes()
        remover = self.bin / "rm"
        remover.write_text('#!/bin/sh\nfor argument do\n'
                           '  case "$argument" in */backup-20000101T000000Z-1.sh) exit 1 ;; esac\n'
                           'done\nexec /bin/rm "$@"\n')
        remover.chmod(0o755)
        self.command(target, "--prune-backups", success=False)
        self.assertTrue(self.kept.exists())
        result = self.command(target, "--update", "--release-dir", self.release(VERSION))
        self.assertIn("Installation verified; backup cleanup needs attention", result.stderr)
        record = (self.private / "rollback").read_text().splitlines()
        self.assertEqual((self.private / record[0]).read_bytes(), original)
        self.assertTrue(self.stale.exists())
        self.assertIn(f'SCRIPT_VERSION="{VERSION}"', target.read_text())

    def test_busybox_cleanup_and_user_owned_installation(self):
        busybox = shutil.which("busybox")
        if not busybox:
            self.skipTest("BusyBox is unavailable")
        target = self.managed()
        for command in ("stat", "sha256sum", "date", "cp", "mv", "mkdir", "rmdir", "mktemp", "chmod", "chown", "rm"):
            (self.bin / command).symlink_to(busybox)
        # Synthetic non-root numeric ownership, with the existing mode retained.
        os.chown(target, 23456, 23457)
        record = (self.private / "rollback").read_text().splitlines()
        record[3:5] = ["23456", "23457"]
        (self.private / "rollback").write_text("\n".join(record) + "\n")
        self.command(target, "--prune-backups")
        self.assertFalse(self.stale.exists())
        self.assertTrue(self.kept.exists())
        self.assertEqual((target.stat().st_uid, target.stat().st_gid, target.stat().st_mode & 0o777),
                         (23456, 23457, 0o750))


if __name__ == "__main__":
    unittest.main()
