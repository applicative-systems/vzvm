#!/usr/bin/env bash
# Runs the installed, entitled vzvm binary: exit codes, signals, listener startup.
# Never boots a guest: on-demand mode only starts one when a connection arrives, so this
# needs no hypervisor and runs anywhere vzvm does.
#
# usage: cli.sh <path to vzvm>
set -uo pipefail

vzvm=$1
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$work"' EXIT
cd "$work" || exit 1

failures=0
ok() { echo "ok: $1"; }
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# Just enough of an arm64 Image header: the magic "ARM\x64" at 0x38.
head -c 56 /dev/zero >Image
printf 'ARMd' >>Image
head -c 8 /dev/zero >>Image
echo initrd >initrd
printf '\x1f\x8b\x08\x00' >Image.gz
printf 'QFI\xfb' >qemu.qcow2

port=$((20000 + RANDOM % 40000))

# A config that starts and waits for connections, with the top-level keys of the JSON
# object `overrides` replacing the defaults.
config() {
  local name=$1 overrides=${2:-"{}"}
  jq -n \
    --arg work "$work" --arg listen "127.0.0.1:$port" --argjson overrides "$overrides" \
    '{
      cpuCount: 1,
      memorySizeMiB: 512,
      kernel: "\($work)/Image",
      initrd: "\($work)/initrd",
      cmdline: "console=hvc0",
      console: { mode: "file", path: "\($work)/console.log" },
      vsock: { forwards: [{ listen: $listen, vsockPort: 22 }] },
      idleTimeoutSeconds: 60
    } + $overrides' >"$name"
}

# The exit code of a run that must end by itself. A hang fails rather than blocks.
expect_exit() {
  local description=$1 expected=$2
  shift 2
  timeout 10 "$vzvm" "$@" >run.log 2>&1
  local code=$?
  if [ "$code" -eq "$expected" ]; then
    ok "$description ($code)"
  else
    fail "$description: exit $code, expected $expected"
    sed 's/^/    /' run.log >&2
  fi
}

# Waits up to 10s for `pattern` in `log`.
wait_for() {
  local log=$1 pattern=$2
  for _ in $(seq 100); do
    grep -q "$pattern" "$log" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# Sends `signal` to `pid`, then expects exit `expected` within `limit` seconds.
expect_signal_exit() {
  local description=$1 pid=$2 signal=$3 expected=$4 limit=$5
  local start=$SECONDS
  kill -s "$signal" "$pid"
  wait "$pid"
  local code=$? took=$((SECONDS - start))
  if [ "$code" -eq "$expected" ] && [ "$took" -le "$limit" ]; then
    ok "$description ($code after ${took}s)"
  else
    fail "$description: exit $code after ${took}s, expected $expected within ${limit}s"
  fi
}

## Usage

expect_exit "no arguments is a usage error" 64
expect_exit "a flag is a usage error" 64 --help
expect_exit "two arguments is a usage error" 64 a.json b.json

## Configuration errors

expect_exit "a missing config file is a config error" 78 "$work/missing.json"
echo '{ "cpuCount": ' >broken.json
expect_exit "invalid JSON is a config error" 78 broken.json
config unknown.json '{"idleTimeout": 60}'
expect_exit "an unknown key is a config error" 78 unknown.json
config idle-zero.json '{"idleTimeoutSeconds": 0}'
expect_exit "a zero idle timeout is a config error" 78 idle-zero.json
config idle-no-forward.json '{"vsock": {"forwards": []}}'
expect_exit "an idle timeout without forwards is a config error" 78 idle-no-forward.json
# Only detected once the proxies start, after preflight; still a config error.
config bad-listen.json '{"vsock": {"forwards": [{"listen": "127.0.0.1:ssh", "vsockPort": 22}]}}'
expect_exit "a malformed listen address is a config error" 78 bad-listen.json

## Preflight failures

config no-kernel.json "{\"kernel\": \"$work/missing\"}"
expect_exit "a missing kernel fails preflight" 69 no-kernel.json
config gz-kernel.json "{\"kernel\": \"$work/Image.gz\"}"
expect_exit "a compressed kernel fails preflight" 69 gz-kernel.json
config qcow2.json "{\"disks\": [{\"path\": \"$work/qemu.qcow2\"}]}"
expect_exit "a qcow2 disk fails preflight" 69 qcow2.json

## Signals while idle

config idle.json
for signal in TERM INT; do
  "$vzvm" idle.json >"idle-$signal.log" 2>&1 &
  pid=$!
  if wait_for "idle-$signal.log" "on demand"; then
    expect_signal_exit "SIG$signal while no guest runs exits cleanly" $pid "$signal" 0 2
  else
    fail "SIG$signal: vzvm never came up"
    cat "idle-$signal.log" >&2
  fi
done

## A previous instance still holding the port

"$vzvm" idle.json >first.log 2>&1 &
first=$!
wait_for first.log "on demand" || fail "first instance never came up"

"$vzvm" idle.json >second.log 2>&1 &
second=$!
if wait_for second.log "waiting for 127.0.0.1:$port"; then
  ok "a second instance waits for the port instead of failing"
else
  fail "second instance did not wait for the port"
  cat second.log >&2
fi
# The wait must not block signal handling.
expect_signal_exit "SIGTERM while waiting for the port exits promptly" $second TERM 0 2

# What launchd does on restart: the new instance takes over once the old one is gone.
"$vzvm" idle.json >third.log 2>&1 &
third=$!
wait_for third.log "waiting for" || fail "third instance did not wait for the port"
expect_signal_exit "the old instance exits on SIGTERM" $first TERM 0 2
if wait_for third.log "forwarding 127.0.0.1:$port"; then
  ok "the waiting instance takes over the port"
else
  fail "the waiting instance never took over the port"
  cat third.log >&2
fi
expect_signal_exit "the new instance exits on SIGTERM" $third TERM 0 2

if [ $failures -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
