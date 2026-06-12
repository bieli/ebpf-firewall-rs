# Workshop Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the reproducible workshop environment and prove the full toolchain end to end: a Lima-managed NixOS guest on Apple Silicon that loads a hello-world eBPF program and shows its output in the kernel trace pipe.

**Architecture:** Participants run one Lima + NixOS guest (the only place eBPF can execute, since macOS has no eBPF). A flake provides the in-guest dev environment (Rust nightly, bpf-linker, Aya tooling) and pins the guest kernel. The host's only job is to boot the guest. This plan delivers the `main` branch / "Step 0" state.

**Tech Stack:** Nix flakes, Lima (NixOS template), NixOS guest with pinned kernel + BTF + cgroup v2, Rust nightly, Aya (aya / aya-ebpf), bpf-linker, cargo-generate.

**Important framing:** This is infrastructure bring-up against a stack that has not yet been proven on this hardware. Several tasks are spike-and-verify: run a command, observe real output, and follow the documented branch. Where exact API/attribute names are version-sensitive, the step says which version to pin and how to confirm the real signature, rather than asserting an unverified one. Do not skip the verification commands; they are the tests.

---

## File Structure

Files created by this plan:

- `flake.nix` - dev shell (Rust nightly, bpf-linker, cargo-generate, etc.) and the NixOS guest configuration (pinned kernel, BTF, cgroup v2).
- `flake.lock` - generated; pins all inputs.
- `workshop.yaml` - Lima config that boots the NixOS guest and mounts the repo.
- `Cargo.toml` - workspace manifest (from aya-template, then adjusted).
- `firewall-common/` - shared types crate (from aya-template).
- `firewall-ebpf/` - kernel eBPF crate; holds the hello-world program for Step 0.
- `firewall/` - userspace loader crate; loads + attaches the program.
- `rust-toolchain.toml` - pins the nightly toolchain (from aya-template).
- `README.md` - the workshop map: the step ladder + setup/homework instructions.
- `docs/spike-notes.md` - running log of what actually worked vs. the plan's guesses, so Plans 2 and 3 are grounded in reality.

---

## Task 0: Record spike findings as we go

**Files:**
- Create: `docs/spike-notes.md`

- [ ] **Step 1: Create the spike log**

```bash
mkdir -p docs
cat > docs/spike-notes.md <<'EOF'
# Spike notes (foundation)

Running record of what actually worked on real hardware, so Plans 2 and 3 are
grounded in reality rather than guesses. Append findings under each task.

## Environment as found
- Host: Apple Silicon (arm64), macOS, Determinate Nix installed, no Lima, no cargo on host.

## Findings
EOF
```

- [ ] **Step 2: Commit**

```bash
git add docs/spike-notes.md
git commit -m "docs: start foundation spike notes"
```

**Throughout this plan:** whenever observed reality differs from a step's assumption, append a dated note under "## Findings" before moving on.

---

## Task 1: Install Lima on the host

**Files:** none (host tooling).

- [ ] **Step 1: Install Lima via Nix**

Run:
```bash
nix profile install nixpkgs#lima
```

- [ ] **Step 2: Verify Lima is available**

Run: `limactl --version`
Expected: prints a version (e.g. `limactl version 1.x.x`). If `command not found`, re-open the shell so the Nix profile is on PATH, or run `nix run nixpkgs#lima -- --version` and note in spike-notes that we invoke via `nix run`.

- [ ] **Step 3: Record finding**

Append the installed Lima version to `docs/spike-notes.md`.

```bash
git add docs/spike-notes.md && git commit -m "chore: install Lima, record version"
```

---

## Task 2: Spike a NixOS guest booting under Lima

**Files:** none yet (using Lima's stock template to de-risk before writing our own config).

- [ ] **Step 1: Start the stock NixOS template**

Run:
```bash
limactl start --name=workshop-spike --tty=false template://nixos
```
Expected: Lima downloads/boots an aarch64 NixOS guest and reports it as Running. This can take several minutes on first run.

If the `template://nixos` name fails, list available templates with `limactl start --list-templates` and use the exact NixOS template name shown; record it.

- [ ] **Step 2: Verify shell access into the guest**

Run: `limactl shell workshop-spike uname -a`
Expected: a `Linux ... aarch64 ... GNU/Linux` line.

- [ ] **Step 3: Record what booted**

Append to `docs/spike-notes.md`: the exact template name used, the guest kernel version (`limactl shell workshop-spike uname -r`), and whether boot needed any flags.

```bash
git add docs/spike-notes.md && git commit -m "spike: confirm NixOS guest boots under Lima on aarch64"
```

---

## Task 3: Verify the guest meets eBPF prerequisites

**Files:** none (inspection only).

- [ ] **Step 1: Check BTF is present**

Run: `limactl shell workshop-spike ls -l /sys/kernel/btf/vmlinux`
Expected: the file exists (non-zero size). BTF is required for modern Aya/CO-RE.

- [ ] **Step 2: Check cgroup v2 is mounted**

Run: `limactl shell workshop-spike stat -f -c %T /sys/fs/cgroup`
Expected: `cgroup2fs`. This is required for the `cgroup/connect4` hook used in later plans.

- [ ] **Step 3: Check the bpf syscall / mount works**

Run: `limactl shell workshop-spike -- sh -c 'mount | grep -i bpf; ls /sys/fs/bpf'`
Expected: a `bpf` filesystem is mounted (or mountable); the directory lists without error.

- [ ] **Step 4: Check the trace pipe exists**

Run: `limactl shell workshop-spike -- sh -c 'ls /sys/kernel/debug/tracing/trace_pipe || ls /sys/kernel/tracing/trace_pipe'`
Expected: one of the paths exists. Record which path is the real one; the hello-world verify step (Task 8) reads from it.

- [ ] **Step 5: Record the prerequisite results**

Append all four results to `docs/spike-notes.md`. If BTF or cgroup2 is missing, note it: this tells us the stock template kernel is insufficient and Task 6 (flake-pinned kernel) is mandatory rather than optional.

```bash
git add docs/spike-notes.md && git commit -m "spike: record eBPF prerequisites in stock guest"
```

---

## Task 4: Scaffold the Cargo workspace with aya-template

**Files:**
- Create: `Cargo.toml`, `firewall/`, `firewall-ebpf/`, `firewall-common/`, `rust-toolchain.toml` (all generated).

The scaffold needs `cargo` + `cargo-generate`, which we do not have on the host. Use a throwaway Nix shell to generate it, then we wrap it with our own flake in Task 5.

- [ ] **Step 1: Generate the project into a temp dir**

Run:
```bash
nix shell nixpkgs#cargo-generate nixpkgs#cargo -c \
  cargo generate --git https://github.com/aya-rs/aya-template \
  --name firewall --destination /tmp/fw-gen --init false
```
This is interactive: when prompted for the program type, choose a `cgroup_sockopt`/`cgroup_skb`/`cgroup_sock_addr` option if offered; otherwise pick any simple type (we replace the program body in Task 7 anyway). Record which program type the template offered and which was chosen.

Expected: a generated workspace at `/tmp/fw-gen/firewall` with `firewall/`, `firewall-ebpf/`, `firewall-common/`, `Cargo.toml`, `rust-toolchain.toml`.

- [ ] **Step 2: Move the generated files into the repo root**

Run:
```bash
cp -R /tmp/fw-gen/firewall/. /Users/artogahr/workplace/ebpf-firewall-rs/
```
Then inspect what landed: `ls -la` should show `Cargo.toml`, the three crates, and `rust-toolchain.toml`. Do not let it overwrite `.git`, `docs/`, or `README` if present (the temp project has its own; reconcile in Task 9).

- [ ] **Step 3: Record the generated layout and dependency versions**

Append to `docs/spike-notes.md`: the aya / aya-ebpf / aya-log versions in the generated `Cargo.toml` files, and the nightly date in `rust-toolchain.toml`. Plans 2 and 3 pin to these exact versions.

- [ ] **Step 4: Commit the scaffold**

```bash
git add -A
git commit -m "feat: scaffold Aya workspace from aya-template"
```

---

## Task 5: Write the flake dev shell

**Files:**
- Create: `flake.nix`
- Create: `flake.lock` (generated)

- [ ] **Step 1: Write `flake.nix` with a dev shell**

Create `flake.nix`:

```nix
{
  description = "eBPF + Rust firewall workshop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };
        # Pin the nightly used by aya-template's rust-toolchain.toml.
        # Replace the date with the one recorded in spike-notes (Task 4 Step 3).
        rustNightly = pkgs.rust-bin.nightly."2025-01-01".default.override {
          extensions = [ "rust-src" ];
          targets = [ "bpfel-unknown-none" ];
        };
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            rustNightly
            pkgs.bpf-linker
            pkgs.cargo-generate
            pkgs.llvmPackages.clang
            pkgs.pkg-config
          ];
        };
      });
}
```

- [ ] **Step 2: Generate the lock and verify the dev shell evaluates in the guest**

The dev shell must be entered inside the guest (Linux), not on macOS. Mount the repo into the spike guest and enter:

Run (host):
```bash
limactl shell workshop-spike -- sh -c 'cd /Users/artogahr/workplace/ebpf-firewall-rs 2>/dev/null || echo NO_MOUNT'
```
If it prints `NO_MOUNT`, the repo is not mounted into the stock spike guest (expected; mounts are configured in Task 7's `workshop.yaml`). In that case, validate the flake on the host instead for now:

Run (host): `nix flake lock` then `nix flake check`
Expected: `flake.lock` is created; `nix flake check` evaluates without error. (Building the Linux dev shell from macOS may be deferred to the guest; if `nix develop` on the host errors about the `bpfel-unknown-none` target or Linux-only packages, note it and rely on entering the shell inside the guest in Task 7.)

- [ ] **Step 3: Record the exact nightly date used**

Confirm the date in `flake.nix` matches `rust-toolchain.toml`. Append the final pinned date to `docs/spike-notes.md`.

- [ ] **Step 4: Commit**

```bash
git add flake.nix flake.lock
git commit -m "feat: add flake dev shell (Rust nightly, bpf-linker, cargo-generate)"
```

---

## Task 6: Pin the guest kernel via a NixOS configuration in the flake

**Files:**
- Modify: `flake.nix` (add `nixosConfigurations.workshop`)

This makes the guest kernel reproducible (BTF on, cgroup v2, eBPF config) rather than relying on Lima's stock template kernel.

- [ ] **Step 1: Add a NixOS configuration output to `flake.nix`**

Add to the flake outputs (outside `eachDefaultSystem`, since NixOS configs are not per-system):

```nix
      # ... inside outputs, alongside the flake-utils call:
    } // {
      nixosConfigurations.workshop = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ({ pkgs, lib, ... }: {
            # Pin a recent kernel with BTF + BPF enabled.
            boot.kernelPackages = pkgs.linuxPackages_latest;
            # NixOS enables cgroup v2 and CONFIG_DEBUG_INFO_BTF by default on
            # recent kernels; assert the eBPF-relevant options explicitly.
            boot.kernelPatches = lib.mkDefault [];
            # Tools available inside the guest for the workshop.
            environment.systemPackages = with pkgs; [ bpftool curl iproute2 ];
            # cgroup v2 unified hierarchy (NixOS default with systemd, asserted here).
            systemd.enableUnifiedCgroupHierarchy = true;
            system.stateVersion = "24.11";
          })
        ];
      };
```

Note: merging the `eachDefaultSystem` attrset with the top-level `nixosConfigurations` requires the `//` join shown. If the flake fails to evaluate, restructure outputs so `nixosConfigurations` sits at the top level of the returned attrset (record the working shape in spike-notes).

- [ ] **Step 2: Build the kernel/config closure to verify it evaluates**

Run: `nix build .#nixosConfigurations.workshop.config.system.build.toplevel --no-link`
Expected: builds or fetches from cache without evaluation error. On a Mac host this needs the binary cache (no local Linux builder); if it fails to *build* (vs. evaluate), note it and defer the actual build to inside the guest. Evaluation success is the gate here.

- [ ] **Step 3: Record approach**

In `docs/spike-notes.md`, record whether the pinned kernel is applied via (a) `nixos-rebuild switch --flake .#workshop` inside the Lima NixOS guest, or (b) Lima provisioning. Decide based on what Task 7 proves out.

- [ ] **Step 4: Commit**

```bash
git add flake.nix flake.lock
git commit -m "feat: pin guest kernel via nixosConfigurations.workshop"
```

---

## Task 7: Write the Lima config and boot the real workshop guest

**Files:**
- Create: `workshop.yaml`

- [ ] **Step 1: Write `workshop.yaml`**

Create `workshop.yaml` (start from Lima's NixOS template shape, recorded in Task 2):

```yaml
# Lima config for the eBPF workshop guest.
# Boots a NixOS guest and mounts the repo read-write so all nix/cargo work
# happens inside Linux.
vmType: "vz"            # Apple Virtualization.framework; fast on Apple Silicon.
os: "Linux"
images:
  # Use the same NixOS image reference the stock template used (Task 2);
  # paste the exact location/arch/digest entries here.
  - location: "REPLACE_WITH_TEMPLATE_IMAGE_LOCATION"
    arch: "aarch64"

mounts:
  - location: "~/workplace/ebpf-firewall-rs"
    writable: true

provision:
  - mode: system
    script: |
      #!/bin/sh
      # Apply our pinned kernel/config from the mounted flake.
      cd /Users/${LIMA_USER}/workplace/ebpf-firewall-rs 2>/dev/null || \
        cd "$(find / -maxdepth 6 -name flake.nix -path '*ebpf-firewall-rs*' 2>/dev/null | head -1 | xargs dirname)"
      nixos-rebuild switch --flake .#workshop || \
        echo "WARN: flake rebuild failed; guest running stock kernel (see spike-notes)"
```

The `REPLACE_WITH_TEMPLATE_IMAGE_LOCATION` and the mount path are filled from real values observed in Tasks 2 and the mount point Lima actually uses (Lima mounts host paths under the same path or under `/Users/...`; confirm with `limactl shell`). Record the real mount path.

- [ ] **Step 2: Boot the real guest**

Run:
```bash
limactl start --name=workshop --tty=false ./workshop.yaml
```
Expected: guest boots and the provision script runs. If the image location is wrong, Lima errors immediately; fix from the Task 2 template values.

- [ ] **Step 3: Verify the repo is mounted and writable inside the guest**

Run:
```bash
limactl shell workshop -- sh -c 'cd $(find / -maxdepth 6 -name flake.nix -path "*ebpf-firewall-rs*" 2>/dev/null | head -1 | xargs dirname) && pwd && touch .mount-test && rm .mount-test && echo MOUNT_OK'
```
Expected: prints the repo path and `MOUNT_OK`. Record the exact in-guest repo path.

- [ ] **Step 4: Verify the dev shell works inside the guest**

Run:
```bash
limactl shell workshop -- sh -c 'cd <in-guest-repo-path> && nix develop -c rustc --version && nix develop -c bpf-linker --version'
```
Expected: prints rustc nightly version and bpf-linker version. This is the first proof the in-guest dev environment is real.

- [ ] **Step 5: Re-verify eBPF prerequisites on the real (pinned) guest**

Repeat Task 3's four checks against `workshop` (not `workshop-spike`). Expected: BTF present, cgroup2, bpf fs, trace_pipe path. Record results.

- [ ] **Step 6: Commit**

```bash
git add workshop.yaml docs/spike-notes.md
git commit -m "feat: add Lima workshop guest config; verify in-guest dev shell + eBPF prereqs"
```

---

## Task 8: Write the hello-world eBPF program (Step 0)

**Files:**
- Modify: `firewall-ebpf/src/main.rs` (the kernel program)
- Modify: `firewall/src/main.rs` (the loader)

The hello-world fires on a trivially-triggered event (process execve) and prints a line to the trace pipe, proving the load -> attach -> trace loop. We deliberately use a tracepoint here (fires on any command) rather than the connect hook, which is introduced in Plan 2 / Step 1.

- [ ] **Step 1: Write the kernel program as a tracepoint that prints**

Replace `firewall-ebpf/src/main.rs` with:

```rust
#![no_std]
#![no_main]

use aya_ebpf::{macros::tracepoint, programs::TracePointContext};

// Confirm the exact macro/helper names against the aya-ebpf version recorded in
// spike-notes (Task 4). If `bpf_printk!` lives elsewhere or the tracepoint macro
// signature differs, adjust per aya docs and record the correct form.
use aya_ebpf::helpers::bpf_printk;

#[tracepoint]
pub fn hello(_ctx: TracePointContext) -> u32 {
    unsafe {
        bpf_printk!(b"hello from eBPF: a process called execve\n");
    }
    0
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
```

- [ ] **Step 2: Write the loader to attach the tracepoint**

In `firewall/src/main.rs`, attach the program to the `syscalls:sys_enter_execve` tracepoint. Use the loader shape aya-template generated; the attach call is roughly:

```rust
use aya::programs::TracePoint;
// inside main, after loading the eBPF bytes into `Ebpf`:
let program: &mut TracePoint = ebpf.program_mut("hello").unwrap().try_into()?;
program.load()?;
program.attach("syscalls", "sys_enter_execve")?;
println!("hello-world loaded. Run any command in another shell and watch the trace pipe.");
// keep the program attached until Ctrl-C:
tokio::signal::ctrl_c().await?;
```
Confirm the `program_mut` name matches the function name `hello` and that the loader keeps running (so the program stays attached). Adjust to the template's actual main signature (async/tokio vs. sync) and record which it is.

- [ ] **Step 3: Build inside the guest**

Run:
```bash
limactl shell workshop -- sh -c 'cd <in-guest-repo-path> && nix develop -c cargo build'
```
Expected: both crates compile. If `bpf-linker` or target errors appear, this is the first real eBPF build; fix per the error and record the resolution.

- [ ] **Step 4: Run the loader and watch the trace pipe**

In one guest shell, run the loader (needs root for bpf):
```bash
limactl shell workshop -- sh -c 'cd <in-guest-repo-path> && nix develop -c sudo target/debug/firewall'
```
In a second guest shell, read the trace pipe (path from Task 3 Step 4) while running a command:
```bash
limactl shell workshop -- sh -c 'sudo cat /sys/kernel/debug/tracing/trace_pipe' &
limactl shell workshop -- sh -c 'ls'   # triggers execve
```
Expected: a `hello from eBPF: a process called execve` line appears in the trace pipe output.

- [ ] **Step 5: Record the working end-to-end result**

This is the key milestone. Append to `docs/spike-notes.md`: the exact build command, run command, trace pipe path, and confirmation that the line appeared. This proves the entire stack.

- [ ] **Step 6: Commit**

```bash
git add firewall-ebpf/src/main.rs firewall/src/main.rs docs/spike-notes.md
git commit -m "feat: hello-world eBPF prints to trace pipe (Step 0 end-to-end proven)"
```

---

## Task 9: Write the `main` README (the workshop map)

**Files:**
- Create/replace: `README.md`

- [ ] **Step 1: Write the welcoming README with the ladder map**

Replace `README.md` with (no em-dashes per author preference):

```markdown
# Accessing the Linux Kernel with eBPF and Rust

Welcome. In this workshop you build a small firewall that lives inside the Linux
kernel and decides, per process, whether a program is allowed to open network
connections. You write it in Rust on both sides: the kernel program and the
userspace app that controls it.

## Why a VM?

eBPF only exists in the Linux kernel. macOS has no eBPF, so everyone (Mac and
Linux alike) runs the exact same Linux guest. The guest's kernel is pinned, so
the kernel verifier behaves identically for all of us.

## Setup (do this before the workshop)

1. Install Nix: https://nixos.org (Determinate installer recommended).
2. Install Lima: `nix profile install nixpkgs#lima`
3. Clone this repo and boot the guest once to warm your cache:
   `limactl start --name=workshop ./workshop.yaml`
4. Confirm it works: follow the "Step 0" check below. If you see the hello line
   in the trace pipe, you are ready.

## The workshop, step by step

Each step is a git branch. Start on `main` (this branch, "Step 0"), then move up
the ladder. If you fall behind, check out the next step's branch and rejoin.

- [ ] **Step 0 (you are here, `main`): Hello eBPF.** Load a program and see it
  print to the kernel trace pipe. Proves your toolchain works.
- [ ] **Step 1 (`step-1`): Catch the hook.** Attach to `cgroup/connect4` and log
  every connection attempt.
- [ ] **Step 2 (`step-2`): Read the PID** of the process making the connection.
- [ ] **Step 3 (`step-3`): Read the destination** IP and port.
- [ ] **Step 4 (`step-4`): Share state with a map.** Userspace pushes a PID onto
  a blocklist; the kernel logs when a blocked PID connects (no blocking yet).
- [ ] **Step 5 (`step-5`): The kill switch.** Deny connections from blocked PIDs.
- [ ] **Step 6 / `solution`: IPv6 and polish.**

## Step 0 check

```bash
limactl shell workshop
cd <repo path inside the guest>
nix develop -c cargo build
sudo target/debug/firewall        # leave running
# in another shell:
sudo cat /sys/kernel/debug/tracing/trace_pipe   # then run any command
```
You should see a `hello from eBPF` line. That means you are ready.

## Running this for a crowd?

See `docs/instructor-notes.md` for timing, talking points, and an optional local
Nix cache trick that serves the closure over the room's LAN so dozens of people
are not all pulling from the internet at once.
```

Fill `<repo path inside the guest>` with the real path recorded in Task 7.

- [ ] **Step 2: Verify the setup instructions against reality**

Re-read the README against `docs/spike-notes.md`. Every command in the Setup and Step 0 sections must be one that actually worked. Fix any that drifted.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add welcoming README with the step ladder map"
```

---

## Task 10: Establish `main` as the clean Step 0 baseline

**Files:** none (git hygiene).

- [ ] **Step 1: Confirm the working tree is clean and on main**

Run: `git status` and `git branch --show-current`
Expected: clean tree, on `main`.

- [ ] **Step 2: Tag the foundation**

```bash
git tag step-0
git log --oneline -8
```
Expected: tag created; history shows the foundation commits.

- [ ] **Step 3: Record completion in spike notes**

Append a "Foundation complete" entry to `docs/spike-notes.md` summarizing the proven stack (Lima image, kernel version, aya versions, nightly date, trace pipe path, in-guest repo path). Plans 2 and 3 read this as their source of truth.

```bash
git add docs/spike-notes.md
git commit -m "docs: foundation complete; record proven stack for plans 2 and 3"
```

---

## Self-Review (completed by plan author)

**Spec coverage:** This plan covers the spec's Environment/distribution (flake, Lima, NixOS guest, pinned kernel: Tasks 5-7), Tooling (Aya workspace, devShell: Tasks 4-5), Step 0 of the ladder (Task 8), the welcoming `main` README with the ladder map and the optional-cache pointer (Task 9), and the `main`-is-start-point convention (Task 10). Deferred to later plans (by design, per the agreed sequencing): Steps 1-6 code and checkpoint branches (Plan 2), full instructor notes + `harmonia` cache + CI test matrix (Plan 3), and the TC optional stretch (Plan 2 or a later plan).

**Placeholder note:** The `REPLACE_WITH_TEMPLATE_IMAGE_LOCATION` token and `<in-guest-repo-path>` are intentional: they are filled from values that can only be observed by running Tasks 2 and 7 on real hardware. Each is paired with the exact command that produces the value. This is a spike plan; discovering these is the work, not a deferral of it.

**Version consistency:** The pinned nightly date, aya versions, and trace pipe path are recorded once in `docs/spike-notes.md` (Tasks 4, 5, 8) and referenced from there, so Plans 2 and 3 stay consistent with what was proven.
```
