#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
python3 scripts/build-release.py
bash -n host-pushover.sh
bash -n dist/upgrade-host-pushover.sh
shellcheck host-pushover.sh dist/upgrade-host-pushover.sh scripts/check.sh
python3 -m unittest discover -s tests -v
