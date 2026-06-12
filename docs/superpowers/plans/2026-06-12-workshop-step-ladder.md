# Workshop Step Ladder Implementation Plan (Plan 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the workshop's content ladder: a per-process firewall grown over five checkpoint branches (`step-1` .. `step-5`, plus `step-6`/`solution`), from "catch the connect hook" to "deny blocked PIDs", each branch a cumulative, runnable state.

**Architecture:** A single `cgroup/connect4` eBPF program, attached to the root cgroup, grown one concept per step. The userspace loader attaches it and (from Step 4) seeds a blocklist map from argv. Logging during the logging steps uses `bpf_printk` -> kernel trace pipe (zero loader boilerplate); aya-log was demonstrated in Step 0. Each step is a git branch holding the completed state of that step; the instructor live-codes the small delta from the previous branch.

**Tech Stack:** aya 0.13.2 (git-pinned), aya-ebpf, Rust nightly (LLVM 22) + bpf-linker via the flake `.#guest` shell, NixOS guest (kernel 7.0.10) booted with `nix run .#start`.

**Builds on Plan 1 (foundation), which is complete.** Proven facts (see `docs/spike-notes.md`): guest boots via `nix run .#start` (instance `workshop`); build with `nix develop -c cargo build --locked`; run with `RUST_LOG=info cargo run` (the `.cargo/config.toml` `runner = "sudo -E"` auto-elevates); trace pipe at `/sys/kernel/tracing/trace_pipe`; cgroup v2 at `/sys/fs/cgroup`.

**Verified API (aya 0.13.2):**
- eBPF hook: `#[cgroup_sock_addr(connect4)]`, fn takes `SockAddrContext`, returns `i32` (`1` = allow, `0` = deny). Section becomes `cgroup/connect4`.
- `SockAddrContext { sock_addr: *mut bpf_sock_addr }`; `bpf_sock_addr` has `user_ip4: u32`, `user_port: u32` (network byte order), `user_ip6: [u32; 4]`.
- PID: `aya_ebpf::helpers::bpf_get_current_pid_tgid() >> 32`.
- eBPF map: `aya_ebpf::maps::HashMap`; `#[map] static BLOCKLIST: HashMap<u32, u8>`; lookup `unsafe { BLOCKLIST.get(&pid) }`.
- Userspace: `aya::programs::{CgroupSockAddr, CgroupAttachMode}`; `program.attach(&cgroup_file, CgroupAttachMode::Single)`. Map: `aya::maps::HashMap::try_from(ebpf.map_mut("BLOCKLIST")?)`, `.insert(pid, 0, 0)`.

---

## Conventions for every task

- **Work inside the guest.** From the repo dir on the host: `nix run .#enter`, then `cd` to the repo path (the shell mirrors host cwd). Build/run commands use `nix develop -c ...`.
- **Branch model.** Each `step-N` branch is branched from the previous step's branch and holds that step's *completed* state. Create with `git switch -c step-N` from the prior branch.
- **Verify, don't assume.** Each task ends by loading the program and observing real behavior. If a verified-API assumption (e.g. the deny return value) turns out wrong, the observation step catches it; fix and record in `docs/spike-notes.md`.
- **Live-diff annotation.** Each task marks what the instructor types live vs. what is pre-staged. Keep pre-staged code minimal and readable.
- **Trace pipe.** Observe `bpf_printk` output with `sudo cat /sys/kernel/tracing/trace_pipe` in a second `nix run .#enter` shell. Trigger connects with `curl -s http://example.com -o /dev/null` or `curl -s 1.1.1.1 -o /dev/null` from a chosen shell.

## File Structure

- `firewall-ebpf/src/main.rs` - the `cgroup/connect4` program. Changes every step (it is the lesson).
- `firewall/src/main.rs` - the loader. Rewritten once in Step 1 (tracepoint -> cgroup attach), extended once in Step 4 (seed blocklist from argv), unchanged otherwise.
- `README.md` - per-branch progress header updated each step ("you are here").
- `firewall-common/src/lib.rs` - stays `#![no_std]`; no shared types needed (PID is a plain `u32`). Left untouched.

---

## Task 1: Step 1 - Catch the hook (`step-1`)

**Concept:** program types; attaching to `cgroup/connect4`; the hook fires on every outbound connection.

**Files:**
- Modify: `firewall-ebpf/src/main.rs`
- Modify: `firewall/src/main.rs`
- Modify: `README.md`

**Live diff (instructor types):** the `connect4` function body. **Pre-staged:** the loader's cgroup-attach ceremony.

- [ ] **Step 1: Create the branch from main**

```bash
git switch main && git switch -c step-1
```

- [ ] **Step 2: Replace the eBPF program with a connect4 hook**

Write `firewall-ebpf/src/main.rs`:

```rust
#![no_std]
#![no_main]

use aya_ebpf::{helpers::bpf_printk, macros::cgroup_sock_addr, programs::SockAddrContext};

#[cgroup_sock_addr(connect4)]
pub fn connect4(_ctx: SockAddrContext) -> i32 {
    unsafe { bpf_printk!(c"connect4: a process is connecting") };
    1 // 1 = allow the connection, 0 = deny
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
```

- [ ] **Step 3: Replace the loader to attach the cgroup program**

Write `firewall/src/main.rs` (this is the pre-staged loader, reused unchanged through Step 3):

```rust
use std::fs::File;

use aya::programs::{CgroupAttachMode, CgroupSockAddr};
use tokio::signal;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    env_logger::init();

    let mut ebpf = aya::Ebpf::load(aya::include_bytes_aligned!(concat!(
        env!("OUT_DIR"),
        "/firewall"
    )))?;

    // Attach to the root cgroup v2, so the hook sees every process on the system.
    let cgroup = File::open("/sys/fs/cgroup")?;
    let program: &mut CgroupSockAddr = ebpf.program_mut("connect4").unwrap().try_into()?;
    program.load()?;
    program.attach(&cgroup, CgroupAttachMode::Single)?;

    println!("firewall attached. Press Ctrl-C to exit.");
    signal::ctrl_c().await?;
    Ok(())
}
```

- [ ] **Step 4: Build**

Run:
```bash
nix develop -c cargo build --locked
```
Expected: both crates compile. If the `connect4` fn signature is rejected (return type or context), check the aya `cgroup_sock_addr` macro expectations and adjust; record any change in `docs/spike-notes.md`.

- [ ] **Step 5: Load and observe the hook firing**

Terminal A (loader): `nix develop -c bash -c 'cargo run --locked'`
Terminal B (trace pipe): `sudo cat /sys/kernel/tracing/trace_pipe`
Terminal C (trigger): `curl -s 1.1.1.1 -o /dev/null; echo done`

Expected: each connect produces a `connect4: a process is connecting` line in Terminal B's trace pipe. Press Ctrl-C in A to stop.

- [ ] **Step 6: Update the README progress header**

In `README.md`, change the ladder checklist so Step 0 and Step 1 are checked and the "you are here" marker is on Step 1:

```markdown
- [x] **Step 0 (`main`): Hello eBPF.** ...
- [x] **Step 1 (`step-1`, you are here): Catch the hook.** ...
```
(Leave the remaining items unchecked.)

- [ ] **Step 7: Commit**

```bash
git add firewall-ebpf/src/main.rs firewall/src/main.rs README.md
git commit -m "step-1: cgroup/connect4 hook logs on every outbound connection"
```

---

## Task 2: Step 2 - Read the PID (`step-2`)

**Concept:** reading kernel context via helpers; identifying *which* process is connecting.

**Files:**
- Modify: `firewall-ebpf/src/main.rs`
- Modify: `README.md`

**Live diff (instructor types):** two lines, get the PID and add it to the printk. **Pre-staged:** everything else (loader unchanged).

- [ ] **Step 1: Create the branch from step-1**

```bash
git switch step-1 && git switch -c step-2
```

- [ ] **Step 2: Add the PID to the program**

Write `firewall-ebpf/src/main.rs`:

```rust
#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_printk},
    macros::cgroup_sock_addr,
    programs::SockAddrContext,
};

#[cgroup_sock_addr(connect4)]
pub fn connect4(_ctx: SockAddrContext) -> i32 {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    unsafe { bpf_printk!(c"connect4: pid %d is connecting", pid) };
    1 // allow
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
```

- [ ] **Step 3: Build**

Run: `nix develop -c cargo build --locked`
Expected: compiles.

- [ ] **Step 4: Load and observe distinct PIDs**

Terminal A: `nix develop -c bash -c 'cargo run --locked'`
Terminal B: `sudo cat /sys/kernel/tracing/trace_pipe`
Terminal C: `echo "my shell pid is $$"; curl -s 1.1.1.1 -o /dev/null`

Expected: trace pipe shows `connect4: pid <N> is connecting`, and `<N>` matches the connecting process. Run curl from two different shells to see two different PIDs.

- [ ] **Step 5: Update README progress header**

In `README.md`, check Step 2 and move "you are here" to Step 2.

- [ ] **Step 6: Commit**

```bash
git add firewall-ebpf/src/main.rs README.md
git commit -m "step-2: log the PID of the connecting process"
```

---

## Task 3: Step 3 - Read the destination (`step-3`)

**Concept:** reading the program context struct (`bpf_sock_addr`); network byte order.

**Files:**
- Modify: `firewall-ebpf/src/main.rs`
- Modify: `README.md`

**Live diff (instructor types):** read `sock_addr`, add destination IP/port to the printk. **Pre-staged:** loader unchanged.

- [ ] **Step 1: Create the branch from step-2**

```bash
git switch step-2 && git switch -c step-3
```

- [ ] **Step 2: Read the destination address and port**

Write `firewall-ebpf/src/main.rs`:

```rust
#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_printk},
    macros::cgroup_sock_addr,
    programs::SockAddrContext,
};

#[cgroup_sock_addr(connect4)]
pub fn connect4(ctx: SockAddrContext) -> i32 {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;

    // The connect target lives in the program context. user_ip4 and user_port are
    // in network byte order; we print them raw here and decode them in the slides.
    let sa = unsafe { &*ctx.sock_addr };
    let dest_ip = u32::from_be(sa.user_ip4);
    let dest_port = u16::from_be(sa.user_port as u16);

    unsafe {
        bpf_printk!(c"connect4: pid %d -> ip %x port %d", pid, dest_ip, dest_port as u32)
    };
    1 // allow
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
```

- [ ] **Step 3: Build**

Run: `nix develop -c cargo build --locked`
Expected: compiles. If the verifier rejects the raw pointer deref (out-of-bounds), this is the expected "verifier moment"; the deref of a context-provided pointer is allowed here, but record any verifier message and resolution in `docs/spike-notes.md`.

- [ ] **Step 4: Load and observe destinations**

Terminal A: `nix develop -c bash -c 'cargo run --locked'`
Terminal B: `sudo cat /sys/kernel/tracing/trace_pipe`
Terminal C: `curl -s http://1.1.1.1 -o /dev/null` (expect ip 1010101 hex, port 50) and `curl -s http://1.1.1.1:443 ...`

Expected: trace pipe shows pid, destination IP (hex), and port. Confirm the port matches (80 -> `50` hex; verify by connecting to a known port).

- [ ] **Step 5: Update README progress header**

Check Step 3, move "you are here" to Step 3.

- [ ] **Step 6: Commit**

```bash
git add firewall-ebpf/src/main.rs README.md
git commit -m "step-3: log the destination IP and port"
```

---

## Task 4: Step 4 - Share state with a map (`step-4`)

**Concept:** BPF maps; userspace writing kernel state; log-before-enforce. The kernel logs when a *blocked* PID connects but does NOT block yet.

**Files:**
- Modify: `firewall-ebpf/src/main.rs`
- Modify: `firewall/src/main.rs`
- Modify: `README.md`

**Live diff (instructor types):** the `#[map]` declaration and the lookup branch in eBPF; the blocklist-seeding loop in the loader. **Pre-staged:** the loader's existing attach code.

- [ ] **Step 1: Create the branch from step-3**

```bash
git switch step-3 && git switch -c step-4
```

- [ ] **Step 2: Add the blocklist map and a lookup (log only)**

Write `firewall-ebpf/src/main.rs`:

```rust
#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_printk},
    macros::{cgroup_sock_addr, map},
    maps::HashMap,
    programs::SockAddrContext,
};

// PIDs userspace has asked us to block. Value is unused (just membership).
#[map]
static BLOCKLIST: HashMap<u32, u8> = HashMap::with_max_entries(1024, 0);

#[cgroup_sock_addr(connect4)]
pub fn connect4(_ctx: SockAddrContext) -> i32 {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;

    if unsafe { BLOCKLIST.get(&pid) }.is_some() {
        unsafe { bpf_printk!(c"connect4: pid %d is on the blocklist (allowing for now)", pid) };
    }
    1 // still allow; Step 5 turns this into a deny
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
```

- [ ] **Step 3: Extend the loader to seed the blocklist from argv**

Write `firewall/src/main.rs`:

```rust
use std::fs::File;

use aya::maps::HashMap;
use aya::programs::{CgroupAttachMode, CgroupSockAddr};
use tokio::signal;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    env_logger::init();

    let mut ebpf = aya::Ebpf::load(aya::include_bytes_aligned!(concat!(
        env!("OUT_DIR"),
        "/firewall"
    )))?;

    // Seed the blocklist with the PIDs passed on the command line.
    let mut blocklist: HashMap<_, u32, u8> =
        HashMap::try_from(ebpf.map_mut("BLOCKLIST").unwrap())?;
    for arg in std::env::args().skip(1) {
        let pid: u32 = arg.parse()?;
        blocklist.insert(pid, 0, 0)?;
        println!("blocking PID {pid}");
    }

    let cgroup = File::open("/sys/fs/cgroup")?;
    let program: &mut CgroupSockAddr = ebpf.program_mut("connect4").unwrap().try_into()?;
    program.load()?;
    program.attach(&cgroup, CgroupAttachMode::Single)?;

    println!("firewall attached. Press Ctrl-C to exit.");
    signal::ctrl_c().await?;
    Ok(())
}
```

- [ ] **Step 4: Build**

Run: `nix develop -c cargo build --locked`
Expected: compiles. If `map_mut` borrow conflicts with `program_mut`, ensure the blocklist block finishes (drops its borrow) before `program_mut` is called, as written.

- [ ] **Step 5: Load with a blocked PID and observe the log (no blocking yet)**

Terminal C first: open a shell, run `echo $$` to get its PID (call it `P`).
Terminal A: `nix develop -c bash -c "cargo run --locked -- P"` (substitute `P`).
Terminal B: `sudo cat /sys/kernel/tracing/trace_pipe`
Terminal C: `curl -s 1.1.1.1 -o /dev/null; echo exit=$?`

Expected: trace pipe shows `pid P is on the blocklist (allowing for now)`, and curl still SUCCEEDS (exit 0). This proves userspace->kernel state sharing works before any enforcement.

- [ ] **Step 6: Update README progress header**

Check Step 4, move "you are here" to Step 4.

- [ ] **Step 7: Commit**

```bash
git add firewall-ebpf/src/main.rs firewall/src/main.rs README.md
git commit -m "step-4: blocklist map; kernel logs blocked PIDs (no enforcement yet)"
```

---

## Task 5: Step 5 - The kill switch (`step-5`)

**Concept:** the return value controls kernel behavior. One-line change from "log" to "deny".

**Files:**
- Modify: `firewall-ebpf/src/main.rs`
- Modify: `README.md`

**Live diff (instructor types):** change the blocklist branch to `return 0`. **Pre-staged:** everything else.

- [ ] **Step 1: Create the branch from step-4**

```bash
git switch step-4 && git switch -c step-5
```

- [ ] **Step 2: Deny connections from blocked PIDs**

Write `firewall-ebpf/src/main.rs`:

```rust
#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_printk},
    macros::{cgroup_sock_addr, map},
    maps::HashMap,
    programs::SockAddrContext,
};

#[map]
static BLOCKLIST: HashMap<u32, u8> = HashMap::with_max_entries(1024, 0);

#[cgroup_sock_addr(connect4)]
pub fn connect4(_ctx: SockAddrContext) -> i32 {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;

    if unsafe { BLOCKLIST.get(&pid) }.is_some() {
        unsafe { bpf_printk!(c"connect4: BLOCKING pid %d", pid) };
        return 0; // 0 = deny the connect() call
    }
    1 // allow everyone else
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
```

- [ ] **Step 3: Build**

Run: `nix develop -c cargo build --locked`
Expected: compiles.

- [ ] **Step 4: Load and observe a blocked PID failing to connect**

Terminal C: open a shell, `echo $$` -> PID `P`.
Terminal A: `nix develop -c bash -c "cargo run --locked -- P"`.
Terminal C: `curl -sv 1.1.1.1 -o /dev/null; echo exit=$?`

Expected: curl FAILS to connect (non-zero exit; connect() returns EPERM/"Permission denied"). Trace pipe shows `BLOCKING pid P`. From a DIFFERENT shell (different PID), curl still succeeds. This is the kill switch.

- [ ] **Step 5: Update README progress header**

Check Step 5, move "you are here" to Step 5.

- [ ] **Step 6: Commit**

```bash
git add firewall-ebpf/src/main.rs README.md
git commit -m "step-5: deny connections from blocked PIDs (the kill switch)"
```

---

## Task 6: Step 6 / solution - IPv6 and polish (`step-6`)

**Concept:** IPv6 bypass; closing the obvious hole. A connect4-only firewall is silently bypassed by IPv6-capable apps.

**Files:**
- Modify: `firewall-ebpf/src/main.rs`
- Modify: `README.md`

**Live diff (instructor types):** a second hook for `connect6` that reuses the same blocklist. **Pre-staged:** nothing new.

- [ ] **Step 1: Create the branch from step-5**

```bash
git switch step-5 && git switch -c step-6
```

- [ ] **Step 2: Add a connect6 hook sharing the blocklist**

Write `firewall-ebpf/src/main.rs`:

```rust
#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_printk},
    macros::{cgroup_sock_addr, map},
    maps::HashMap,
    programs::SockAddrContext,
};

#[map]
static BLOCKLIST: HashMap<u32, u8> = HashMap::with_max_entries(1024, 0);

// Shared decision for both IPv4 and IPv6 connect attempts.
fn decide() -> i32 {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    if unsafe { BLOCKLIST.get(&pid) }.is_some() {
        unsafe { bpf_printk!(c"connect: BLOCKING pid %d", pid) };
        return 0; // deny
    }
    1 // allow
}

#[cgroup_sock_addr(connect4)]
pub fn connect4(_ctx: SockAddrContext) -> i32 {
    decide()
}

#[cgroup_sock_addr(connect6)]
pub fn connect6(_ctx: SockAddrContext) -> i32 {
    decide()
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
```

- [ ] **Step 3: Attach connect6 in the loader**

In `firewall/src/main.rs`, after the existing `connect4` attach block, add a `connect6` attach (pre-staged; insert before the `println!("firewall attached...`):

```rust
    let program6: &mut CgroupSockAddr = ebpf.program_mut("connect6").unwrap().try_into()?;
    program6.load()?;
    program6.attach(&cgroup, CgroupAttachMode::Single)?;
```

- [ ] **Step 4: Build**

Run: `nix develop -c cargo build --locked`
Expected: compiles.

- [ ] **Step 5: Load and observe IPv6 also blocked**

Terminal C: shell with PID `P`.
Terminal A: `nix develop -c bash -c "cargo run --locked -- P"`.
Terminal C: `curl -s -6 http://[2606:4700:4700::1111] -o /dev/null; echo exit=$?` (IPv6) and the IPv4 curl.

Expected: both IPv4 and IPv6 connects from PID `P` are denied (non-zero exit), trace pipe shows `BLOCKING pid P` for each. If the guest has no IPv6 route, note that and verify connect6 at least loads/attaches.

- [ ] **Step 6: Update README progress header and mark the ladder complete**

Check Step 6; note this branch is also the `solution`.

- [ ] **Step 7: Commit and tag as solution**

```bash
git add firewall-ebpf/src/main.rs firewall/src/main.rs README.md
git commit -m "step-6: connect6 closes the IPv6 bypass (solution)"
git tag solution
```

---

## Task 7: Tag the step branches and return to main

**Files:** none (git hygiene).

- [ ] **Step 1: Confirm all branches exist and build**

Run: `git branch` and confirm `step-1` through `step-6` exist. Spot-check that `step-1` and `step-5` still build:
```bash
for b in step-1 step-5; do git switch $b && nix develop -c cargo build --locked; done
```
Expected: both build cleanly.

- [ ] **Step 2: Return to main**

```bash
git switch main
```

- [ ] **Step 3: Record ladder completion**

Append a "Step ladder complete" section to `docs/spike-notes.md` noting any deviations found during execution (verifier messages, the actual EPERM behavior, IPv6 route availability) and confirming each branch builds and loads.

```bash
git add docs/spike-notes.md
git commit -m "docs: step ladder complete; record per-step verification results"
```

---

## Self-Review (completed by plan author)

**Spec coverage:** Implements the spec's step ladder Steps 1-6: catch the hook (Task 1), read PID (Task 2), read destination (Task 3), blocklist map with log-before-enforce (Task 4, the deliberate "log, don't enforce" hinge), the kill switch (Task 5), and connect6 polish (Task 6). Checkpoint branches `step-1`..`step-6`/`solution` are created per the spec's catch-up mechanism, and each branch's README progress header is updated per the spec's "you are here" convention. The live-coding principle is honored via per-task live-diff annotations and minimal hand-typed code. Deferred to Plan 3 (by design): instructor notes, the `harmonia` LAN cache, and the CI test matrix. The TC packet-drop stretch remains out of the core ladder per the spec.

**Logging-mechanism note (flag for user):** Steps 1-3 log via `bpf_printk` -> trace pipe rather than aya-log, to keep the loader free of perf-buffer polling boilerplate and the live diffs minimal. aya-log remains demonstrated in Step 0. This is a deliberate reading of the "show both" + "minimal live code" decisions; confirm or override.

**Placeholder scan:** No TBD/TODO/"similar to" placeholders. Each code step shows the full file (the engineer may read tasks out of order). The only substituted token is the runtime PID `P`, which the engineer obtains via `echo $$` as instructed.

**Type consistency:** `BLOCKLIST: HashMap<u32, u8>` is consistent across eBPF (`aya_ebpf::maps::HashMap`) and userspace (`aya::maps::HashMap<_, u32, u8>`, `.insert(pid, 0, 0)`). The `connect4`/`connect6` fns return `i32` (`1` allow / `0` deny) consistently. The loader uses `ebpf.program_mut("connect4")` / `"connect6"` matching the fn names, and `ebpf.map_mut("BLOCKLIST")` matching the map name.
