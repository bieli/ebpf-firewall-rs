# Accessing the Linux Kernel with eBPF and Rust

Welcome! In this workshop you build a small firewall that lives inside the Linux
kernel and decides, per process, whether a program is allowed to open network
connections. You write it in Rust on both sides: the kernel program and the
userspace app that controls it.

## Why a VM?

eBPF only exists in the Linux kernel. macOS has no eBPF, so everyone (Mac and Linux
alike) runs the same Linux guest. The image is pinned, so the kernel and its verifier
behave identically for all of us. The only tools you install by hand are Nix and this
repo; everything else, including the VM runner, comes from the flake.

## Setup (please do this before the workshop)

1. **Install Nix** with the Determinate installer (it enables flakes by default):
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
   ```
   Open a new terminal, then check: `nix --version`.

2. **Clone this repo and boot the guest once** (do this at home on good internet, the
   image is a few GB). Run these from the repo directory:
   ```bash
   git clone https://github.com/artogahr/ebpf-firewall-rs.git && cd ebpf-firewall-rs
   nix develop          # host toolchain; launch your editor from here for autocomplete
   nix run .#start      # boots the pinned Linux guest (provides Lima for you)
   nix run .#enter      # opens a shell inside the guest
   ```
   `nix run .#stop` shuts the guest down later.

3. **Confirm it works** with the Step 0 check below. If you see the hello line, you are
   ready.

## How you'll work: edit on your laptop, build in the guest

Your code lives on your laptop (you cloned it there), and the guest mounts your home
directory, so your edits show up inside the guest instantly. The loop is:

1. **Edit** `firewall-ebpf/src/main.rs` (the kernel program) and `firewall/src/main.rs`
   (the loader) with your normal editor on your laptop. (Prefer to stay in the terminal?
   `vim` and `nano` are installed in the guest.)
2. **Build and run inside the guest**, where the Linux eBPF toolchain lives:
   `nix run .#enter`, then `cargo run`.
3. **Watch** the result in the kernel trace pipe (a second `nix run .#enter` shell:
   `sudo cat /sys/kernel/tracing/trace_pipe`).

So: edit on your laptop, `cargo run` in the guest, watch the trace pipe. Note: clone the
repo somewhere under your home directory so the guest's mount can see it.

## The workshop, step by step

Each step is a git branch. Start on `main` (Step 0) and move up the ladder one branch at
a time with `git switch step-N`; if you fall behind, check out the next step and rejoin.
Run `git branch --show-current` if you lose track of where you are.

- **Step 0 (`main`): Hello eBPF.** Load a program and watch it react to the kernel.
  Proves your toolchain works.
- **Step 1 (`step-1`): Catch the hook.** Attach to `cgroup/connect4` and log every
  connection attempt.
- **Step 2 (`step-2`): Read the PID** of the process making the connection.
- **Step 3 (`step-3`): Read the destination** IP and port.
- **Step 4 (`step-4`): Share state with a map.** Userspace pushes a PID onto a
  blocklist; the kernel logs when a blocked PID connects (no blocking yet).
- **Step 5 (`step-5`): The kill switch.** Deny connections from blocked PIDs.
- **Step 6 (`step-6` / `solution`): IPv6 and polish.**

## Step 0 check

Open the guest from the repo directory (the shell lands in the same directory inside
the guest, with `cargo` and the toolchain already on PATH):

```bash
nix run .#enter      # shell into the guest, already in the dev shell
cargo run            # builds the program and loads it into the kernel
```

In a second terminal (`nix run .#enter` again), watch the kernel trace pipe while you
run any command:

```bash
sudo cat /sys/kernel/tracing/trace_pipe
# ...   bpf_trace_printk: hello from eBPF: a process called execve
```

Every command you run triggers a line, because the program fires on the `execve`
syscall. Seeing it means your whole toolchain works. Press Ctrl-C to stop the loader.

## Running this for a crowd?

If you are presenting this to many people at once, a few GB per person over shared wifi
will hurt. Have everyone do the boot step above as homework, and optionally run a local
Nix binary cache on your laptop so the room pulls over the LAN. See
[`docs/instructor-notes.md`](docs/instructor-notes.md) for details.

## License

With the exception of eBPF code, this project is distributed under the terms of either
the [MIT license] or the [Apache License] (version 2.0), at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for
inclusion in this crate by you, as defined in the Apache-2.0 license, shall be dual
licensed as above, without any additional terms or conditions.

### eBPF

All eBPF code is distributed under either the terms of the
[GNU General Public License, Version 2] or the [MIT license], at your option.

[Apache license]: LICENSE-APACHE
[MIT license]: LICENSE-MIT
[GNU General Public License, Version 2]: LICENSE-GPL2
