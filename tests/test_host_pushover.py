"""Run without live configuration or network; root integration tests use /tmp only."""
import hashlib
import json
import os
import pwd
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "host-pushover.sh").read_text()


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="host-pushover-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.network = self.base / "network"
        self.network.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        shutil.copyfile(ROOT / "tests/fake_curl.py", self.bin / "curl")
        (self.bin / "curl").chmod(0o755)
        # Backoff remains observable but does not slow notification unit tests.
        (self.bin / "sleep").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "sleep").chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", HOME=str(self.base),
                        HP_TEST_NETWORK=str(self.network))
        self.script = self.base / "host-pushover.sh"
        # Only the system fixture path changes, so no test can source live config.
        self.system_config = self.base / "system-config"
        self.script.write_text(SOURCE.replace('CONFIG_ROOT_DIR="/usr/local/etc/host-pushover"',
                                             f'CONFIG_ROOT_DIR="{self.system_config}"'))
        self.script.chmod(0o755)
        self.definitions = self.base / "definitions.sh"
        self.definitions.write_text(self.script.read_text().rsplit('\nmain "$@"\n', 1)[0])
        self.state = self.base / "state"

    def run_script(self, *args, success=True, script=None, env=None):
        result = subprocess.run(["/bin/bash", str(script or self.script), *map(str, args)],
                                env=env or self.env, capture_output=True, text=True, timeout=15)
        if success is True:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        elif success is False:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def function(self, code, *args):
        return subprocess.run(["/bin/bash", "-c", 'source "$1"; shift; ' + code,
                               "test", str(self.definitions), *args], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def requests(self):
        path = self.network / "requests.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def configure(self, profile="dsm", extra=""):
        directory = self.base / ".config/host-pushover" if profile == "dsm" else self.system_config
        (directory / "apps").mkdir(parents=True)
        config = directory / "config"
        config.write_text("PUSHOVER_APP_TOKEN='" + "T" * 30 + "'\n"
                          "PUSHOVER_RECIPIENT_KEY='" + "U" * 30 + "'\n" + extra)
        config.chmod(0o600 if profile == "dsm" else 0o644)
        return directory

    def release(self, version="2.0.0", body=None):
        directory = self.network / version
        directory.mkdir(exist_ok=True)
        body = body or SOURCE.replace('readonly SCRIPT_VERSION="2.0.0"',
                                       f'readonly SCRIPT_VERSION="{version}"')
        (directory / "host-pushover.sh").write_text(body)
        checksum = hashlib.sha256(body.encode()).hexdigest()
        (directory / "update-manifest.txt").write_text(
            f"format=1\nversion={version}\nscript_sha256={checksum}\nbootstrap_sha256=" + "a" * 64 + "\n")
        (self.network / "latest").write_text(version)
        return directory

    def target(self, version="1.04", mode=0o750):
        directory = self.base / "installation with spaces"
        directory.mkdir(exist_ok=True)
        target = directory / "host-pushover.sh"
        target.write_text('#!/bin/bash\nreadonly SCRIPT_NAME="host-pushover.sh"\n'
                          f'readonly SCRIPT_VERSION="{version}"\n'
                          'echo "The legacy script must never execute during migration" >&2\nexit 99\n')
        target.chmod(mode)
        return target

    def command(self, target, mode="--update", *args, **kwargs):
        return self.run_script(mode, "--target", target, "--state-dir", self.state, *args, **kwargs)

    def target_state(self, target):
        return self.state / hashlib.sha256(str(target.resolve()).encode()).hexdigest()


class RuntimeTests(Fixture):
    def test_version_is_offline_without_home(self):
        env = self.env.copy()
        env.pop("HOME")
        result = self.run_script("--version", env=env)
        self.assertEqual(result.stdout, "host-pushover.sh 2.0.0\n")
        self.assertEqual(self.requests(), [])

    def test_exclusive_modes(self):
        for args in (("--version", "--check-in"), ("--check-in", "--test"),
                     ("--update", "--setup"), ("--version", "--help"),
                     ("--update", "--caller", "example"), ("--dry-run", "--version")):
            with self.subTest(args=args):
                self.run_script(*args, success=False)
        self.assertEqual(self.requests(), [])

    def test_profile_and_home_discovery(self):
        output = self.run_script("--profile", "dsm", "--paths").stdout
        self.assertIn(f"config_file={self.base}/.config/host-pushover/config", output)
        env = self.env.copy()
        env.pop("HOME")
        output = self.run_script("--profile", "dsm", "--paths", env=env).stdout
        self.assertIn(pwd.getpwuid(os.geteuid()).pw_dir + "/.config/host-pushover/config", output)
        etc = self.base / "etc"
        etc.mkdir()
        self.assertEqual(self.function('detect_profile "$1"', str(etc)).stdout, "system\n")
        (etc / "synoinfo.conf").touch()
        self.assertEqual(self.function('detect_profile "$1"', str(etc)).stdout, "dsm\n")

    def test_json_parser(self):
        for payload in ('{"status":1}', '{"request":"test","status": 1,"errors":[]}',
                        '{"other":{"status":0},"status":1}', '{"status":1,"a":[null,true,{},"text"]}'):
            with self.subTest(payload=payload):
                self.assertEqual(self.function('json_status_is_success "$1"', payload).returncode, 0)
        for payload in ('{"status":10}', '{"status":0}', '{"status":"1"}',
                        '{"nested":{"status":1}}', '{"status":1,"status":0}',
                        '{"error":"\\\"status\\\":1"}', '{"status":1,}',
                        '{"status":1}garbage', '{"status":1', 'not JSON',
                        '{"status":1.0}', '{"status":1e0}', '{"status":01}'):
            with self.subTest(payload=payload):
                self.assertNotEqual(self.function('json_status_is_success "$1"', payload).returncode, 0)

    def test_version_comparison(self):
        for remote, current, expected in (("2.0.0", "1.04", 0), ("2.0.0", "2.03-dsm", 0),
                                          ("2.10.0", "2.9.9", 0), ("2.0.1", "2.0.0", 0),
                                          ("2.0.0", "2.0.0", 1), ("2.0.0", "2.1.0", 1),
                                          ("1.9.0", "2.03-dsm", 1),
                                          ("02.0.0", "2.0.0", 1), ("2.0.0-rc1", "1.04", 1)):
            with self.subTest(remote=remote, current=current):
                self.assertEqual(self.function('hp_newer "$1" "$2"', remote, current).returncode, expected)

    def test_delivery_and_overrides_without_update_network(self):
        for profile in ("system", "dsm"):
            with self.subTest(profile=profile):
                directory = self.configure(profile)
                (directory / "apps/backup-job.conf").write_text("APP_PUSHOVER_TITLE_PREFIX='Backups'\nAPP_PUSHOVER_SOUND='magic'\n")
                config_before = (directory / "config").read_bytes()
                result = self.run_script("--profile", profile, "--caller", "backup-job", "--level", "err", "--message", "synthetic failure")
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")
                self.assertEqual((directory / "config").read_bytes(), config_before)
                request = self.requests()[-1]
                self.assertIn("sound=magic", request)
                self.assertTrue(any(value.startswith("title=Backups [") for value in request))
                self.assertTrue(all(args[-1].startswith("https://api.pushover.net/") for args in self.requests()))

    def test_dsm_retry_and_health_check(self):
        self.configure()
        (self.network / "fault").write_text("dns-once")
        result = self.run_script("--profile", "dsm", "--check-in")
        self.assertIn("Retrying", result.stderr)
        self.assertEqual(len(self.requests()), 3)  # validation retry, then delivery
        self.assertTrue(any("2.0.0" in value for value in self.requests()[-1]))

    def test_system_retains_one_transport_attempt(self):
        self.configure("system")
        (self.network / "fault").write_text("dns-once")
        self.run_script("--profile", "system", "--caller", "backup-job", "--level", "err", "--message", "example", success=False)
        self.assertEqual(len(self.requests()), 1)

    def test_setup_writer_preserves_profile_format_and_modes(self):
        for profile, mode in (("dsm", 0o600), ("system", 0o644)):
            with self.subTest(profile=profile):
                result = self.function('PROFILE="$1"; initialize_profile; write_global_config "$2" "$3" "" "" 10 30 ""', profile, "T" * 30, "U" * 30)
                self.assertEqual(result.returncode, 0, result.stderr)
                path = (self.base / ".config/host-pushover" if profile == "dsm" else self.system_config) / "config"
                self.assertEqual(path.stat().st_mode & 0o777, mode)
                self.assertIn("PUSHOVER_HOST_LABEL=", path.read_text())
                self.assertNotIn("UPDATE", path.read_text())

    @unittest.skipIf(os.geteuid() == 0, "Unprivileged command test runs in the normal-user suite")
    def test_install_requires_root(self):
        result = self.command(self.target(), success=False)
        self.assertIn("requires root", result.stderr)
        self.assertEqual(self.requests(), [])


@unittest.skipUnless(os.geteuid() == 0, "Run with sudo to exercise isolated root installation")
class UpdateTests(Fixture):
    def test_legacy_upgrade_rollback_and_configuration_preservation(self):
        for version in ("1.04", "2.03-dsm"):
            with self.subTest(version=version):
                target = self.target(version)
                original = target.read_bytes()
                config = target.parent / "local-config"
                config.write_text("synthetic local configuration\n")
                config.chmod(0o600)
                before = (config.read_bytes(), config.stat().st_mode, config.stat().st_uid)
                release = self.release()
                self.command(target, "--update", "--release-dir", release)
                self.assertEqual(target.read_bytes(), (release / "host-pushover.sh").read_bytes())
                self.assertEqual(target.stat().st_mode & 0o777, 0o750)
                self.assertEqual((config.read_bytes(), config.stat().st_mode, config.stat().st_uid), before)
                self.command(target, "--rollback")
                self.assertEqual(target.read_bytes(), original)
                self.command(target, "--rollback")
                shutil.rmtree(self.state)

    def test_dry_run_and_idempotency(self):
        target = self.target()
        original = target.read_bytes()
        release = self.release()
        self.command(target, "--update", "--release-dir", release, "--dry-run")
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual(list(self.target_state(target).glob("private/backup-*")), [])
        self.command(target, "--update", "--release-dir", release)
        self.command(target, "--update", "--release-dir", release)
        self.assertEqual(len(list(self.target_state(target).glob("private/backup-*"))), 1)

    def test_download_failure_retains_target(self):
        target = self.target()
        original = target.read_bytes()
        self.release()
        for fault in ("timeout", "http-error", "force-304"):
            with self.subTest(fault=fault):
                (self.network / "fault").write_text(fault)
                self.command(target, success=False)
                self.assertEqual(target.read_bytes(), original)
                self.assertFalse((self.target_state(target) / "private/lock").exists())

    def test_manifest_and_candidate_validation(self):
        target = self.target()
        original = target.read_bytes()
        release = self.release()
        manifest = (release / "update-manifest.txt").read_text()
        cases = [manifest + "version=9.0.0\n", manifest.replace("format=1", "format=2"),
                 manifest.replace("version=2.0.0", "version=$(touch injected)"),
                 manifest + "url=https://example.com/script\n", "x" * 5000]
        for value in cases:
            (release / "update-manifest.txt").write_text(value)
            self.command(target, "--update", "--release-dir", release, success=False)
            self.assertEqual(target.read_bytes(), original)
        (release / "update-manifest.txt").write_text(manifest)
        (release / "host-pushover.sh").write_text("corrupt")
        self.command(target, "--update", "--release-dir", release, success=False)
        self.assertEqual(target.read_bytes(), original)
        self.release(body='#!/bin/bash\nreadonly SCRIPT_NAME="host-pushover.sh"\nreadonly SCRIPT_VERSION="2.0.1"\n')
        self.command(target, "--update", "--release-dir", release, success=False)
        self.release(body='#!/bin/bash\nreadonly SCRIPT_NAME="host-pushover.sh"\nreadonly SCRIPT_VERSION="2.0.0"\nif\n')
        self.command(target, "--update", "--release-dir", release, success=False)
        self.assertEqual(target.read_bytes(), original)

    def test_pinned_release_and_no_downgrade(self):
        target = self.target()
        self.release("2.0.0")
        self.release("2.1.0")
        self.command(target, "--update", "--release", "2.0.0")
        self.assertIn('SCRIPT_VERSION="2.0.0"', target.read_text())
        self.command(target)
        self.assertIn('SCRIPT_VERSION="2.1.0"', target.read_text())
        self.command(target, "--update", "--release", "2.0.0", success=False)
        self.assertIn('SCRIPT_VERSION="2.1.0"', target.read_text())

    def test_cache_conditional_request_and_backoff(self):
        target = self.target()
        self.release()
        result = self.command(target, "--check-update")
        self.assertIn("update_available=true", result.stdout)
        self.assertEqual((self.target_state(target) / "update-available").read_text(), "2.0.0\n")
        self.command(target, "--check-update")
        self.assertEqual(len(self.requests()), 1)
        self.command(target, "--check-update", "--refresh")
        self.assertEqual(len(self.requests()), 2)
        self.assertIn("--header", self.requests()[-1])
        (self.network / "fault").write_text("timeout")
        self.command(target, "--check-update", "--refresh", success=False)
        self.command(target, "--check-update")
        self.assertEqual(len(self.requests()), 3)
        result = self.command(target, "--update-status")
        self.assertIn("latest_known_version=2.0.0", result.stdout)
        self.assertIn("cache=stale", result.stdout)
        self.assertEqual(len(self.requests()), 3)

    def test_install_clears_flag_and_rollback_restores_it(self):
        target = self.target()
        self.release()
        self.command(target, "--check-update")
        flag = self.target_state(target) / "update-available"
        self.assertTrue(flag.exists())
        self.command(target)
        self.assertFalse(flag.exists())
        self.command(target, "--rollback")
        self.assertTrue(flag.exists())

    def test_owner_preserved_for_user_installation(self):
        target = self.target("2.03-dsm")
        account = next(entry for entry in pwd.getpwall() if entry.pw_uid >= 1000)
        os.chown(target, account.pw_uid, account.pw_gid)
        self.command(target, "--update", "--release-dir", self.release())
        self.assertEqual((target.stat().st_uid, target.stat().st_gid), (account.pw_uid, account.pw_gid))
        checker = self.target_state(target) / "private/checker.sh"
        self.assertEqual(checker.stat().st_uid, 0)
        self.assertEqual(checker.stat().st_mode & 0o777, 0o700)
        self.command(target, "--rollback")
        self.assertEqual((target.stat().st_uid, target.stat().st_gid), (account.pw_uid, account.pw_gid))

    def test_root_update_never_sources_notification_configuration(self):
        target = self.target("2.03-dsm")
        directory = self.configure()
        poison = self.base / "configuration-executed"
        (directory / "config").write_text(f'touch "{poison}"\n')
        self.command(target, "--update", "--release-dir", self.release())
        self.assertFalse(poison.exists())

    def test_generated_bootstrap_migrates_legacy_without_a_second_engine(self):
        bundle = self.base / "bundle"
        subprocess.run(["python3", str(ROOT / "scripts/build-release.py"), "--output", str(bundle)],
                       check=True, capture_output=True, env=self.env)
        target = self.target("2.03-dsm")
        self.run_script("--target", target, "--state-dir", self.state, "--release-dir", bundle,
                        "--no-schedule", script=bundle / "upgrade-host-pushover.sh")
        self.assertEqual(target.read_bytes(), (bundle / "host-pushover.sh").read_bytes())
        self.run_script("--rollback", "--target", target, "--state-dir", self.state,
                        script=bundle / "upgrade-host-pushover.sh")
        self.assertIn('SCRIPT_VERSION="2.03-dsm"', target.read_text())

    def test_cron_writer_is_idempotent_and_quotes_paths(self):
        cron = self.base / "cron"
        work = self.base / "work"
        cron.mkdir()
        work.mkdir()
        result = self.function('HP_WORK="$1"; HP_ID="0123456789abcdef"; HP_TARGET="$2"; '
                               'hp_write_cron "$3" "$4"; hp_write_cron "$3" "$4"',
                               str(work), str(self.base / "target with spaces"), str(cron),
                               "/bin/bash '/synthetic directory/checker.sh' --check-update")
        self.assertEqual(result.returncode, 0, result.stderr)
        files = list(cron.iterdir())
        self.assertEqual(len(files), 1)
        content = files[0].read_text()
        self.assertEqual(content.count("* * * root"), 1)
        self.assertIn("'/synthetic directory/checker.sh'", content)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o644)

    def test_modified_script_and_backup_detection(self):
        target = self.target()
        release = self.release()
        self.command(target, "--update", "--release-dir", release)
        with target.open("a") as stream:
            stream.write("# local edit\n")
        self.command(target, "--update", "--release-dir", release, success=False)
        self.command(target, "--rollback", success=False)
        self.command(target, "--update", "--release-dir", release, "--allow-modified")
        backup = sorted(self.target_state(target).glob("private/backup-*"))[-1]
        backup.write_text("damaged backup")
        self.command(target, "--rollback", success=False)

    def test_symlinks_and_hardlinks_are_refused(self):
        target = self.target()
        link = target.parent / "link.sh"
        link.symlink_to(target)
        self.command(link, success=False)
        hard = target.parent / "hard.sh"
        os.link(target, hard)
        self.command(target, success=False)
        self.assertEqual(self.requests(), [])

    def test_state_symlink_is_refused(self):
        target = self.target()
        self.state.symlink_to(self.network)
        self.command(target, success=False)
        self.assertEqual(self.requests(), [])

    def test_concurrent_update_and_interruption(self):
        target = self.target()
        original = target.read_bytes()
        self.release()
        (self.network / "fault").write_text("block")
        process = subprocess.Popen(["/bin/bash", str(self.script), "--update", "--target", str(target),
                                    "--state-dir", str(self.state)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            for _ in range(100):
                if (self.network / "blocked").exists(): break
                time.sleep(0.02)
            self.assertTrue((self.network / "blocked").exists())
            result = self.command(target, success=False)
            self.assertIn("lock", result.stderr)
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual(target.read_bytes(), original)
            self.assertFalse((self.target_state(target) / "private/lock").exists())
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_busybox_update_and_rollback(self):
        busybox = shutil.which("busybox")
        if not busybox: self.skipTest("BusyBox is not installed")
        for command in ("stat", "sha256sum", "date", "cp", "mv", "mkdir", "rmdir", "mktemp", "chmod", "chown", "rm"):
            (self.bin / command).symlink_to(busybox)
        target = self.target("2.03-dsm")
        original = target.read_bytes()
        self.command(target, "--update", "--release-dir", self.release())
        self.command(target, "--rollback")
        self.assertEqual(target.read_bytes(), original)

    def test_directory_replacement_cannot_redirect_root_installation(self):
        target = self.target()
        original = target.read_bytes()
        decoy_dir = self.base / "decoy"
        decoy_dir.mkdir()
        decoy = decoy_dir / target.name
        decoy.write_bytes(original)
        self.release()
        (self.network / "fault").write_text("block")
        process = subprocess.Popen(["/bin/bash", str(self.script), "--update", "--target", str(target),
                                    "--state-dir", str(self.state)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            for _ in range(100):
                if (self.network / "blocked").exists(): break
                time.sleep(0.02)
            self.assertTrue((self.network / "blocked").exists())
            moved = self.base / "original-directory"
            target.parent.rename(moved)
            target.parent.symlink_to(decoy_dir)
            (self.network / "fault").write_text("")
            output, error = process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0, output + error)
            self.assertEqual(decoy.read_bytes(), original)
            self.assertEqual((moved / target.name).read_bytes(), original)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()


if __name__ == "__main__":
    unittest.main()
