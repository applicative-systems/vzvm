#!/usr/bin/env bash
#
# One-time setup: place an unprivileged copy of the builder SSH key where the
# harness can read it.
#
# /etc/nix/builder_ed25519 is 0600 root:nixbld. The benchmark runs unprivileged,
# and every subject must present the *same* key as the one already installed --
# otherwise `add-keys` takes its sudo branch and prompts for a password in the
# middle of a timed run.
#
# This is the only step that needs sudo. Run it once per machine.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh disable=SC1091
. "$here/lib.sh"

SYSTEM_KEY=/etc/nix/builder_ed25519

[ -e "$SYSTEM_KEY" ] || die "no builder key at $SYSTEM_KEY -- has the linux builder ever run?"

mkdir -p "$BENCH_STATE_DIR"
sudo install -m 600 -o "$(id -un)" "$SYSTEM_KEY" "$BENCH_KEY"
sudo install -m 644 -o "$(id -un)" "$SYSTEM_KEY.pub" "$BENCH_KEY.pub"

echo "installed readable copy at $BENCH_KEY"
echo "this is your real builder key -- $BENCH_STATE_DIR is world-readable on some setups;"
echo "remove it when you are done benchmarking:  rm -rf $BENCH_STATE_DIR"
