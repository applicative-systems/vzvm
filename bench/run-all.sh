#!/usr/bin/env bash
#
# The whole benchmark session as one command: `nix run .#benchmark-full`.
#
# Stages run in a deliberate order. `subst` wipes the guest store, so it must come
# last -- otherwise every later compute stage pays to re-download its
# dependencies and measures the wrong thing.
#
# This stops the nix-darwin linux-builder for the duration, because all three
# subjects would otherwise collide with it on port 31022. It is restored from an
# EXIT trap, so an interrupt or a failed stage still puts the machine back.
set -euo pipefail

BUILDER_LABEL=org.nixos.linux-builder
BUILDER_PLIST=/Library/LaunchDaemons/$BUILDER_LABEL.plist
STAGES="compute-x86,control-aarch64,churn,subst"
# Workloads for the two compile stages. run.sh loops over these, and analyze.py
# groups by (workload, arch), so several land in one report as a per-workload
# table. Kept at w1 by default because w2/w3 multiply the session length several
# times over -- see --help for measured estimates.
COMPUTE_WORKLOADS=w1
PAIRS_COMPUTE=7
PAIRS_CHURN=5
PAIRS_SUBST=5
COOLDOWN=90
QUICK=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
  --stages) STAGES="$2" && shift 2 ;;
  --workloads) COMPUTE_WORKLOADS="$2" && shift 2 ;;
  --pairs) PAIRS_COMPUTE="$2" && shift 2 ;;
  --cooldown) COOLDOWN="$2" && shift 2 ;;
  --dry-run) DRY_RUN=1 && shift ;;
  # Exercises every stage end to end in ~30 min. For validating the pipeline
  # after a change, not for numbers worth publishing.
  --quick)
    QUICK=1
    PAIRS_COMPUTE=1
    PAIRS_CHURN=1
    PAIRS_SUBST=1
    COOLDOWN=15
    shift
    ;;
  -h | --help)
    # Spelled out rather than sed'd out of $0: writeShellApplication prepends a
    # prelude, so line offsets into this file are wrong once packaged.
    cat <<'EOF'
benchmark-full -- the whole vzvm A/B benchmark session in one command.

Run from the vzvm checkout. Results are written to bench/results/ in the
working tree, and every stage's table is printed at the end.

This stops the nix-darwin linux-builder for the duration (all subjects would
otherwise collide with it on port 31022) and restores it from an EXIT trap, so
an interrupt or a failed stage still puts the machine back. It asks for sudo
once up front and holds the timestamp, so the restore at the end cannot stall
on a password prompt with nobody watching.

Stages, in order. `subst` is last because it wipes the guest store, which the
compute stages depend on:

  compute-x86        x86_64-linux zstd -- the headline, Rosetta vs qemu-user
  control-aarch64    aarch64-linux zstd -- must land near 1.0x or the headline
                     is not trustworthy
  churn              300 tiny derivations -- guest-side build scheduling
  subst              ~400 small paths fetched into a wiped store -- network

Options:
  --stages a,b   subset of the above, comma separated
  --workloads a,b  compile workloads for the two compute stages (default w1).
                 w1=zstd w2=openssl w3=git w4=ffmpeg. Measured on an M3 Pro,
                 7 pairs: w1 alone is ~2h for both compute stages. w2 roughly
                 quadruples that, w4 is far longer again and may fail under
                 Rosetta. Drop --pairs to 5 when adding workloads; the observed
                 spread (IQR ~3%) does not need 7.
  --pairs N      pairs per compile stage (default 7)
  --cooldown N   seconds between runs (default 90)
  --quick        1 pair per stage, short cooldown (~30 min). Validates the
                 pipeline; produces no publishable numbers.
  --dry-run      print the plan and exit, touching nothing
  -h, --help     this text

Full session is roughly 4-6 hours. Run on AC power with the lid open.
EOF
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    exit 1
    ;;
  esac
done

# Checked after argument parsing so --help works from anywhere.
#
# Results must land in the working tree, not the read-only store copy, so this
# operates on $PWD rather than on its own location.
REPO="${PWD}"
[ -f "$REPO/flake.nix" ] && [ -x "$REPO/bench/run.sh" ] || {
  echo "run this from the vzvm checkout (no flake.nix + bench/run.sh in $REPO)" >&2
  exit 1
}

say() { echo "[$(date -u +%H:%M:%S)] == $*" >&2; }

selected() {
  case ",$STAGES," in
  *",$1,"*) return 0 ;;
  *) return 1 ;;
  esac
}

if [ "$DRY_RUN" = 1 ]; then
  echo "repo:     $REPO"
  echo "cooldown: ${COOLDOWN}s"
  echo "builder:  $(nc -z 127.0.0.1 31022 2>/dev/null && echo "up (will be stopped, then restored)" || echo "down (will be started for --prepare, then stopped)")"
  echo "stages:"
  selected compute-x86 && echo "  compute-x86      x86_64-linux  $COMPUTE_WORKLOADS  pairs=$PAIRS_COMPUTE"
  selected control-aarch64 && echo "  control-aarch64  aarch64-linux $COMPUTE_WORKLOADS  pairs=$PAIRS_COMPUTE"
  selected churn && echo "  churn            aarch64-linux churn  pairs=$PAIRS_CHURN"
  selected subst && echo "  subst            x86_64-linux  subst  pairs=$PAIRS_SUBST  (wipes guest store; runs last)"
  echo
  echo "nothing was changed."
  exit 0
fi

builder_up() { nc -z 127.0.0.1 31022 2>/dev/null; }

STOPPED_BUILDER=0
SUDO_KEEPALIVE_PID=""

cleanup() {
  local rc=$?
  [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  if [ "$STOPPED_BUILDER" = 1 ]; then
    say "restoring the linux-builder"
    sudo launchctl bootstrap system "$BUILDER_PLIST" 2>/dev/null ||
      echo "could not restore the builder; run: sudo launchctl bootstrap system $BUILDER_PLIST" >&2
  fi
  # Never leave a benchmark VM holding a port or eight vCPUs.
  pkill -f "/tmp/vzvm-bench/" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

# Ask for sudo once, up front, and hold the timestamp for the session. A stage
# can run for hours, and without this the *restore* at the end would sit at a
# password prompt with nobody watching.
say "sudo is needed to stop and restart the linux-builder"
sudo -v
while true; do
  sudo -n true 2>/dev/null || true
  sleep 60
done &
SUDO_KEEPALIVE_PID=$!

if [ ! -r /tmp/vzvm-bench/builder_ed25519 ]; then
  say "installing an unprivileged copy of the builder key"
  "$REPO/bench/setup-keys.sh"
fi

# Subject closures are aarch64-linux, so they need a Linux builder -- the one we
# are about to stop. This must happen first.
if ! builder_up; then
  say "starting the linux-builder so subjects can be realised"
  sudo launchctl bootstrap system "$BUILDER_PLIST" 2>/dev/null || true
  for _ in $(seq 60); do
    builder_up && break
    sleep 1
  done
fi
say "realising subjects"
"$REPO/bench/run.sh" --prepare --subjects a1,b

if builder_up; then
  say "stopping the linux-builder for the session"
  sudo launchctl bootout "system/$BUILDER_LABEL" 2>/dev/null || true
  STOPPED_BUILDER=1
  for _ in $(seq 30); do
    builder_up || break
    sleep 1
  done
  builder_up && {
    echo "the builder is still on 31022; refusing to benchmark against it" >&2
    exit 1
  }
fi

declare -a REPORTS=()

# Runs one stage and remembers which results file it produced, so the summary can
# render every table at the end without the user hunting for timestamps.
stage() {
  local name="$1" phase="$2"
  shift 2
  selected "$name" || {
    say "skipping $name"
    return 0
  }
  say "stage $name"
  caffeinate -dimsu "$REPO/bench/run.sh" --cooldown "$COOLDOWN" "$@" || {
    echo "stage $name failed; continuing with the rest" >&2
    return 0
  }
  local newest
  newest="$(find "$REPO/bench/results" -name '*.jsonl' -print0 |
    xargs -0 ls -t 2>/dev/null | head -1)"
  [ -n "$newest" ] && REPORTS+=("$name|$phase|$newest")
}

stage compute-x86 compute --arch x86_64-linux --workloads "$COMPUTE_WORKLOADS" --pairs "$PAIRS_COMPUTE"
stage control-aarch64 compute --arch aarch64-linux --workloads "$COMPUTE_WORKLOADS" --pairs "$PAIRS_COMPUTE"
stage churn compute --arch aarch64-linux --workloads churn --pairs "$PAIRS_CHURN"
# Last: this wipes the guest store that the stages above rely on.
stage subst compute --mode subst --workloads subst --arch x86_64-linux --pairs "$PAIRS_SUBST"

say "all stages done"
echo
for entry in "${REPORTS[@]}"; do
  IFS='|' read -r name phase file <<<"$entry"
  echo "######## $name ########"
  python3 "$REPO/bench/analyze.py" "$file" --phase "$phase" || true
  if [ "$name" = compute-x86 ]; then
    echo
    echo "-------- $name (transfer) --------"
    python3 "$REPO/bench/analyze.py" "$file" --phase copy || true
  fi
  echo
done

if [ "$QUICK" = 1 ]; then
  echo "NOTE: --quick used. One pair per stage means no meaningful confidence" >&2
  echo "interval; this validates the pipeline, it does not produce publishable" >&2
  echo "numbers. Re-run without --quick for those." >&2
fi
