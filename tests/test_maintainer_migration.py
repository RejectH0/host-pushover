"""Maintainer wrapper tests use temporary targets and the closed network stub."""
import hashlib
import io
import os
import shlex
import shutil
import subprocess
import tarfile
import unittest
from pathlib import Path

from test_host_pushover import Fixture, ROOT


RUNNER = ROOT / "maintainer/legacy-migration/run-upgrade.sh"
BOOTSTRAP = ROOT / "maintainer/legacy-migration/upgrade-host-pushover.sh"
BUNDLE_NAMES = ("host-pushover.sh", "upgrade-host-pushover.sh", "update-manifest.txt", "SHA256SUMS")


class RunnerFixture(Fixture):
    def setUp(self):
        super().setUp()
        self.scratch = self.base / "scratch"
        self.scratch.mkdir()
        self.env["TMPDIR"] = str(self.scratch)

    def archive(self, alteration=None):
        # Use the notification fixture's configuration path, never live settings.
        files = {"host-pushover.sh": self.script.read_bytes(),
                 "upgrade-host-pushover.sh": BOOTSTRAP.read_bytes()}
        files["update-manifest.txt"] = (
            "format=1\nversion=2.0.0\nscript_sha256="
            + hashlib.sha256(files["host-pushover.sh"]).hexdigest()
            + "\nbootstrap_sha256="
            + hashlib.sha256(files["upgrade-host-pushover.sh"]).hexdigest() + "\n").encode()
        files["SHA256SUMS"] = "".join(
            f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in files.items()).encode()
        path = self.base / "reviewed bundle.tar.gz"
        with tarfile.open(path, "w:gz") as output:
            for name, data in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                if alteration == "symlink" and name == "host-pushover.sh":
                    info.type = tarfile.SYMTYPE
                    info.linkname = str(self.script)
                    info.size = 0
                if alteration == "unexpected" and name == "SHA256SUMS":
                    info.name = "../unexpected.txt"
                if alteration == "duplicate" and name == "SHA256SUMS":
                    info.name = "host-pushover.sh"
                output.addfile(info, io.BytesIO(data))
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def migrate(self, target, archive, checksum, *args, success=True):
        return self.run_script("--acknowledge-private-use", "--archive", archive,
                               "--sha256", checksum, "--target", target,
                               "--state-dir", self.state, "--no-schedule", *args,
                               script=RUNNER, success=success)


class MaintainerRunnerTests(RunnerFixture):
    def test_help_and_required_opt_in_have_no_side_effects(self):
        result = self.run_script("--help", script=RUNNER)
        self.assertIn("PRIVATE USE ONLY", result.stdout)
        self.assertIn("DO NOT DEPLOY", result.stdout)
        result = self.run_script("--archive", self.base / "missing.tar.gz",
                                 script=RUNNER, success=False)
        self.assertIn("Refusing to run without --acknowledge-private-use", result.stderr)
        self.run_script("--acknowledge-private-use", "--archive", script=RUNNER, success=False)
        self.assertEqual(self.requests(), [])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_invalid_archive_is_refused_before_running_bootstrap(self):
        target = self.target()
        original = target.read_bytes()
        for alteration in ("checksum", "unexpected", "duplicate", "symlink"):
            with self.subTest(alteration=alteration):
                archive, checksum = self.archive(alteration)
                if alteration == "checksum":
                    checksum = "0" * 64
                self.migrate(target, archive, checksum, success=False)
                self.assertEqual(target.read_bytes(), original)
                self.assertFalse(self.state.exists())
                self.assertFalse((self.scratch / "unexpected.txt").exists())
                self.assertEqual(list(self.scratch.iterdir()), [])
                self.assertEqual(self.requests(), [])

    def test_archive_builder_is_reproducible_and_omits_local_metadata(self):
        output = self.base / "build"
        output.mkdir()
        (output / "local-settings").write_text("synthetic data that must not enter the archive\n")
        command = ["python3", str(ROOT / "scripts/build-release.py"), "--output", str(output), "--archive"]
        subprocess.run(command, check=True, capture_output=True, timeout=15)
        archive = next(output.glob("*-upgrade.tar.gz"))
        original = archive.read_bytes()
        subprocess.run(command, check=True, capture_output=True, timeout=15)
        self.assertEqual(archive.read_bytes(), original)
        with tarfile.open(archive) as bundle:
            self.assertEqual(tuple(bundle.getnames()), BUNDLE_NAMES)
            for member in bundle.getmembers():
                self.assertTrue(member.isfile())
                self.assertEqual((member.uid, member.gid, member.mtime, member.uname, member.gname),
                                 (0, 0, 0, "", ""))
                self.assertEqual(bundle.extractfile(member).read(), (output / member.name).read_bytes())
        self.assertEqual((output / "upgrade-host-pushover.sh").read_bytes(), BOOTSTRAP.read_bytes())


@unittest.skipUnless(os.geteuid() == 0, "Run with sudo to exercise isolated maintainer installation")
class MaintainerInstallTests(RunnerFixture):
    def test_dry_run_does_not_install_schedule_or_send(self):
        target = self.target()
        original = target.read_bytes()
        archive, checksum = self.archive()
        self.migrate(target, archive, checksum, "--dry-run")
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual(list(self.target_state(target).glob("private/backup-*")), [])
        self.assertFalse((self.target_state(target) / "private/checker.sh").exists())
        self.assertEqual(self.requests(), [])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_upgrade_preserves_configuration_and_sends_one_health_check(self):
        config = self.configure("system") / "config"
        previous_config = (config.read_bytes(), config.stat().st_mode, config.stat().st_mtime_ns)
        target = self.target()
        original = target.read_bytes()
        archive, checksum = self.archive()
        result = self.migrate(target, archive, checksum)
        self.assertEqual(target.read_bytes(), self.script.read_bytes())
        self.assertEqual(target.stat().st_mode & 0o777, 0o750)
        self.assertEqual((config.read_bytes(), config.stat().st_mode, config.stat().st_mtime_ns), previous_config)
        backups = list(self.target_state(target).glob("private/backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.assertEqual(len(self.requests()), 2)  # One validation and one notification.
        self.assertIn("Post-upgrade Pushover health check accepted.", result.stdout)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_busybox_runner_can_defer_health_check(self):
        busybox = shutil.which("busybox")
        if not busybox:
            self.skipTest("BusyBox is unavailable")
        wrapper = self.bin / "tar"
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(busybox) + ' tar "$@"\n')
        wrapper.chmod(0o755)
        target = self.target()
        archive, checksum = self.archive()
        self.migrate(target, archive, checksum, "--no-check-in")
        self.assertEqual(target.read_bytes(), self.script.read_bytes())
        self.assertEqual(self.requests(), [])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_failed_health_check_reports_installed_upgrade(self):
        self.configure("system")
        (self.network / "fault").write_text("timeout")
        target = self.target()
        archive, checksum = self.archive()
        result = self.migrate(target, archive, checksum, success=False)
        self.assertEqual(target.read_bytes(), self.script.read_bytes())
        self.assertIn("Upgrade completed, but the health check failed", result.stderr)
        self.assertEqual(list(self.scratch.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
