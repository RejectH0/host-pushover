"""Diagnostics and notice tests keep all configuration, state, and traffic local."""
import os
import pwd
import shutil
import time
import unittest

from test_host_pushover import Fixture, VERSION

_VERSION_PARTS = list(map(int, VERSION.split(".")))
NEXT_VERSION = f"{_VERSION_PARTS[0]}.{_VERSION_PARTS[1] + 1}.0"
LATER_VERSION = f"{_VERSION_PARTS[0]}.{_VERSION_PARTS[1] + 2}.0"


class DiagnosticsTests(Fixture):
    def test_doctor_is_offline_and_does_not_execute_configuration(self):
        for profile in ("system", "dsm"):
            with self.subTest(profile=profile):
                directory = self.configure(profile)
                marker = self.base / "configuration-executed"
                secret = "synthetic-secret-must-not-be-displayed"
                (directory / "config").write_text(f'touch "{marker}"\nprintf "{secret}"\n')
                result = self.run_script("--doctor", "--profile", profile, "--state-dir", self.state)
                self.assertIn("PASS curl 7.86.0 supports HTTPS", result.stdout)
                self.assertIn("contents were not loaded", result.stdout)
                self.assertIn("Cached update information is unknown", result.stdout)
                self.assertNotIn(secret, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertFalse(self.state.exists())
        self.assertEqual(self.requests(), [])

    def test_doctor_reports_missing_files_and_excess_permissions(self):
        directory = self.configure("dsm")
        (directory / "config").chmod(0o666)
        result = self.run_script("--doctor", "--profile", "dsm", "--state-dir", self.state)
        self.assertIn("WARN Configuration file", result.stdout)
        (directory / "config").unlink()
        result = self.run_script("--doctor", "--profile", "dsm", "--state-dir", self.state, success=False)
        self.assertIn("FAIL Global configuration", result.stdout)
        self.assertEqual(self.requests(), [])

    def test_doctor_reports_missing_utilities(self):
        env = dict(self.env, PATH="/nonexistent")
        result = self.run_script("--doctor", "--profile", "system", env=env, success=False)
        self.assertIn("FAIL Missing utilities:", result.stdout)
        self.assertEqual(self.requests(), [])

    def test_new_options_are_exclusive_and_validate_before_network(self):
        for args in (("--doctor", "--validate"), ("--doctor", "--caller", "example"),
                     ("--doctor", "--refresh"), ("--human", "--version"),
                     ("--check-update", "--human"), ("--update", "--no-notify"),
                     ("--check-update", "--notify-priority", "2"),
                     ("--internal-update-notice", "invalid"),
                     ("--prune-backups", "--update"), ("--prune-backups", "--allow-modified"),
                     ("--prune-backups", "--refresh"), ("--prune-backups", "--release", VERSION)):
            with self.subTest(args=args):
                self.run_script(*args, success=False)
        self.assertEqual(self.requests(), [])

    def test_human_status_is_offline_and_keeps_default_output(self):
        target = self.target("2.0.0")
        raw = self.command(target, "--update-status").stdout
        expected = {"installed_version", "latest_known_version", "update_available", "cache",
                    "last_success", "next_check", "state_dir"}
        self.assertEqual({line.split("=", 1)[0] for line in raw.splitlines()}, expected)
        human = self.command(target, "--update-status", "--human").stdout
        self.assertIn("Installed version: 2.0.0", human)
        self.assertIn("Available version is unknown", human)
        self.assertIn("Last recorded failure: none", human)
        self.assertEqual(self.requests(), [])
        self.assertFalse(self.state.exists())


@unittest.skipUnless(os.geteuid() == 0, "Isolated root-owned updater state requires root")
class ImprovedUpdateTests(Fixture):
    def managed(self):
        self.configure("system")
        target = self.target()
        self.command(target, "--update", "--release-dir", self.release(VERSION))
        return target

    def notices(self):
        return [request for request in self.requests() if request[-1].endswith("/messages.json")]

    def test_update_notice_deduplicates_and_honors_priority_and_suppression(self):
        target = self.managed()
        self.release(NEXT_VERSION)
        self.command(target, "--check-update", "--no-notify")
        self.assertEqual(self.notices(), [])
        self.command(target, "--check-update")  # Cached discovery still permits delivery.
        self.assertEqual(len(self.notices()), 1)
        self.assertIn("priority=-1", self.notices()[0])
        self.assertTrue(any("installed=" + VERSION in value and "available=" + NEXT_VERSION in value
                            for value in self.notices()[0]))
        marker = self.target_state(target) / f"private/notified-{NEXT_VERSION}"
        self.assertTrue(marker.is_file())
        self.command(target, "--check-update", "--refresh")
        self.assertEqual(len(self.notices()), 1)
        self.release(LATER_VERSION)
        self.command(target, "--check-update", "--refresh", "--notify-priority", "0")
        self.assertEqual(len(self.notices()), 2)
        self.assertIn("priority=0", self.notices()[-1])

    def test_failed_notice_retries_without_poisoning_discovery(self):
        target = self.managed()
        self.release(NEXT_VERSION)
        (self.network / "fault").write_text("notice-fail")
        result = self.command(target, "--check-update")
        self.assertIn("cache=fresh", result.stdout)
        self.assertIn("update_available=true", result.stdout)
        self.assertEqual(len(self.notices()), 1)
        state = self.target_state(target)
        self.assertFalse((state / f"private/notified-{NEXT_VERSION}").exists())
        self.assertGreater(int((state / "notice-next").read_text()), time.time())
        human = self.command(target, "--update-status", "--human").stdout
        self.assertIn("delivery failed", human)
        self.assertNotIn("synthetic-private-response", human + result.stderr)
        self.command(target, "--check-update")
        self.assertEqual(len(self.notices()), 1)
        (self.network / "fault").unlink()
        (state / "notice-next").write_text("0\n")
        self.command(target, "--check-update")
        self.assertEqual(len(self.notices()), 2)
        self.assertTrue((state / f"private/notified-{NEXT_VERSION}").is_file())

    def test_disabled_notices_and_tampered_checker_are_not_marked_sent(self):
        target = self.managed()
        config = self.system_config / "config"
        with config.open("a") as stream:
            stream.write("PUSHOVER_ENABLED=false\n")
        self.release(NEXT_VERSION)
        self.command(target, "--check-update")
        state = self.target_state(target)
        self.assertEqual((state / "notice-status").read_text(), "disabled\n")
        self.assertEqual(self.notices(), [])
        checker = state / "private/checker.sh"
        marker = self.base / "untrusted-code-executed"
        checker.write_text(f'#!/bin/bash\ntouch "{marker}"\n')
        (state / "notice-next").write_text("0\n")
        self.command(target, "--check-update")
        self.assertEqual((state / "notice-status").read_text(), "unavailable\n")
        self.assertFalse(marker.exists())
        self.assertFalse((state / f"private/notified-{NEXT_VERSION}").exists())

    def test_human_status_retains_failure_details_after_recovery(self):
        target = self.target("2.0.0")
        release = self.release("2.1.0")
        (release / "update-manifest.txt").unlink()
        self.command(target, "--check-update", success=False)
        human = self.command(target, "--update-status", "--human").stdout
        self.assertIn("HTTP 404: release manifest not found", human)
        self.assertRegex(human, r"Last attempt: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC")
        self.release("2.1.0")
        (self.network / "fault").write_text("timeout")
        self.command(target, "--check-update", "--refresh", success=False)
        self.assertIn("Request timed out", self.command(target, "--update-status", "--human").stdout)
        (self.network / "fault").unlink()
        self.command(target, "--check-update", "--refresh", "--no-notify")
        human = self.command(target, "--update-status", "--human").stdout
        self.assertIn("Cache: fresh", human)
        self.assertIn("Request timed out", human)
        before = len(self.requests())
        self.command(target, "--update-status", "--human")
        self.assertEqual(len(self.requests()), before)

    def test_dsm_notice_loads_config_only_after_switching_uid(self):
        if not shutil.which("runuser") and not shutil.which("sudo"):
            self.skipTest("No account-switch utility available")
        account = next(entry for entry in pwd.getpwall() if entry.pw_uid >= 1000)
        self.base.chmod(0o755)
        user_home = self.base / "notification-home"
        config_dir = user_home / ".config/host-pushover"
        (config_dir / "apps").mkdir(parents=True)
        config = config_dir / "config"
        config.write_text('PUSHOVER_APP_TOKEN="' + "T" * 30 + '"\nPUSHOVER_RECIPIENT_KEY="'
                          + "U" * 30 + '"\nprintf "%s" "$EUID" > "$HOME/config-uid"\n')
        for path in [user_home, *user_home.rglob("*")]:
            os.chown(path, account.pw_uid, account.pw_gid)
            path.chmod(0o700 if path.is_dir() else 0o600)
        # Mock only NSS's home directory; runuser/sudo really drops to this UID.
        getent = self.bin / "getent"
        getent.write_text('#!/bin/sh\nprintf "%s\\n" ' + repr(
            f"{account.pw_name}:x:{account.pw_uid}:{account.pw_gid}::{user_home}:/bin/bash") + '\n')
        getent.chmod(0o755)
        self.script.write_text(self.script.read_text().replace('\nmain "$@"\n',
            '\ndetect_profile() { printf "dsm\\n"; }\nmain "$@"\n'))
        target = self.target("2.03-dsm")
        os.chown(target, account.pw_uid, account.pw_gid)
        self.command(target, "--update", "--release-dir", self.release(VERSION))
        self.release(NEXT_VERSION)
        request_log = self.network / "requests.jsonl"
        request_log.touch()
        request_log.chmod(0o666)
        marker = self.base / "mutable-target-executed"
        with target.open("a") as stream:
            stream.write(f'\ntouch "{marker}"\n')
        self.command(target, "--check-update")
        self.assertEqual((user_home / "config-uid").read_text(), str(account.pw_uid))
        self.assertEqual(len(self.notices()), 1)
        self.assertFalse(marker.exists())
        self.assertTrue((self.target_state(target) / f"private/notified-{NEXT_VERSION}").is_file())

    def test_dsm_notice_supports_sudo_when_runuser_is_unavailable(self):
        if not shutil.which("sudo"):
            self.skipTest("sudo is unavailable; runuser is covered separately")
        self.script.write_text(self.script.read_text().replace('\nmain "$@"\n',
            '\ncommand() { if [[ "$1" == -v && "${2:-}" == runuser ]]; then return 1; fi; builtin command "$@"; }\nmain "$@"\n'))
        self.test_dsm_notice_loads_config_only_after_switching_uid()


if __name__ == "__main__":
    unittest.main()
