# Benchmarks

Measures this repo's Virtualization.framework builder against the upstream QEMU
one. The point is to find out where it is faster, by how much, and where it is
not — not to produce a headline number.

## Subjects

| id  | what                                                                                                                                |
| --- | ----------------------------------------------------------------------------------------------------------------------------------- |
| A1  | `darwin.linux-builder` + `boot.binfmt.emulatedSystems = [ "x86_64-linux" ]` (qemu-user TCG inside an HVF-accelerated aarch64 guest) |
| A2  | `darwin.linux-builder-x86_64` (full x86_64 guest under `qemu-system-x86_64`, no HVF — whole-system TCG)                             |
| B   | `darwin.linux-builder-vz` (this repo; aarch64 guest under Virtualization.framework, x86_64 via Rosetta)                             |

**A1 is the fair comparator.** Same guest architecture, same hypervisor
acceleration; the only difference is the x86 translation layer. Any ratio quoted
as "vs QEMU" must be B/A1. A2 is a footnote — it produces a far more dramatic
number by changing two variables at once, and quoting it while describing A1's
mechanism would be dishonest.

**Stock `darwin.linux-builder` cannot build `x86_64-linux` at all.** It sets no
`boot.binfmt.*` and no `extra-platforms`; verified against the pinned nixpkgs.
That is a capability difference, not a speed difference, and is reported
separately from any ratio.

All three are pinned to identical `cores`, `memorySize`, and `diskSize` in
`subjects.nix`. Both backends default to `virtualisation.cores = 1`, so an
unpinned comparison would be single-core — fair, but not how anyone runs a
builder. They also get distinct ports (31023/31024/31025) and working
directories, because all three ship the same committed SSH host key and would
otherwise collide on 31022 and `/var/lib/linux-builder`.

## Axes

Each run measures two things separately, because they have different causes:

- **compute-only** — `nix-store --realise` inside the guest, with dependencies
  pre-warmed and substituters emptied. No host↔guest transfer, no host daemon.
- **copy-back** — `nix-copy-closure --from` the guest, timed on its own.

Driving the build from the host via `--builders` would have been a more faithful
"end-to-end", but it is a dead end here: the nix daemon runs as root, so it uses
root's ssh config and `known_hosts`, and the harness's `StrictHostKeyChecking` and
`IdentityFile` options never reach it. Making that work needs a system-wide
`ssh_config` entry per subject port — another sudo dependency, for a number that
decomposes into these two anyway.

Beyond that:

- **x86_64-linux throughput** — the headline. Rosetta vs qemu-user.
- **aarch64-linux throughput** — the _control_. Both guests are aarch64 under HVF,
  so this should be near parity. A delta above ~10% here means the harness is
  broken, or the workload is I/O-bound rather than CPU-bound, and the x86_64
  number should not be trusted until it is explained.
- **boot latency** — reported separately, in seconds, never folded into the ratio
  table.

## Workloads

`workloads.nix`. Real packages, forced to miss every cache by adding a `SALT` env
var via `overrideAttrs`. Verified against the pinned nixpkgs: this changes the
target's drv hash while leaving its `inputs` byte-identical, so exactly one
package rebuilds and every dependency stays substitutable.

W0 is a calibration probe, not a result. It runs immediately before each timed
workload; if the two probes in an A/B pair disagree by more than `--drift-pct`
(default 5%), the machine was not in the same thermal state for both halves and
the pair is discarded. The rule is fixed in advance — post-hoc outlier removal is
how benchmarks lie.

W4 (`ffmpeg`, full of hand-written x86 SIMD) is deliberately adversarial to
Rosetta, whose AVX coverage is limited. It may be slow or may fail outright.
Either outcome is a result and goes in the table at the same size as the wins.

### Beyond compute

The compute workloads above deliberately exclude everything except CPU: deps are
pre-warmed and the timed build runs with substituters emptied. Three further axes
cover what that subtracts.

**`subst` — substitution throughput.** A closure of ~400 small paths fetched from
`cache.nixos.org` into a _wiped_ guest store. This is the "a derivation with many
small dependencies feels far slower than its compute cost explains" case. Not
salted: salting would force a build, and the point is to measure fetching —
hundreds of small NARs, each its own HTTPS request, through SLiRP for QEMU versus
vmnet NAT for vz.

```sh
bench/run.sh --mode subst --workloads subst --arch x86_64-linux --pairs 7
```

`--mode subst` deletes `nixos.qcow2` before each boot so substitution genuinely
has work to do, skips pre-warming, and leaves substituters enabled. It is
genuinely network-bound, so it carries `cache.nixos.org` and uplink variance —
expect a much wider spread than the compute axis, use more pairs, and report the
IQR next to the median. `analyze.py` prints a `NETWORK-BOUND` banner and a
per-path cost so the number is interpretable across different closure sizes.

**`churn` — many tiny derivations.** 300 salted trivial builds realised in one
go, measuring guest-side build scheduling rather than bandwidth. Runs in normal
compute mode:

```sh
bench/run.sh --workloads churn --arch aarch64-linux --pairs 7
```

**Per-connection SSH cost.** Recorded automatically on _every_ run, in the boot
table. This is the axis where vz is most likely to lose: it serves SSH over vsock
from a socket unit with `Accept = true`, forking a fresh `sshd -i` per
connection, where the QEMU guest runs a persistent sshd. A build graph driven
from the host opens a connection per operation, so this cost is multiplied by the
derivation count.

Note that `churn` does **not** measure that: it realises everything inside a
single SSH session, so it captures guest-side scheduling instead. The two are
complementary and neither substitutes for the other.

## Running

```sh
# once per machine: unprivileged copy of the builder key (the only sudo needed)
bench/setup-keys.sh

# WITH THE STOCK BUILDER STILL RUNNING: build the subject closures.
# They are aarch64-linux, so this needs a Linux builder -- the one we are about
# to stop. Skipping this step is a chicken-and-egg deadlock.
nix develop .#bench
bench/run.sh --prepare --subjects a1,b

# now stop the nix-darwin builder -- it holds port 31022
sudo launchctl bootout system/org.nixos.linux-builder

caffeinate -dimsu bench/run.sh --arch x86_64-linux --workloads w1 --pairs 3

bench/analyze.py bench/results/<stamp>.jsonl

# restore the builder
sudo launchctl bootstrap system /Library/LaunchDaemons/org.nixos.linux-builder.plist
```

While the builder is stopped, any `nix build` needing `aarch64-linux` or
`x86_64-linux` fails. That is why `--prepare` exists and why it must run first.
Once the subjects are realised they are cached, and the timed run needs no
builder other than the subject under test.

`--prepare` must be re-run whenever a subject's closure changes — after editing
`subjects.nix`, bumping nixpkgs, or changing `cores`/`memorySize` (which alter
`nix.settings` and so the guest's `system.build.toplevel`).

`setup-keys.sh` exists because `add-keys` generates a fresh keypair per working
directory and calls `sudo --reset-timestamp` whenever it differs from the one in
`/etc/nix`. With three subjects in three working directories that would prompt for
a password mid-run and repeatedly overwrite the system builder key. Seeding all
three with the existing key avoids the sudo branch entirely.

Run on AC power with the lid open and no other GUI apps. Pairs are run **ABBA**,
not ABAB: session drift is roughly monotone, and ABAB leaves a systematic offset
favouring whichever subject runs second. This is also why the driver is
hand-rolled — `hyperfine` runs all of A then all of B, the worst possible order
here, and reports mean ± stddev, which is the wrong statistic for
right-skewed build times.

`analyze.py` reports the **geometric** mean of per-pair ratios with a bootstrap
95% CI, and median/IQR for absolute times. Ratios are multiplicative, so an
arithmetic mean of them is biased.

## Reporting rules

Anything published from this harness must carry:

- Hardware, macOS build, nix version, nixpkgs rev, and this repo's commit. Rosetta
  and Virtualization.framework both change materially across macOS releases, and
  QEMU's aarch64 TCG has improved a lot recently.
- N, the number of discarded pairs, and the CI. The raw `results/*.jsonl` stays
  in-repo so every figure is checkable.
- The per-workload table, not one number. Compile-bound C is Rosetta's best case.
- Where B **loses**. A benchmark containing only wins reads as marketing and gets
  discounted wholesale, including the parts that are true.
- That builds were pre-warmed with zero network I/O, and so exclude substitution
  time — which in real use often dominates.

Two claims currently in the top-level `README.md` are what this exists to check:

- _"~15x slower under TCG"_ — must state which comparator it is against. Against
  A1 and against A2 these are very different numbers.
- _"within ~20% of native"_ — not well-formed as written. An x86_64 build and an
  aarch64 build of the same package are different amounts of work, so the ratio
  between them is a workload-level observation, not a measure of Rosetta's
  instruction-level overhead. Restate or drop it.

Also note that B's store-image cache (`vz-vm.nix`, `storeImageName`) makes warm
restart look good against upstream's rebuild-every-start — but that is an
_upstream design_ cost, not a _QEMU_ cost. A QEMU backend with the same caching
would close most of that gap. Conflating "our backend is faster" with "we also
fixed an unrelated inefficiency" is exactly what a reviewer of an upstream PR
will catch.
