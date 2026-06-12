# Instructor Notes

Presenter guide for the eBPF + Rust firewall workshop. Participant-facing setup is in
the top-level `README.md`; this file is for running the session.

## Before the day

- Tell participants to do the README "Setup" section as homework: install Nix
  (Determinate), clone the repo, run `nix run .#start` once on good internet (the image
  is a few GB), then the Step 0 check. This warms their guest so the room is not pulling
  gigabytes over shared wifi.
- Bring the repo on a USB stick as a fallback for anyone who did not clone it.

## Optional: local Nix cache for a crowd

If many people did not warm their cache at home, serve the closure over the room LAN so
they pull at LAN speed instead of from the internet. On your laptop, from the repo:

```bash
# Simplest: serve your local /nix/store read-only over HTTP.
nix run nixpkgs#nix-serve -- --port 5000
```
Participants then add your laptop as a substituter for one command:
```bash
nix develop --option substituters "http://<your-laptop-ip>:5000 https://cache.nixos.org" \
            --option require-sigs false
```
`nix-serve` serves unsigned paths, hence `require-sigs false` (acceptable on a trusted
workshop LAN). Test this on one machine before relying on it for the room.

## Timing (120-minute slot)

| Segment | Time | Branch |
|---|---|---|
| Setup check + the big picture | 15 min | `main` |
| Step 1: catch the hook | 10 min | `step-1` |
| Step 2: read the PID | 10 min | `step-2` |
| Step 3: read the destination | 15 min | `step-3` |
| Step 4: maps, log before enforce | 25 min | `step-4` |
| Step 5: the kill switch | 15 min | `step-5` |
| Step 6 + the verifier | 15 min | `step-6` |
| Buffer / questions | 15 min | |

Flex: drop to 60 min by demoing Steps 1-3 instead of live-coding them; extend to 180 min
by adding the TC packet-drop stretch (see the design spec).

## How to live-code each step

You start each step on the previous branch and type only the small diff (see the
"Live-coding cheat" below for the exact lines). If you fall behind or a demo breaks,
`git switch step-N` jumps to a known-good checkpoint. Enter the dev shell once, then the
commands are short and Nix-native:

```bash
nix run .#enter        # shell into the guest (from the repo dir)
nix develop            # enter the dev shell once: cargo + toolchain on PATH
cargo build            # build
cargo run -- 1234      # load (auto-sudo via .cargo/config); 1234 = PID to block
```

Keep a second `nix run .#enter` shell open for `sudo cat /sys/kernel/tracing/trace_pipe`.

## Live-coding cheat: the exact delta per step

The full source of each step is on its branch (`git show step-N:firewall-ebpf/src/main.rs`).
Below is just what you TYPE to get from the previous step to this one. eBPF file is
`firewall-ebpf/src/main.rs`; loader is `firewall/src/main.rs`.

**Step 1 (from Step 0): switch tracepoint -> connect4.** Biggest change; consider pasting
the loader. Loader becomes:
```rust
use std::fs::File;
use aya::programs::{CgroupAttachMode, CgroupSockAddr};
use tokio::signal;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut ebpf = aya::Ebpf::load(aya::include_bytes_aligned!(concat!(
        env!("OUT_DIR"), "/firewall")))?;
    let cgroup = File::open("/sys/fs/cgroup")?;
    let program: &mut CgroupSockAddr = ebpf.program_mut("connect4").unwrap().try_into()?;
    program.load()?;
    program.attach(&cgroup, CgroupAttachMode::Single)?;
    println!("firewall attached. Press Ctrl-C to exit.");
    signal::ctrl_c().await?;
    Ok(())
}
```
eBPF becomes (the part you type live):
```rust
use aya_ebpf::{helpers::bpf_printk, macros::cgroup_sock_addr, programs::SockAddrContext};

#[cgroup_sock_addr(connect4)]
pub fn connect4(_ctx: SockAddrContext) -> i32 {
    unsafe { bpf_printk!(c"connect4: a process is connecting") };
    1 // 1 = allow, 0 = deny
}
```

**Step 2 (eBPF only): add the PID.** Add `bpf_get_current_pid_tgid` to the helpers import,
then:
```rust
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    unsafe { bpf_printk!(c"connect4: pid %d is connecting", pid) };
```

**Step 3 (eBPF only): add the destination.** Rename `_ctx` to `ctx`, then:
```rust
    let sa = unsafe { &*ctx.sock_addr };
    let dest_ip = u32::from_be(sa.user_ip4);
    let dest_port = u16::from_be(sa.user_port as u16);
    unsafe { bpf_printk!(c"connect4: pid %d -> ip %x port %d", pid, dest_ip, dest_port as u32) };
```

**Step 4: add the map (eBPF) and seed it (loader).** eBPF: add `macros::map` and
`maps::HashMap` to imports, then the map and a lookup:
```rust
#[map]
static BLOCKLIST: HashMap<u32, u8> = HashMap::with_max_entries(1024, 0);
// inside connect4, replace the printk with:
    if unsafe { BLOCKLIST.get(&pid) }.is_some() {
        unsafe { bpf_printk!(c"connect4: pid %d is on the blocklist (allowing for now)", pid) };
    }
```
Loader: add `use aya::maps::HashMap;` and, before the attach, seed from argv:
```rust
    let mut blocklist: HashMap<_, u32, u8> =
        HashMap::try_from(ebpf.map_mut("BLOCKLIST").unwrap())?;
    for arg in std::env::args().skip(1) {
        let pid: u32 = arg.parse()?;
        blocklist.insert(pid, 0, 0)?;
        println!("blocking PID {pid}");
    }
```

**Step 5 (eBPF only): the kill switch.** One line. In the `if` block, change the message
and add the deny:
```rust
    if unsafe { BLOCKLIST.get(&pid) }.is_some() {
        unsafe { bpf_printk!(c"connect4: BLOCKING pid %d", pid) };
        return 0; // deny
    }
```

**Step 6: IPv6.** eBPF: pull the body into a shared `decide()` and add a second hook:
```rust
fn decide() -> i32 {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    if unsafe { BLOCKLIST.get(&pid) }.is_some() {
        unsafe { bpf_printk!(c"connect: BLOCKING pid %d", pid) };
        return 0;
    }
    1
}

#[cgroup_sock_addr(connect4)]
pub fn connect4(_ctx: SockAddrContext) -> i32 { decide() }

#[cgroup_sock_addr(connect6)]
pub fn connect6(_ctx: SockAddrContext) -> i32 { decide() }
```
Loader: after the connect4 attach, add the connect6 attach:
```rust
    let program6: &mut CgroupSockAddr = ebpf.program_mut("connect6").unwrap().try_into()?;
    program6.load()?;
    program6.attach(&cgroup, CgroupAttachMode::Single)?;
```

## The demo that works: block a shell's own PID

A `curl` forks a child with a fresh PID every run, so you cannot pre-block it. Instead
block a shell's OWN PID and have that shell connect via bash's `/dev/tcp`:

```bash
# In a guest shell:
echo $$                              # this shell's PID, e.g. 1234
: <>/dev/tcp/1.1.1.1/80 && echo ok   # the shell itself calls connect()
```
Then run the firewall blocking that PID (from another guest shell, in the repo):
```bash
nix develop -c bash -c 'cargo run --locked -- 1234'
```
Back in the first shell, `: <>/dev/tcp/1.1.1.1/80` now fails with
`Operation not permitted` (EPERM). A different shell (different PID) still connects.

## Per-step talking points

- **Step 0 (hello):** `bpf_printk` writes to the kernel's global trace pipe
  (`sudo cat /sys/kernel/tracing/trace_pipe`); every command fires it via the `execve`
  syscall. (Aside: there is also a nicer library logger, `aya-log`, that routes lines to
  your own app instead of the global pipe; we use the trace pipe throughout for one
  simple, consistent mechanism.)
- **Step 1 (catch the hook):** `cgroup/connect4` runs inside the `connect()` syscall for
  every process in the cgroup. Returning 1 allows, 0 denies. We attach to the root
  cgroup so it sees everything.
- **Step 2 (PID):** `bpf_get_current_pid_tgid()` packs tgid (the "PID" users see) in the
  high 32 bits; `>> 32` extracts it. This is the process identity the kernel normally
  loses when moving packets.
- **Step 3 (destination):** the target is in the program context (`bpf_sock_addr`).
  `user_ip4` and `user_port` are network byte order, hence `from_be`. Good moment to show
  decoding `1010101` hex back to `1.1.1.1`, and port `80`.
- **Step 4 (maps, log before enforce):** a `HashMap` is shared memory between your app
  and the kernel. The loader writes PIDs; the kernel reads them. We deliberately only LOG
  here, proving the two sides talk before we let the kernel block anything.
- **Step 5 (kill switch):** the entire firewall is one returned value. `return 0` turns
  the log into a denial. Show `/dev/tcp` failing with EPERM, then a different PID still
  working.
- **Step 6 (IPv6):** a connect4-only firewall is silently bypassed by IPv6 apps. The
  `connect6` hook shares the same blocklist. The hook runs before routing, so even with
  no IPv6 route the denial shows as EPERM ("Operation not permitted") rather than
  "Network is unreachable".

## The verifier segment

The verifier checks every path terminates and every memory access is in bounds, before
the program is allowed to load. The natural workshop code passes cleanly (kernel 7.0.10's
verifier even handles bounded loops), so to SHOW the verifier rejecting something, paste
this genuine infinite loop into `connect4` and try to load it:

```rust
#[cgroup_sock_addr(connect4)]
pub fn connect4(_ctx: SockAddrContext) -> i32 {
    loop {
        unsafe { bpf_printk!(c"spinning forever") };
    }
}
```
It compiles and links fine. The rejection happens at LOAD time, captured on kernel
7.0.10:
```
infinite loop detected at insn 4
cur state: R0=scalar() R10=fp0
processed 12 insns (limit 1000000) ...

Caused by:
    Invalid argument (os error 22)
```
Talking points: the error appears at load time (`program.load()`), not at compile time;
the verifier is the kernel protecting itself from your code (here it guarantees your
program terminates); the register/instruction dump and the trace logs are your two
debugging tools. Note the `limit 1000000`: the verifier walks every path up to an
instruction budget.

(Other things that are NOT clean verifier demos here: a 64-bit-math loop fails earlier at
`bpf-linker` with `__multi3 not supported`; aya's safe map API returns `Option`, so the
classic "forgot the null check" rejection cannot occur through it.)

## Troubleshooting

- **`bpf-linker` "Invalid record":** the toolchain LLVM and bpf-linker's LLVM differ. The
  flake pins them together (`llvmPackagesForLinker = llvmPackages_22`); rebuild the dev
  shell. See `docs/spike-notes.md`.
- **Permission denied loading the program:** the loader must run as root. `cargo run`
  already wraps in `sudo -E` via `.cargo/config.toml`.
- **No trace output:** read the pipe as root: `sudo cat /sys/kernel/tracing/trace_pipe`.
- **A step branch misbehaves:** `git switch step-N` for a known-good checkpoint; CI builds
  every branch so they should always compile.
