# Migrating from `darwin.linux-builder` to `darwin.linux-builder-vz`

How to replace the QEMU-based Linux builder on an existing nix-darwin machine.

It is a single `darwin-rebuild switch`. The one thing worth understanding first is why
that is not circular.

## Why this is not a chicken-and-egg problem

The vz builder's guest system is a NixOS closure for `aarch64-linux`. Most of it comes
from `cache.nixos.org`, but the top-level system derivation is specific to your
configuration, so it has to be built — and building it needs a Linux builder, which on a
Mac is the very thing being replaced.

That resolves itself. `darwin-rebuild switch` realises the whole new system closure
_before_ it activates anything, and the new guest is part of that closure. The old QEMU
builder is still running throughout the build, so it is what builds the new guest; only
once that has succeeded does activation stop it and start the replacement. The ordering
is structural, not a race, so no separate bootstrap step is needed.

What this does not survive is having no builder at all to start from — see the
prerequisites. The thing that actually tends to go wrong on first start is the leftover
data disk, covered in step 1.

## Prerequisites

- **`aarch64-darwin`.** The only supported host platform.
- **macOS 13 or newer.**
- **Rosetta installed:**

  ```
  softwareupdate --install-rosetta --agree-to-license
  ```

  The builder fails at startup with instructions if it is missing, rather than
  quietly dropping `x86_64-linux` from the systems it advertises.

- **A working existing builder**, to bootstrap with.

Check Rosetta and the current builder before starting:

```
sudo launchctl list | grep linux-builder
nix build --impure --expr '(import <nixpkgs> { system = "aarch64-linux"; }).hello' --no-link
```

## Step 1 — switch the builder over

Add the flake input, then apply the overlay and point `nix.linux-builder` at the vz
package from a nix-darwin module:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    vzvm.url = "github:applicative-systems/vzvm";
  };

  outputs =
    { nix-darwin, vzvm, ... }:
    {
      darwinConfigurations.myhost = nix-darwin.lib.darwinSystem {
        modules = [
          (
            { pkgs, ... }:
            {
              nixpkgs.hostPlatform = "aarch64-darwin";
              nixpkgs.overlays = [ vzvm.overlays.default ];

              nix.linux-builder = {
                enable = true;
                package = pkgs.darwin.linux-builder-vz;

                # Required. Without x86_64-linux the builder never advertises it, and
                # Rosetta — the entire reason for this backend — goes unused.
                systems = [
                  "aarch64-linux"
                  "x86_64-linux"
                ];
              };
            }
          )
          # ... your other modules
        ];
      };
    };
}
```

Without flakes, add the overlay from a path —
`nixpkgs.overlays = [ (import /path/to/vzvm/overlay.nix) ];` — and set
`nix.linux-builder.package` the same way.

Unless `nix.linux-builder.ephemeral` is set, delete the QEMU builder's data disk first.
The vz backend has to reuse that filename, but writes a raw image there and refuses to
misread a genuine qcow2:

```
sudo rm -f /var/lib/linux-builder/nixos.qcow2
```

With `ephemeral = true` this is unnecessary — the launchd job deletes the file before
every start.

Then:

```
darwin-rebuild switch --flake .
```

The build step takes a while the first time: the old builder compiles a NixOS system for
`aarch64-linux` and downloads most of its closure. Afterwards nix-darwin stops the QEMU
builder, installs the new launchd job, and starts it.

Everything else about `nix.linux-builder` keeps working unchanged: `ephemeral`,
`maxJobs`, `workingDirectory`, and `config`. The host still listens on port 31022 and the
guest presents the same committed host key, so no `known_hosts` or `/etc/nix/machines`
changes are needed — only the transport behind that port changes, from TCP forwarding to
vsock.

### First start is slower than later ones

On the first start the runner builds a read-only erofs image of the guest's store —
roughly a gigabyte, a minute or so — and creates the data disk. The image is cached
in the working directory under a name derived from the closure's hash, so subsequent
starts reuse it and the VM is up in well under a minute. The image is rebuilt only
when the guest system changes, and stale ones are removed automatically.

## Step 2 — verify

```
# The daemon is running.
sudo launchctl list | grep linux-builder

# The guest answers on the port nix-darwin expects.
ssh -p 31022 -i /etc/nix/builder_ed25519 builder@127.0.0.1 uname -m     # aarch64

# Rosetta is wired up inside the guest.
ssh -p 31022 -i /etc/nix/builder_ed25519 builder@127.0.0.1 \
  'ls /proc/sys/fs/binfmt_misc/rosetta && mount | grep rosetta'

# A native build.
nix build --impure --expr \
  '(import <nixpkgs> { system = "aarch64-linux"; }).hello' --no-link

# The one that matters: x86_64 through Rosetta. This should take seconds.
# Under QEMU's TCG emulation the same build takes minutes.
nix build --impure --expr \
  '(import <nixpkgs> { system = "x86_64-linux"; }).hello' --no-link
```

If the last command completes in seconds rather than minutes, Rosetta is doing its
job and the migration is done.

## Rolling back

The old builder is untouched by any of this — `pkgs.darwin.linux-builder` still
exists and still works. Reverting is one line:

```nix
nix.linux-builder.package = pkgs.darwin.linux-builder;   # or just remove the line
```

followed by `darwin-rebuild switch`. Keep `systems` or drop it; the QEMU builder can
still advertise `x86_64-linux`, it is simply slow at it.

## Seeing what the VM is doing

By default the guest console goes to standard output, which under launchd goes
nowhere useful. When debugging, send it to a file instead:

```nix
nix.linux-builder.config = {
  virtualisation.vz.console = "file";
  virtualisation.vz.consoleLog = "./console.log";
};
```

The path is relative to `nix.linux-builder.workingDirectory`, so this writes to
`/var/lib/linux-builder/console.log`. That file contains the guest's full boot log,
which is where to look for anything that goes wrong after the VM starts.

Diagnostics from the VM monitor itself — preflight failures, port conflicts, vsock
errors — go to standard error and appear in the launchd log.

## Troubleshooting

**`preflight: Rosetta is not installed`**
Run `softwareupdate --install-rosetta --agree-to-license`. The builder refuses to
start rather than silently losing the ability to build `x86_64-linux`.

**`preflight: ... is a QEMU qcow2 image, not a raw disk`**
The data disk has to be named `<hostName>.qcow2` because `nix.linux-builder.ephemeral`
deletes exactly that path, but the vz backend writes a raw image there. The file left
behind by the QEMU builder is a genuine qcow2, and is rejected rather than misread. This
is the step 1 cleanup, skipped:

```
sudo rm -f /var/lib/linux-builder/nixos.qcow2
```

then `sudo launchctl kickstart -k system/org.nixos.linux-builder`.

**`cannot listen on 127.0.0.1:31022: Address already in use`**
Another builder VM is still running — usually the old QEMU one, if a switch half
failed. `sudo launchctl bootout system/org.nixos.linux-builder`, confirm no
`qemu-system-aarch64` process remains, then start it again with
`sudo launchctl kickstart -k system/org.nixos.linux-builder`.

**The daemon restarts in a loop**
`KeepAlive` is set, so a failing VM is restarted forever. The reason is on the first
line of the launchd log; the exit code distinguishes the cause: 69 preflight, 70
runtime, 78 configuration, 71 the guest itself stopped with an error.

**Builds compile from source instead of downloading**
The guest serves SSH only once `network-online.target` is reached, precisely so this
does not happen. If it still does, the guest has no route to `cache.nixos.org`; check
from inside the guest with
`ssh -p 31022 -i /etc/nix/builder_ed25519 builder@127.0.0.1 'curl -sI https://cache.nixos.org/nix-cache-info'`.

**`nix.linux-builder.config` changes do not take effect**
Changing the guest configuration changes the closure, so the store image is rebuilt
on the next start — the first start after such a change is slow again.

## What is and is not persistent

The guest's writable store lives on the data disk, so anything built there survives a
restart — unless `nix.linux-builder.ephemeral` is set, in which case the disk is
deleted on every start and the guest begins with an empty writable store each time.
That is the same behaviour as the QEMU builder.

The cached store image is not affected by `ephemeral`; it is derived from the guest
system, not from anything the guest wrote.
