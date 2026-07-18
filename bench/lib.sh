# shellcheck shell=bash
# Helpers for the A/B builder benchmark. Sourced by run.sh.

BENCH_STATE_DIR="${BENCH_STATE_DIR:-/tmp/vzvm-bench}"
# Not /etc/nix/builder_ed25519 directly: that is 0600 root:nixbld and the harness
# runs unprivileged. `bench/setup-keys.sh` places a readable copy here.
BENCH_KEY="${BENCH_KEY:-$BENCH_STATE_DIR/builder_ed25519}"

# Subject -> host port. Must match bench/subjects.nix.
subject_port() {
  case "$1" in
  a1) echo 31023 ;;
  a2) echo 31024 ;;
  b) echo 31025 ;;
  *)
    echo "unknown subject: $1" >&2
    return 1
    ;;
  esac
}

die() {
  echo "bench: $*" >&2
  exit 1
}

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

# Nanosecond wall clock. macOS `date` has no %N, and depending on python3 breaks
# outside the devshell (the system python3 is an Xcode stub). bash 5's
# EPOCHREALTIME needs nothing external.
now_ns() {
  local t=$EPOCHREALTIME
  # "seconds.microseconds" -> ns. 10# forces base 10 despite leading zeros.
  echo $((${t%.*} * 1000000000 + 10#${t#*.} * 1000))
}

# Refuse to run while nix-darwin's builder owns 31022 and /var/lib/linux-builder.
# Sharing a working directory between subjects would let one subject read
# another's store image; sharing a port makes "which VM answered?" unanswerable.
assert_no_stock_builder() {
  if nc -z 127.0.0.1 31022 2>/dev/null; then
    die "the nix-darwin builder is live on 31022. Stop it first:
  sudo launchctl bootout system/org.nixos.linux-builder
and re-enable it when you are done."
  fi
}

# Exactly one subject may be running, and it must own the port we expect.
assert_only_subject() {
  local subject="$1" port
  port="$(subject_port "$subject")"
  local other
  for other in a1 a2 b; do
    [ "$other" = "$subject" ] && continue
    if nc -z 127.0.0.1 "$(subject_port "$other")" 2>/dev/null; then
      die "subject '$other' is still listening while running '$subject'"
    fi
  done
  nc -z 127.0.0.1 "$port" 2>/dev/null || die "subject '$subject' is not listening on $port"
}

ssh_guest() {
  local port="$1"
  shift
  ssh -q -p "$port" \
    -i "$BENCH_KEY" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=10 \
    builder@127.0.0.1 "$@" </dev/null
}

# A single liveness probe, bounded in wall time.
#
# ConnectTimeout is not enough on its own: QEMU's user-mode hostfwd binds the
# host port immediately, so the TCP connect succeeds long before the guest sshd
# exists and ssh then blocks forever waiting for a banner. An unbounded probe
# also defeats wait_ssh's deadline, which is only evaluated between iterations.
ssh_probe() {
  local port="$1" pid n=0
  ssh_guest "$port" true 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 150 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  wait "$pid"
}

# `create-builder` runs `add-keys`, which generates a fresh keypair in the working
# directory and then, whenever it differs from /etc/nix/builder_ed25519.pub, calls
# `sudo --reset-timestamp` to install it. Three subjects have three working
# directories, so left alone that would prompt for a password in the middle of a
# timed run *and* repeatedly overwrite the system builder key.
#
# Seeding every subject with the key already installed in /etc/nix makes
# add-keys' `cmp` succeed, so it never reaches the sudo branch.
seed_keys() {
  [ -r "$BENCH_KEY" ] || die "no readable builder key at $BENCH_KEY. Run:
  bench/setup-keys.sh"
  local s
  for s in a1 a2 b; do
    mkdir -p "$BENCH_STATE_DIR/$s/keys"
    install -m 600 "$BENCH_KEY" "$BENCH_STATE_DIR/$s/keys/builder_ed25519"
    install -m 644 "$BENCH_KEY.pub" "$BENCH_STATE_DIR/$s/keys/builder_ed25519.pub"
  done
}

start_vm() {
  local subject="$1" installer="$2" port
  port="$(subject_port "$subject")"
  mkdir -p "$BENCH_STATE_DIR/$subject"
  log "starting $subject"
  # `set -m` puts the background job in its own process group, so stop_vm can
  # signal the whole tree. create-builder is a wrapper that execs run-builder
  # which execs the VM; killing just the recorded pid leaves the VM orphaned,
  # still holding its port and its vCPUs.
  set -m
  # stdin MUST be /dev/null. QEMU's `-nographic` reads stdin for the serial
  # console, and `set -m` puts this job in its own process group -- so reading the
  # terminal raises SIGTTIN and the kernel stops the VM before it executes a
  # single instruction. It presents as a silent hang with 0% CPU.
  #
  # create-builder resolves its image directory from $PWD.
  (cd "$BENCH_STATE_DIR/$subject" && exec "$installer/bin/create-builder") \
    </dev/null >"$BENCH_STATE_DIR/$subject/vm.log" 2>&1 &
  echo $! >"$BENCH_STATE_DIR/$subject/vm.pid"
  set +m
}

# Time from launch to first successful SSH. "Usable" has to mean one thing for
# both backends -- boot-log greps differ between them and are not comparable.
wait_ssh() {
  local subject="$1" start="$2" port deadline
  port="$(subject_port "$subject")"
  deadline=$((SECONDS + 600))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ssh_probe "$port"; then
      echo $(($(now_ns) - start))
      return 0
    fi
    sleep 0.1
  done
  die "$subject never became reachable on $port after 600s.
Check $BENCH_STATE_DIR/$subject/vm.log, and whether the VM process is stopped:
  ps -o pid,stat,command -p \$(cat $BENCH_STATE_DIR/$subject/vm.pid)
STAT 'T' means it was stopped by SIGTTIN/SIGTTOU on the terminal."
}

stop_vm() {
  local subject="$1"
  local pidfile="$BENCH_STATE_DIR/$subject/vm.pid"
  [ -f "$pidfile" ] || return 0
  local pid
  pid="$(cat "$pidfile")"
  # Negative pid signals the whole process group.
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  # Give the VM its shutdown path before forcing it.
  local deadline=$((SECONDS + 60))
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
  kill -9 -- "-$pid" 2>/dev/null || true
  rm -f "$pidfile"

  # The group kill misses a VM that reparented away from the group. Match on this
  # subject's own state directory so only our processes are ever targeted -- never
  # a bare `pkill vzvm`, which would hit the user's real builder.
  pkill -f "$BENCH_STATE_DIR/$subject/" 2>/dev/null || true

  # The port must actually be free before the next subject starts, or the next
  # run silently measures the wrong VM.
  local port
  port="$(subject_port "$subject")"
  deadline=$((SECONDS + 30))
  while nc -z 127.0.0.1 "$port" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
  if nc -z 127.0.0.1 "$port" 2>/dev/null; then
    die "$subject still holds port $port after shutdown; a VM was orphaned"
  fi
  log "stopped $subject"
}

# Record what the guest actually got, rather than what we asked for. A config
# that silently failed to apply is the most likely way this comparison goes wrong.
# The guest has `nix-command` disabled, so `nix config show` errors out. Read the
# settings from nix.conf directly instead of enabling an experimental feature
# just to observe the machine.
guest_facts() {
  local port="$1"
  # shellcheck disable=SC2016  # deliberately unexpanded: this runs in the guest
  ssh_guest "$port" '
    printf "%s|%s|%s|%s" \
      "$(nproc)" \
      "$(awk "/MemTotal/ {print \$2}" /proc/meminfo)" \
      "$(awk -F"= *" "/^cores *=/    {print \$2}" /etc/nix/nix.conf)" \
      "$(awk -F"= *" "/^max-jobs *=/ {print \$2}" /etc/nix/nix.conf)"
  '
}

# Copy a derivation (not its outputs) into the guest store. `nix-store --realise`
# on the guest can only build a .drv that the guest actually has. This is done
# outside every timed region.
copy_drv() {
  local port="$1" drv="$2"
  NIX_SSHOPTS="-p $port -i $BENCH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    nix-copy-closure --to builder@127.0.0.1 "$drv" >/dev/null 2>&1
}

# Fixed-cost computation on the HOST, used to detect thermal drift between the
# two halves of a pair.
#
# This must NOT run in the guest. The guest probe would be slowed by the very
# translation layer under test -- a1's probe is slow precisely because a1 is slow
# -- so every pair would look drifted and be discarded. Measuring the host tells
# us about the machine's state, which is the confounder we actually care about.
host_probe() {
  local f="$BENCH_STATE_DIR/probe.dat" start
  [ -e "$f" ] || head -c 67108864 /dev/zero >"$f"
  start="$(now_ns)"
  # Eight passes, not four: at ~0.6s the run-to-run spread was ~4%, uncomfortably
  # close to the 5% drift threshold. A longer probe averages that noise down so
  # the filter reacts to real thermal drift rather than to its own jitter.
  local _n
  for _n in 1 2 3 4 5 6 7 8; do
    shasum -a 256 "$f" >/dev/null 2>&1 || die "host_probe failed"
  done
  echo $(($(now_ns) - start))
}

# Cost of N sequential SSH connections.
#
# This is the one measurement that exercises the backends' connection designs
# head-on: vz serves SSH over vsock from a socket unit with `Accept = true`, so
# every connection forks a fresh `sshd -i`, where the QEMU guest runs a
# persistent sshd behind SLiRP hostfwd. A build graph of many small derivations
# driven from the host opens a connection per operation, so per-connection cost
# is multiplied by the derivation count.
#
# Note this is NOT what the `churn` workload measures: churn realises everything
# inside one session, so it captures guest-side build scheduling instead. The two
# are complementary and neither substitutes for the other.
time_ssh_connections() {
  local port="$1" count="$2" start i
  start="$(now_ns)"
  for ((i = 0; i < count; i++)); do
    ssh_guest "$port" true >/dev/null 2>&1 || {
      echo "0"
      return 1
    }
  done
  echo $(($(now_ns) - start))
}

# Delete the guest's writable store, so the next boot starts with only the
# read-only erofs base image and substitution genuinely has work to do.
#
# Both backends name this disk `nixos.qcow2` in the working directory (upstream
# from `system.name`, vz from the hostName hack in nix-builder-vz-vm.nix), so one
# path covers both. The store *image* is deliberately kept: rebuilding that is a
# boot-latency cost, measured on its own axis, not part of substitution.
wipe_guest_store() {
  local subject="$1"
  rm -f "$BENCH_STATE_DIR/$subject/nixos.qcow2"
}

# Realise with substituters ENABLED and nothing pre-warmed: this measures fetch
# throughput, not compute. Hundreds of small NARs, each its own HTTPS request
# through the guest's network stack -- SLiRP for QEMU, vmnet NAT for vz.
#
# Unlike the compute path this is genuinely network-bound, so it carries the
# variance of cache.nixos.org and the local uplink. That is the honest cost of
# measuring the thing users actually feel; report the spread, not just a median.
time_build_guest_online() {
  local port="$1" drv="$2" start rc
  start="$(now_ns)"
  if ssh_guest "$port" \
    "nix-store --realise '$drv' --log-format raw >/dev/null 2>&1"; then
    rc=0
  else
    rc=1
  fi
  echo "$(($(now_ns) - start))|$rc"
}

# How many store paths the guest ended up with for this output. Gives the
# per-path denominator that makes a substitution number interpretable.
guest_closure_size() {
  local port="$1"
  shift
  # Unique across all outputs: their closures overlap heavily, and double
  # counting would understate the per-path cost.
  ssh_guest "$port" "nix-store -q --requisites $* 2>/dev/null | sort -u | wc -l" | tr -d ' \n'
}

# Realise an *unsalted* variant with substituters allowed, so that the salted,
# timed run afterwards needs zero network. Failures are tolerated: the timed run
# uses empty substituters and will fail loudly if this did not pull enough, which
# is the diagnostic we actually want.
prewarm() {
  local port="$1" drv="$2"
  copy_drv "$port" "$drv"
  ssh_guest "$port" "nix-store --realise '$drv' --log-format raw >/dev/null 2>&1" || true
}

# Realise a derivation entirely inside the guest.
#
# Substituters are emptied rather than passing --offline: with no substituters a
# missing dependency fails loudly and immediately, which tells us the pre-warm was
# incomplete *before* we publish a number. --offline can fail in vaguer ways.
#
# This is the compute-only measurement: no host<->guest NAR transfer, no host
# daemon. Pair it with the end-to-end number; the difference between them is the
# transfer cost measured in situ.
time_build_guest() {
  local port="$1" drv="$2" start rc
  start="$(now_ns)"
  if ssh_guest "$port" \
    "nix-store --realise '$drv' --option substituters '' --log-format raw >/dev/null 2>&1"; then
    rc=0
  else
    rc=1
  fi
  echo "$(($(now_ns) - start))|$rc"
}

# Transfer cost: copy an already-built closure guest -> host.
#
# This replaces driving the build through `--builders`. That route is a dead end
# here: the nix daemon runs as root, so it uses root's ssh config and known_hosts,
# and our StrictHostKeyChecking/IdentityFile options never reach it. Making it
# work needs a system-wide ssh_config entry per subject port, i.e. another sudo
# dependency, for a number we can measure directly instead.
#
# vsock (b) vs QEMU user-mode networking (a1) is exactly what this compares, and
# the total a user feels is this plus the compute-only time.
# Takes every output path as separate arguments -- multi-output derivations are
# the norm, and collapsing them into one argument fails instantly.
time_copy_back() {
  local port="$1" start rc
  shift
  start="$(now_ns)"
  if NIX_SSHOPTS="-p $port -i $BENCH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    nix-copy-closure --from builder@127.0.0.1 "$@" >/dev/null 2>&1; then
    rc=0
  else
    rc=1
  fi
  echo "$(($(now_ns) - start))|$rc"
}

# Output paths of a derivation, one per line -- note the plural.
#
# Two traps here, both of which produced silently-wrong results:
#   - `nix derivation show` reports outputs.out.path as a bare basename with no
#     /nix/store prefix, so it yields an invalid path. The classic query does not.
#   - Many packages are multi-output (zstd has out/bin/dev/man). Capturing this
#     into a scalar gives a multi-line string that breaks every consumer: the
#     copy-back fails instantly, and the cache-miss assertion silently passes
#     because its `nix-store --check-validity` errors on the malformed argument.
# Callers must read this into an array.
out_paths() {
  nix-store --query --outputs "$1"
}

# Both subjects are aarch64-linux guests that advertise x86_64-linux (a1 via
# binfmt, b via Rosetta). Read it from nix.conf rather than `nix config show`,
# which needs nix-command.
guest_systems() {
  # shellcheck disable=SC2016  # deliberately unexpanded: this runs in the guest
  ssh_guest "$1" '
    printf "%s %s" \
      "$(uname -m)-linux" \
      "$(awk -F"= *" "/^extra-platforms *=/ {print \$2}" /etc/nix/nix.conf)"
  ' | awk '{for (i=1;i<=NF;i++) printf "%s%s", (n++?",":""), $i}'
}

# Assert the salt actually bit: the output must be absent from the guest before
# we time anything. A silently-cached run reports a spectacular speedup.
#
# `nix-store --check-validity` is the classic-CLI equivalent of `nix path-info`;
# the guest does not have nix-command enabled.
# Every output must be absent, not just the first: a partially-present closure
# would let some of the work be skipped and still report a clean number.
assert_not_built() {
  local port="$1" drv="$2" out
  local -a outs
  mapfile -t outs < <(out_paths "$drv")
  [ "${#outs[@]}" -gt 0 ] || die "derivation $drv has no outputs"
  for out in "${outs[@]}"; do
    case "$out" in
    /nix/store/*) ;;
    *) die "out_paths returned a non-store path: '$out'" ;;
    esac
    if ssh_guest "$port" "nix-store --check-validity '$out'" >/dev/null 2>&1; then
      die "output $out already present in guest -- salt did not force a miss"
    fi
  done
}

emit() {
  jq -nc "$@" >>"$BENCH_RESULTS"
}
