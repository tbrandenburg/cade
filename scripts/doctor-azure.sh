#!/usr/bin/env bash
# Offline declaration checks only; authentication belongs to future live acceptance.
set -euo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$directory/doctor_azure.py" "$@"
