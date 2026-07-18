#!/usr/bin/env python3
"""Turn a benchmark JSONL into a table that can be pasted into the README.

Two deliberate statistical choices:

* Ratios are combined with a *geometric* mean. Speedups are multiplicative, so
  the arithmetic mean of a set of ratios is biased upward -- a pair that runs 2x
  faster and one that runs 2x slower average to 1.25x arithmetically and 1.0x
  geometrically. Only the latter is meaningful.

* Absolute times are reported as median and IQR, never mean +/- stddev. Build
  times are right-skewed and left-truncated (there is a floor, no ceiling), so
  stddev overstates the spread and the mean chases outliers.

The drift filter is applied by a rule fixed before the run, not chosen after
looking at the data.
"""

import argparse
import json
import math
import random
import statistics
import sys
from collections import defaultdict

NS_PER_S = 1e9


def load(path):
    with open(path) as fh:
        return [json.loads(line) for line in fh if line.strip()]


def geometric_mean(xs):
    return math.exp(statistics.fmean(math.log(x) for x in xs))


def bootstrap_ci(ratios, iterations=10000, alpha=0.05, seed=0):
    """Percentile bootstrap CI over pairs -- makes no normality assumption."""
    if len(ratios) < 2:
        return (float("nan"), float("nan"))
    rng = random.Random(seed)
    means = []
    for _ in range(iterations):
        sample = [rng.choice(ratios) for _ in ratios]
        means.append(geometric_mean(sample))
    means.sort()
    lo = means[int(alpha / 2 * iterations)]
    hi = means[int((1 - alpha / 2) * iterations) - 1]
    return (lo, hi)


def iqr(xs):
    if len(xs) < 2:
        return 0.0
    q = statistics.quantiles(xs, n=4)
    return q[2] - q[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--drift-pct", type=float, default=5.0)
    ap.add_argument("--phase", choices=["compute", "copy"], default="compute")
    args = ap.parse_args()

    rows = load(args.results)
    if not rows:
        sys.exit("no rows")

    field = "compute_ns" if args.phase == "compute" else "copy_ns"
    okfield = "compute_ok" if args.phase == "compute" else "copy_ok"

    # Index by (workload, arch, pair) so A and B meet as a pair.
    pairs = defaultdict(dict)
    for r in rows:
        pairs[(r["workload"], r["arch"], r["pair"])][r["subject"]] = r

    subjects = sorted({r["subject"] for r in rows})
    if len(subjects) != 2:
        sys.exit(f"expected exactly 2 subjects, got {subjects}")
    a, b = subjects

    meta = rows[0]
    mode = meta.get("mode", "compute")
    print(f"# {args.results}  phase={args.phase}  mode={mode}")
    print(
        f"# nixpkgs={meta['nixpkgs_rev'][:12]} repo={meta['repo_rev'][:12]} "
        f"macOS={meta['host_os']} nix={meta['nix_version']}"
    )
    g = meta["guest"]
    print(f"# guest: nproc={g['nproc']} cores={g['cores']} max-jobs={g['max_jobs']}")
    if mode == "subst":
        # A substitution time means little without knowing how many paths it
        # covered, and this axis is network-bound so the spread matters more than
        # the median. Say both, loudly.
        paths = {r.get("closure_paths", 0) for r in rows}
        print(f"# closure: {sorted(paths)} paths fetched per run")
        print("# NETWORK-BOUND: includes cache.nixos.org and local uplink variance.")
    print()

    hdr = f"| workload | arch | N | dropped | {a} median | {b} median | {a}/{b} | 95% CI |"
    print(hdr)
    print("|" + "---|" * 8)

    by_workload = defaultdict(list)
    for (workload, arch, _pair), sides in pairs.items():
        by_workload[(workload, arch)].append(sides)

    for (workload, arch), plist in sorted(by_workload.items()):
        ratios, ta, tb, dropped, failed = [], [], [], 0, 0
        for sides in plist:
            if a not in sides or b not in sides:
                dropped += 1
                continue
            ra, rb = sides[a], sides[b]
            if not (ra[okfield] and rb[okfield]):
                failed += 1
                continue
            # Pre-declared drift rule: if the two calibration probes disagree by
            # more than the threshold, the machine was not in the same state for
            # both halves and the pair is not comparable.
            pa, pb = ra["probe_ns"], rb["probe_ns"]
            if abs(pa - pb) / min(pa, pb) * 100 > args.drift_pct:
                dropped += 1
                continue
            ta.append(ra[field] / NS_PER_S)
            tb.append(rb[field] / NS_PER_S)
            ratios.append(ra[field] / rb[field])

        if not ratios:
            note = f"all {failed} failed" if failed else "no usable pairs"
            print(f"| {workload} | {arch} | 0 | {dropped} | - | - | {note} | - |")
            continue

        gm = geometric_mean(ratios)
        lo, hi = bootstrap_ci(ratios)
        note = f"{dropped}" + (f" +{failed} failed" if failed else "")
        print(
            f"| {workload} | {arch} | {len(ratios)} | {note} "
            f"| {statistics.median(ta):.1f}s ±{iqr(ta):.1f} "
            f"| {statistics.median(tb):.1f}s ±{iqr(tb):.1f} "
            f"| {gm:.2f}x | {lo:.2f}–{hi:.2f} |"
        )

        # Per-path cost is the comparable unit across differently sized closures,
        # and it is what makes "many small dependencies" concrete.
        if mode == "subst":
            n = max((s[a].get("closure_paths", 0) for s in plist if a in s), default=0)
            if n:
                print(
                    f"|   ↳ per path | | | | {statistics.median(ta) / n * 1000:.0f} ms "
                    f"| {statistics.median(tb) / n * 1000:.0f} ms | over {n} paths | |"
                )

    # Boot latency and per-connection cost are separate axes with their own
    # units; keep them out of the ratio table so neither can be mistaken for
    # build throughput.
    print()
    print("| subject | boot median | boot IQR | ssh connect | N |")
    print("|" + "---|" * 5)
    boots, conns = defaultdict(list), defaultdict(list)
    for r in rows:
        boots[r["subject"]].append(r["boot_ns"] / NS_PER_S)
        n = r.get("conn_count", 0)
        if n and r.get("conn_ns"):
            conns[r["subject"]].append(r["conn_ns"] / n / 1e6)
    for s in sorted(boots):
        v = boots[s]
        c = f"{statistics.median(conns[s]):.0f} ms" if conns.get(s) else "-"
        print(
            f"| {s} | {statistics.median(v):.1f}s | {iqr(v):.1f}s | {c} | {len(v)} |"
        )
    if conns:
        print()
        print(
            "ssh connect = per-connection cost. vz forks a fresh `sshd -i` per\n"
            "connection over vsock; the QEMU guest runs a persistent sshd. A build\n"
            "graph driven from the host multiplies this by the derivation count."
        )


if __name__ == "__main__":
    main()
