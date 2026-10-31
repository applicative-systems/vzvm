# shellcheck shell=bash
# Boots a real guest through vzvm's on-demand lifecycle: what the unit tests fake.
# Local only: needs Apple silicon and Virtualization.framework, which CI runners lack.
#
# Provided by the wrapper: run_builder, port, idle. The test builder listens on `port`,
# not 31022, so a running nix-darwin builder is left alone.
#
# State (store image, keys) is kept in $VZVM_LIFECYCLE_STATE so later runs skip building
# the store image; the data disk starts fresh every run.

: "${run_builder:?run via nix run .#lifecycle-test}" "${port:?}" "${idle:?}"

state=${VZVM_LIFECYCLE_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/vzvm-lifecycle-test}
mkdir -p "$state/keys"
cd "$state" || exit 1

vzvm_pid() { pgrep -f "bin/vzvm $state/vzvm.json" || true; }

# Before touching any state: it may belong to a run in progress. Looks for the process
# first, since a probing connection would boot that run's guest.
if [ -n "$(vzvm_pid)" ] || (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  echo "127.0.0.1:$port is in use; is another test still running?" >&2
  exit 1
fi

rm -f nixos.qcow2 vzvm.log
[ -f keys/builder_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f keys/builder_ed25519

log=$state/vzvm.log
failures=0
ok() { echo "ok: $1"; }
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

cleanup() {
  local pid
  pid=$(vzvm_pid)
  [ -z "$pid" ] && return
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 80); do
    kill -0 "$pid" 2>/dev/null || return
    sleep 0.5
  done
  kill -KILL "$pid" 2>/dev/null || true
}
trap cleanup EXIT

guest() {
  ssh -p "$port" -i keys/builder_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    builder@127.0.0.1 "$@"
}

# Log lines so far: later waits only look at what came after.
mark() { wc -l <"$log"; }
seen_since() { tail -n "+$(($1 + 1))" "$log" | grep -q "$2"; }
# Waits up to `timeout` seconds for `pattern` after `mark`.
wait_since() {
  local since=$1 pattern=$2 timeout=$3
  for _ in $(seq $((timeout * 10))); do
    seen_since "$since" "$pattern" && return 0
    sleep 0.1
  done
  return 1
}

# A client that connects and is gone at once, without a word: a killed `ssh`.
vanishing_client() {
  exec 3<>"/dev/tcp/127.0.0.1/$port"
  exec 3>&-
}

echo "starting the test builder; the first run builds the store image..."
KEYS=./keys "$run_builder" >"$log" 2>&1 &

## Booting on demand

if wait_since 0 "on demand" 600; then
  sleep 2
  if seen_since 0 "booting guest"; then
    fail "the guest booted without a connection"
  else
    ok "vzvm listens without booting the guest"
  fi
else
  fail "vzvm never came up"
  cat "$log" >&2
  exit 1
fi

start=$SECONDS
if [ "$(guest 'echo up')" = up ]; then
  ok "a cold connection boots the guest and gets a shell ($((SECONDS - start))s)"
else
  fail "no shell on a cold connection"
fi

# shellcheck disable=SC2016 # expands in the guest
stored=$(guest 'echo "lifecycle $(date +%s%N)" >/tmp/f && nix-store --add /tmp/f')
[ -n "$stored" ] || fail "could not add a store path"

## Idling out and back

since=$(mark)
if wait_since "$since" "guest stopped; next connection" $((idle + 40)); then
  ok "the guest stops after ${idle}s without connections"
else
  fail "the guest did not stop when idle"
fi

since=$(mark)
if guest "nix-store --check-validity $stored" && seen_since "$since" "booting guest"; then
  ok "the next connection boots it again, store paths still registered"
else
  fail "after an on-demand reboot, $stored is no longer valid"
fi

## Clients that vanish

# Once a one-sided close left the bridge open until sshd's LoginGraceTime (120s).
sleep 1
since=$(mark)
start=$SECONDS
vanishing_client
if wait_since "$since" "no connections for" $((idle + 5)); then
  ok "a vanished client does not keep the guest up ($((SECONDS - start))s to idle)"
else
  fail "a vanished client kept the guest up past ${idle}s"
fi
wait_since "$since" "guest stopped; next connection" 40 || fail "the guest did not stop"

since=$(mark)
vanishing_client
if wait_since "$since" "client left before vsock" 30; then
  ok "a client that leaves during boot is released"
else
  fail "a client that left during boot was still held"
fi
if wait_since "$since" "guest stopped; next connection" $((idle + 60)); then
  ok "the guest it booted idles out again"
else
  fail "the guest booted for a vanished client stayed up"
fi

## Stopping right after boot

# The kernel ignores ACPI until logind runs: without repeated presses this took 33s.
since=$(mark)
exec 4<>"/dev/tcp/127.0.0.1/$port"
if wait_since "$since" "guest started" 30; then
  sleep 1
  pid=$(vzvm_pid)
  start=$SECONDS
  kill -TERM "$pid"
  while kill -0 "$pid" 2>/dev/null && [ $((SECONDS - start)) -lt 40 ]; do sleep 0.5; done
  took=$((SECONDS - start))
  if kill -0 "$pid" 2>/dev/null; then
    fail "vzvm did not exit within 40s of SIGTERM"
  elif [ "$took" -le 20 ]; then
    ok "SIGTERM just after boot shuts down in ${took}s"
  else
    fail "SIGTERM just after boot took ${took}s, launchd kills after 20s"
  fi
else
  fail "the guest did not start for the held connection"
fi
exec 4>&-

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s); log: $log" >&2
  exit 1
fi
echo "all lifecycle checks passed"
