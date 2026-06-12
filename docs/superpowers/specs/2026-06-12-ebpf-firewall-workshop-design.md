# eBPF + Rust Firewall Workshop: Design

**Date:** 2026-06-12
**Author:** Arto Gahr
**Status:** Approved design (pending spec review)

## Purpose

Workshop materials for *"Accessing the Linux kernel using eBPF and Rust"*, a
120-minute advanced workshop (flexible to 60/180). Participants build a working
process-identity firewall: the Linux kernel allows or denies network connections
based on which process initiated them, with state shared between a Rust userspace
app and the kernel.

The materials must let a mixed audience (mostly Apple Silicon MacBooks, some Linux)
go from zero to a working eBPF program inside a ~15-minute setup window, and complete
the core build in **~90 minutes**.

**Pedagogical principle (drives the whole structure):** the value is the *path*, not
the final artifact. The firewall is built as a ladder of small, individually
runnable/observable steps, each introducing exactly one new concept, so participants
understand how they arrived at the end product. Guiding arc:
**see the hook fire, read data, store data, enforce.** Observe before you act.

## Core constraint that shapes everything

**eBPF only exists in the Linux kernel. macOS has no eBPF subsystem.** Nix gives
every participant an identical *build* environment but cannot give a Mac a kernel
to *load* programs into. Therefore the actual execution target is a Linux VM, and
that VM's kernel is pinned so the verifier behaves identically for all participants.
This is critical for the verifier teaching: one shared experience, not 30 unique
debugging sessions.

## Environment and distribution

- **Ship a git flake, not a disk image.** The repo is kilobytes; the environment is
  reconstructed from `flake.lock` against `cache.nixos.org`, byte-identical for all.
- **One Lima + NixOS guest for everyone** (Mac and Linux alike). A single
  `workshop.yaml` Lima config runs on both macOS and Linux hosts and auto-selects
  `aarch64-linux` / `x86_64-linux`. The guest is **NixOS with the kernel pinned in
  the flake** (BTF enabled, cgroup v2, eBPF-relevant kernel config).
- **The flake provides Lima itself**, so participants never install it imperatively.
  The flake has two dev shells: `.#host` (runs on the laptop, provides `limactl` to
  boot the guest) and the default shell (runs inside the guest, provides the Rust/Aya
  toolchain). The only manual host steps are installing Nix and cloning the repo; the
  flow is then `nix develop .#host` then `limactl start ./workshop.yaml`. The NixOS
  guest itself is sourced via the `nixos-lima` flake (Lima ships no NixOS template):
  boot its prebuilt image, then apply the flake-pinned kernel config from inside the
  guest with `nixos-rebuild switch --flake .#workshop`.
- **All `nix` work happens inside the guest**, sidestepping the "can't build Linux
  derivations from Darwin" trap (no `linux-builder` needed on participant Macs).
- **Homework:** participants run `limactl start` once at home to warm the guest's
  `/nix/store` over good internet.
- **Optional day-of bandwidth safety net (for large crowds):** the instructor's laptop
  can run a local Nix binary cache (`harmonia`) on the workshop LAN; participants add
  it as a substituter, so closure pulls happen at LAN speed and offline, independent of
  venue wifi. Documented in the instructor notes as bandwidth insurance, not a required
  step. With homework warm-up done, most runs will not need it.

## Tooling

- **Aya** (pure Rust on both kernel and userspace sides: no C, no libbpf, no kernel
  headers), scaffolded from `aya-template` via `cargo-generate`.
- Rust nightly + `bpf-linker` provided by the flake devShell (inside the guest).
- Cargo workspace:
  - `firewall-ebpf`: the kernel program(s).
  - `firewall`: userspace loader + CLI (push a PID onto the blocklist).
  - `firewall-common`: shared types between kernel and userspace.

## Workshop content: the iterative step ladder (90-min core)

The core firewall uses a **single program type**: a `cgroup/connect4` (plus a
`connect6` one-liner) hook. Returning `0` from this hook denies the `connect()`
syscall in-kernel, so there is no TC, no skb parsing, no socket-cookie bridge.

Each step is a **checkpoint branch** participants can land on if they fall behind.
`main` is the start point (the skeleton, "step 0"); `step-1` through `step-5` plus
`solution` build on it.

**Invariant that makes skipping ahead safe (offline, no re-download):**
1. The flake is frozen across every branch. `flake.nix`, `flake.lock`, and the NixOS
   guest config are identical on all step branches, so checking out another branch
   never invalidates the `/nix/store` or the devShell. Only the participant's own
   crate source differs between branches, and rebuilding that is a normal `cargo build`.
2. The Cargo dependency set is fixed from step 0. `Cargo.toml` carries the full set of
   dependencies from the start (even ones unused until later steps), so `Cargo.lock`
   is stable and every crate is fetched once during the homework warm-up. After that,
   jumping to any step works without fetching from crates.io.

| Step | New concept | What they write | What they observe | Likely verifier moment |
|---|---|---|---|---|
| **0, Hello eBPF** *(setup check)* | the load/attach/trace loop; toolchain works | a trivial program that fires and logs | a line in the trace pipe | "compiled but won't load", first taste |
| **1, Catch the hook** | program types; attaching to `cgroup/connect4` | hook that logs `"connect fired"` on every connect | run `curl`, watch the log fire | none |
| **2, Read context: PID** | kernel context + helpers (`bpf_get_current_pid_tgid`) | add PID to the log | two terminals, two different PIDs | none |
| **3, Read more: dest IP/port** | reading the program context struct; endianness | parse sockaddr, log destination | log shows *who* then *where* | byte-order / bounds gotcha |
| **4, Share state: maps** | BPF maps + userspace loader + `common` crate | `HashMap` blocklist; CLI pushes a PID; kernel **logs** "PID X is blocked" *(no enforce yet)* | add PID via CLI, kernel notices it | map lookup returns `Option`; verifier insists you handle it |
| **5, The kill switch** | return value controls kernel behavior | flip step 4's log into `return 0` (deny) | `curl` in blocked shell fails | none |
| **6, (buffer) `connect6` + CLI polish** | IPv6 bypass; ergonomics | one-liner `connect6`; nicer CLI | IPv6 app also blocked | none |

### Why the ladder is shaped this way

- **Step 4 deliberately stops at "log, don't enforce."** This is the pedagogical
  hinge: participants prove kernel and userspace are *talking* (identity flows in,
  kernel reacts) before any blocking happens. Step 5 is then a one-line change from
  "log it" to "deny it", so the kill switch feels earned, not magic.
- **The verifier is not bolted on at the end.** It ambushes participants naturally at
  steps 0, 3, and 4, so the closing segment *consolidates* scars they already have
  rather than introducing the concept cold.

### Rough timing

Step 0 inside the 15-min setup check; Steps 1 and 2 around 10 min each; Step 3 around
15; Step 4 around 25 (the big one); Step 5 around 15; Step 6 plus verifier
consolidation (around 15) in the remaining buffer. Core build is roughly 90 min, plus
15 setup and 15 verifier, which fills the 120-min slot.

### Honest framing notes (to state plainly during the workshop)

- This blocks at **connect time**, not per-packet: existing open connections are not
  torn down; the firewall denies *new* connections from a blocked app. An easy, honest
  thing to explain and a natural lead-in to *why* one would reach for TC.
- It is IPv4 via `connect4`; `connect6` is added (Step 6) so IPv6-capable apps don't
  silently bypass the rule and confuse participants.
- The guest is headless, so the demo is **"watch `curl` stop"** (run from inside the
  VM), not "watch your browser stop." Same effect, accurate to the setup.

## Optional stretch / 180-min extension: TC packet drop

The original proposal's TC packet-drop version is preserved as bonus content. It uses
a socket-cookie bridge: the `connect4` hook records the blocked socket's cookie
(`bpf_get_socket_cookie`) into a map; a TC egress program looks up
`bpf_get_socket_cookie(skb)` per packet and returns `TC_ACT_SHOT` to drop. This is the
per-packet version and the content for the longer workshop variant.

## Teaching scaffolding (so stragglers survive)

- Git **checkpoint branches** matching the ladder: `main` (the start point / Step 0),
  then `step-1` through `step-5` and `solution`. Anyone who falls behind checks out the
  next step and rejoins. Safe to do offline thanks to the frozen-flake / fixed-Cargo
  invariant above.
- The `hello-world` eBPF program for the setup-check segment (Step 0), on `main`.
- A **welcoming participant `README`** written for both workshop attendees and future
  readers who find the repo later: what this is, how to set up, and the staged tasks.
- **README progress convention (self-locating branches):**
  - On `main`, the README shows the **full ladder as a checklist**, with every step
    branch linked and the setup/homework instructions. This is the map of the whole
    workshop.
  - On each step branch, the README opens with a **progress header** that shows where
    you are, for example: `Step 3 of 5  |  done: 0, 1, 2  |  >> you are here <<  |
    next: Step 4`. Below it: a short "what you'll learn in this step" blurb, the task,
    and a one-line command to jump to the next checkpoint. Every branch is therefore
    self-locating, so a participant who checks out a branch cold always knows where
    they are and where to go next.
- Separate **instructor notes**: homework instructions, timing, talking points, and an
  **optional** "if you are running this for a crowd, set up a local Nix cache on your
  laptop like so" section (the `harmonia` LAN-cache trick), framed as bandwidth
  insurance rather than a required step.

## Testing the materials before the day

Testing is in scope. The goal is confidence that the homework path works and that
every step branch is in a known-good state, so nobody hits a broken checkpoint live.

- **Build matrix:** CI builds the flake + guest closure for **both arches**
  (`aarch64-linux`, `x86_64-linux`).
- **Per-branch compile check:** every step branch (`main`, `step-1` ... `solution`)
  compiles cleanly (`cargo build` for both the eBPF and userspace crates). This catches
  a broken checkpoint before a participant lands on it.
- **Behavior smoke test:** boot the VM, load `hello-world`, and assert the expected
  trace output appears; on `solution`, assert that a blocked PID's `curl` actually
  fails while an unblocked one succeeds. This requires nested virtualization (KVM),
  which GitHub-hosted runners do not always provide, so it may run on a self-hosted
  runner or be run manually before the event. The build matrix and per-branch compile
  check run on standard runners regardless.

## Components summary / boundaries

| Unit | Purpose | Depends on |
|------|---------|-----------|
| `flake.nix` | devShell, pinned NixOS guest config, kernel pin, harmonia cache | nixpkgs (pinned) |
| `workshop.yaml` | Lima config booting the NixOS guest, mounts repo | Lima, flake |
| `firewall-ebpf` | `cgroup/connect4(+6)` hook | aya-ebpf, `firewall-common` |
| `firewall` | userspace loader + CLI to manage blocklist map | aya, `firewall-common` |
| `firewall-common` | shared map key/value types | (none) |
| checkpoint branches | per-step catch-up points | git |
| `README` + instructor notes | participant + instructor guidance | (docs) |
| CI | both-arch build + optional boot smoke test | flake |

## Out of scope (YAGNI)

- A "full" firewall (rule persistence, config files, allowlists, logging UI).
- Per-packet TC dropping in the core path (moved to optional stretch).
- Supporting native Linux host execution as a separate path (everyone uses the VM).
- Shipping prebuilt disk-image blobs (flake + cache reconstruction instead).
