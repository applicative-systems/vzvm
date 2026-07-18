#!/usr/bin/env bash
#
# A/B benchmark driver for the vz and QEMU Linux builders.
#
# Emits one JSON object per timed run to bench/results/<stamp>.jsonl. Every
# published figure must be re-derivable from that file alone; analyze.py reads
# nothing else.
#
# Usage:
#   bench/run.sh --workloads w1,w2 --pairs 7 --arch x86_64-linux --subjects a1,b
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh disable=SC1091
. "$here/lib.sh"

WORKLOADS="w1"
PAIRS=7
ARCH="x86_64-linux"
SUBJECTS="a1,b"
COOLDOWN=90
DRIFT_PCT=5
PREPARE_ONLY=0
# compute -- deps pre-warmed, timed build runs offline. Measures pure compute.
# subst   -- guest store wiped, nothing pre-warmed, substituters on. Measures
#            fetch throughput for a wide closure of many small paths.
MODE=compute
# Sequential SSH connections timed per run, for the per-connection cost axis.
CONN_COUNT=20

while [ $# -gt 0 ]; do
  case "$1" in
  --workloads) WORKLOADS="$2" && shift 2 ;;
  --pairs) PAIRS="$2" && shift 2 ;;
  --arch) ARCH="$2" && shift 2 ;;
  --subjects) SUBJECTS="$2" && shift 2 ;;
  --cooldown) COOLDOWN="$2" && shift 2 ;;
  --mode) MODE="$2" && shift 2 ;;
  --prepare) PREPARE_ONLY=1 && shift ;;
  *) die "unknown argument: $1" ;;
  esac
done

case "$MODE" in
compute | subst) ;;
*) die "--mode must be 'compute' or 'subst', got '$MODE'" ;;
esac

IFS=, read -r -a workloads <<<"$WORKLOADS"
IFS=, read -r -a subjects <<<"$SUBJECTS"
[ "${#subjects[@]}" -eq 2 ] || die "--subjects takes exactly two, e.g. a1,b"

mkdir -p "$here/results"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
BENCH_RESULTS="$here/results/$RUN_ID.jsonl"
export BENCH_RESULTS

# Provenance. Without these the numbers are uncomparable to any later run.
NIXPKGS_BENCH_REV="$(nix flake metadata --json 2>/dev/null | jq -r '.locks.nodes["nixpkgs-bench"].locked.rev // .locks.nodes.nixpkgs.locked.rev')"
REPO_REV="$(git -C "$here/.." rev-parse HEAD)"
HOST_OS="$(sw_vers -productVersion)/$(sw_vers -buildVersion)"
NIX_VERSION="$(nix --version | awk '{print $3}')"

log "results  -> $BENCH_RESULTS"
log "nixpkgs  -> $NIXPKGS_BENCH_REV"
log "repo     -> $REPO_REV"

# Realising the subjects happens BEFORE the stock-builder check, because the
# subject closures are aarch64-linux and need a Linux builder to build -- the very
# thing the benchmark stops. Run `--prepare` once while the nix-darwin builder is
# still up; afterwards these are cached and this loop is a no-op that needs no
# builder at all.
log "realising subjects"
declare -A installer
for s in "${subjects[@]}"; do
  installer[$s]="$(nix build --no-link --print-out-paths \
    --impure --expr "
      let f = builtins.getFlake (toString $here/..);
          pkgs = import f.inputs.nixpkgs {
            system = \"aarch64-darwin\";
            overlays = [ f.overlays.default ];
          };
      in (import $here/subjects.nix { inherit pkgs; }).$s")"
  log "  $s -> ${installer[$s]}"
done

if [ "$PREPARE_ONLY" -eq 1 ]; then
  log "subjects realised. Now stop the builder and run without --prepare:"
  log "  sudo launchctl bootout system/org.nixos.linux-builder"
  exit 0
fi

assert_no_stock_builder
seed_keys

drv_for() {
  local workload="$1" salt="$2"
  nix eval --impure --raw --expr "
    let f = builtins.getFlake (toString $here/..);
        w = import $here/workloads.nix {
          nixpkgs = f.inputs.nixpkgs;
          salt = \"$salt\";
          system = \"$ARCH\";
        };
    in w.$workload.drvPath"
}

# What to pre-warm before timing a workload.
#
# Normally the unsalted variant of the workload itself. `churn` is the exception:
# its unsalted variant would build all 300 units, costing as much as the
# measurement. Its units only need stdenv, which w0 pulls in for a fraction of
# the work.
prewarm_target() {
  case "$1" in
  churn) echo w0 ;;
  *) echo "$1" ;;
  esac
}

# One subject, one workload, one salt. The VM is started fresh and torn down, so
# boot latency and build time are never entangled.
run_one() {
  local subject="$1" workload="$2" salt="$3" pair="$4" order="$5"
  local port drv boot facts probe build_g build_e
  port="$(subject_port "$subject")"

  # In subst mode the guest store is wiped before boot, so the timed realise has
  # to fetch its whole closure instead of finding it already present.
  if [ "$MODE" = subst ]; then
    log "$subject: wiping guest store (subst mode)"
    wipe_guest_store "$subject"
  fi

  local t0
  t0="$(now_ns)"
  start_vm "$subject" "${installer[$subject]}"
  boot="$(wait_ssh "$subject" "$t0")"
  assert_only_subject "$subject"
  facts="$(guest_facts "$port")"

  if [ "$MODE" = compute ]; then
    # Pull every dependency into the guest store, so the timed run (which has
    # substituters emptied) needs zero network.
    log "$subject/$workload/$salt: pre-warming deps"
    prewarm "$port" "$(drv_for "$(prewarm_target "$workload")" "prewarm")"
  fi

  # Per-connection SSH cost. Cheap, and recorded on every run regardless of mode:
  # it is the only measurement that exercises vz's fork-per-connection sshd
  # against QEMU's persistent one.
  local conn
  conn="$(time_ssh_connections "$port" "$CONN_COUNT")" || conn=0

  # Thermal-drift probe, measured on the host immediately before the timed run.
  probe="$(host_probe)"

  drv="$(drv_for "$workload" "$salt")"
  copy_drv "$port" "$drv"
  assert_not_built "$port" "$drv"

  local paths=0
  if [ "$MODE" = subst ]; then
    log "$subject/$workload/$salt: substituting (network-bound)"
    build_g="$(time_build_guest_online "$port" "$drv")"
    local -a subst_outs
    mapfile -t subst_outs < <(out_paths "$drv")
    paths="$(guest_closure_size "$port" "${subst_outs[@]}")"
    log "$subject/$workload/$salt: closure is ${paths:-0} paths"
  else
    log "$subject/$workload/$salt: compute-only"
    build_g="$(time_build_guest "$port" "$drv")"
  fi

  # Transfer leg: pull the closure the timed run just produced back to the host.
  # Deleted locally first so this is a real copy rather than a no-op.
  #
  # Skipped in subst mode: that closure is hundreds of megabytes of upstream
  # packages, and copying it back measures nothing the compute-mode copy-back
  # does not already cover.
  if [ "$MODE" = subst ]; then
    build_e="0|0"
  else
    log "$subject/$workload/$salt: copy-back"
    local -a outs
    mapfile -t outs < <(out_paths "$drv")
    nix-store --delete "${outs[@]}" >/dev/null 2>&1 || true
    build_e="$(time_copy_back "$port" "${outs[@]}")"
  fi

  # shellcheck disable=SC2016  # the final argument is a jq program, not shell
  emit \
    --arg subject "$subject" --arg workload "$workload" --arg salt "$salt" \
    --arg arch "$ARCH" --arg order "$order" --arg mode "$MODE" \
    --argjson paths "${paths:-0}" \
    --argjson conn_ns "${conn:-0}" --argjson conn_count "$CONN_COUNT" \
    --argjson pair "$pair" \
    --argjson boot_ns "$boot" \
    --argjson probe_ns "$probe" \
    --argjson compute_ns "${build_g%%|*}" --argjson compute_rc "${build_g##*|}" \
    --argjson copy_ns "${build_e%%|*}" --argjson copy_rc "${build_e##*|}" \
    --arg guest_facts "$facts" \
    --arg nixpkgs_rev "$NIXPKGS_BENCH_REV" --arg repo_rev "$REPO_REV" \
    --arg host_os "$HOST_OS" --arg nix_version "$NIX_VERSION" \
    '{$subject,$workload,$salt,$arch,$pair,$order,$mode,
      closure_paths:$paths,
      conn_ns:$conn_ns, conn_count:$conn_count,
      boot_ns:$boot_ns, probe_ns:$probe_ns,
      compute_ns:$compute_ns, compute_ok:($compute_rc==0),
      copy_ns:$copy_ns, copy_ok:($copy_rc==0),
      guest:($guest_facts|split("|")|{nproc:.[0],mem_kb:.[1],cores:.[2],max_jobs:.[3]}),
      nixpkgs_rev:$nixpkgs_rev, repo_rev:$repo_rev,
      host_os:$host_os, nix_version:$nix_version}'

  stop_vm "$subject"
}

# ABBA, not ABAB.
#
# Thermal and background drift over a session is roughly monotone. ABAB leaves a
# systematic offset that always favours whichever subject runs second; ABBA
# cancels linear drift to first order. This is the main reason the driver is
# hand-rolled -- hyperfine runs all of A then all of B, which is the worst case.
for workload in "${workloads[@]}"; do
  for ((i = 1; i <= PAIRS; i++)); do
    # RUN_ID keeps salts unique across sessions, not just within one. The guest
    # data disk persists between runs, so a salt reused from an earlier session
    # would already be built there -- which assert_not_built correctly rejects,
    # but only after wasting a boot.
    salt="$workload-$ARCH-$RUN_ID-$i"
    a="${subjects[0]}"
    b="${subjects[1]}"
    if [ $((i % 2)) -eq 1 ]; then
      first="$a" second="$b"
    else
      first="$b" second="$a"
    fi
    log "pair $i/$PAIRS ($workload): $first then $second"
    run_one "$first" "$workload" "$salt" "$i" "first"
    log "cooldown ${COOLDOWN}s"
    sleep "$COOLDOWN"
    run_one "$second" "$workload" "$salt" "$i" "second"
    # Guarded with `if` rather than `&&`: under `set -e` a false `&&` as the last
    # command of the loop body would abort the run on the final pair.
    if [ "$i" -lt "$PAIRS" ]; then sleep "$COOLDOWN"; fi
  done
done

log "done. analyse with: bench/analyze.py $BENCH_RESULTS --drift-pct $DRIFT_PCT"
