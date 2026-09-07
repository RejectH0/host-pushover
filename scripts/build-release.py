#!/usr/bin/env python3
"""Build standalone release assets; Python is needed only on the build machine."""

import argparse
import hashlib
import re
from pathlib import Path


def build(destination: Path) -> None:
    root = Path(__file__).resolve().parents[1]
    script = (root / "host-pushover.sh").read_bytes()
    source = script.decode()
    version = re.search(r'^readonly SCRIPT_VERSION="([^"]+)"$', source, re.M).group(1)
    if not re.fullmatch(r"(?:0|[1-9][0-9]{0,5})(?:\.(?:0|[1-9][0-9]{0,5})){2}", version):
        raise ValueError("Release version must have three numeric components")
    engine = source.split("# BEGIN UPDATE ENGINE\n", 1)[1].split("# END UPDATE ENGINE\n", 1)[0]
    engine = engine.replace("readonly HP_BOOTSTRAP=0", "readonly HP_BOOTSTRAP=1", 1)
    bootstrap = '''#!/usr/bin/env bash
# Generated from host-pushover.sh by scripts/build-release.py. Do not edit.
set -u
set -o pipefail
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'The upgrade script requires Bash 4.4 or newer.\\n' >&2
    exit 1
fi
'''+engine+'''
bootstrap_main() {
    local mode=update
    case "${1:-}" in
        --help|-h|"")
            cat <<'HELP'
Upgrade an existing host-pushover installation to a unified release.

Usage: upgrade-host-pushover.sh --target <installed-script> [options]
       upgrade-host-pushover.sh --rollback --target <installed-script>

Run as root. Options:
  --dry-run             Download and verify without replacing the installed script
  --release <version>   Pin a stable release, for example 2.0.0
  --release-dir <dir>   Use a local release bundle for an offline pilot
  --state-dir <dir>     Root-owned updater state (default: /var/lib/host-pushover)
  --allow-modified      Explicitly replace a locally edited managed installation
  --no-schedule         Skip automatic cron setup / DSM scheduling instructions

The original script is backed up. Pushover configuration and existing callers
are preserved. Symlinked directories are resolved; final script symlinks and
multiple hard links are refused. DSM receives the same script as other Linux.
HELP
            return 0 ;;
        --rollback) mode=rollback; shift ;;
    esac
    hp_main "${mode}" "$@"
}
bootstrap_main "$@"
'''
    destination.mkdir(parents=True, exist_ok=True)
    files = {"host-pushover.sh": script, "upgrade-host-pushover.sh": bootstrap.encode()}
    for name, data in files.items():
        path = destination / name
        path.write_bytes(data)
        path.chmod(0o755)
    manifest = ("format=1\n" + f"version={version}\n"
                + f"script_sha256={hashlib.sha256(script).hexdigest()}\n"
                + f"bootstrap_sha256={hashlib.sha256(files['upgrade-host-pushover.sh']).hexdigest()}\n")
    files["update-manifest.txt"] = manifest.encode()
    (destination / "update-manifest.txt").write_text(manifest)
    checksums = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in files.items())
    (destination / "SHA256SUMS").write_text(checksums)
    print(f"Built v{version}: {len(manifest.encode())}-byte update manifest, {len(script)}-byte script")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("dist"))
    build(parser.parse_args().output)
