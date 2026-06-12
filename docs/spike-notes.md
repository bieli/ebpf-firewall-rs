# Spike notes (foundation)

Running record of what actually worked on real hardware, so Plans 2 and 3 are
grounded in reality rather than guesses. Append findings under each task.

## Environment as found
- Host: Apple Silicon (arm64), macOS, Determinate Nix 3.20.0 installed, no Lima, no cargo on host.

## Findings

### Task 1: Lima
- Installed via `nix profile install nixpkgs#lima`. Version: limactl 2.1.2 (on PATH).
- Pulls QEMU 11.0.0 + spice/gst deps from cache; uses vz on Apple Silicon.

### Task 2: NixOS guest path (DECISION)
- Lima 2.1.2 ships NO built-in `nixos` template (confirmed via `--list-templates`).
  Templates are RHEL-family, Debian/Ubuntu, Alpine, openSUSE, Arch, FreeBSD, k8s, etc.
- Decision (user): use the `nixos-lima` community flake (github:nixos-lima/nixos-lima),
  NixOS guest only, no Ubuntu fallback.
- nixos-lima usage:
  - Quick start (no host Nix build): `limactl start github:nixos-lima --memory 8`,
    then `limactl shell nixos`. Uses their prebuilt image + `nixos.yaml`. v0.0.4 tracks
    nixos-25.11. Recommend >= 8 GiB RAM.
  - Custom flake: input `nixos-lima.url = "github:nixos-lima/nixos-lima/"`,
    `services.lima.enable = true`, build image with
    `nix build .#packages.aarch64-linux.img`. This builds a LINUX image, so it cannot
    run on the Darwin host without a linux-builder.
- Chosen bootstrap: boot the prebuilt image first (Linux-build-free), then apply our
  pinned-kernel config from INSIDE the guest via `nixos-rebuild switch --flake .#workshop`
  (builds natively on Linux). Avoids the Darwin-can't-build-Linux trap.

### Task 2/3: guest booted + eBPF prereqs (PROVEN)
- Image: `nixos-lima-v0.2-aarch64.qcow2` from nixos-lima v0.2 GitHub release. Instance
  name `nixos` (spike). Boot via `limactl start --memory 8 --tty=false github:nixos-lima`.
- Image download ~9 min at ~2 MB/s (07:38 -> 07:47). VMType vz, 4 CPU, 8 GiB, 100 GiB.
- Guest: NixOS 26.05 (Yarara), kernel **7.0.10** aarch64.
- eBPF prereqs ALL satisfied:
  - BTF: `/sys/kernel/btf/vmlinux` present (8.6 MB).
  - cgroup v2: `/sys/fs/cgroup` is `cgroup2fs` (needed for cgroup/connect4 hook).
  - bpf fs: mounted at `/sys/fs/bpf` (mode 700, root-only).
  - tracefs at `/sys/kernel/tracing`, debugfs at `/sys/kernel/debug`. Trace pipe:
    **`/sys/kernel/tracing/trace_pipe`** (root-only, mode 640). Read with sudo.
  - Passwordless `sudo` works in the guest (`sudo whoami` -> root).
- NOTE: spike instance is `nixos`; the real workshop.yaml (Task 7) will name it
  `workshop`. The flake apps target `workshop`.

### Task 4: aya-template scaffold (DONE)
- cargo-generate 0.23.9. Generated non-interactively with:
  `-d program_type=tracepoint -d tracepoint_category=syscalls -d tracepoint_name=sys_enter_execve`
  plus `--silent`. `--destination` dir must already exist (mkdir first).
- Template offers NO `cgroup_sock_addr`/`connect4` type (choices: cgroup_skb,
  cgroup_sockopt, cgroup_sysctl, classifier, fentry, fexit, kprobe, kretprobe, lsm,
  perf_event, raw_tracepoint, sk_msg, sock_ops, socket_filter, tp_btf, tracepoint,
  uprobe, uretprobe, xdp). So Step 0 = tracepoint hello-world; connect4 hook is
  hand-written in Plan 2.
- Modern aya build (KEY for the flake):
  - aya deps come from GIT (github.com/aya-rs/aya), not crates.io. Lock pins a git rev;
    warm-up fetches from GitHub. edition = "2024".
  - NO `rust-toolchain.toml` generated. The build is "cargo-in-cargo":
    `firewall/build.rs` calls `aya_build::build_ebpf([...], Toolchain::default())`,
    which compiles the ebpf crate (needs `-Z build-std`, i.e. NIGHTLY + rust-src).
  - `firewall-ebpf/build.rs` requires `bpf-linker` on PATH (`which("bpf-linker")`).
  - `.cargo/config.toml`: `runner = "sudo -E"` so `cargo run` runs the loader as root.
  - OPEN RISK: aya-build's `Toolchain::default()` may shell out to `cargo +nightly`
    (rustup-style), which does not exist in a Nix shell. Must verify during the first
    in-guest build (Task 8) and, if so, provide nightly as the default toolchain or
    point aya-build at it explicitly.

### Task 5/8: flake build + END-TO-END PROVEN
- Flake: rust-overlay `selectLatestNightlyWith` -> rustc 1.98.0-nightly (2026-06-12),
  LLVM **22.1.6**. extensions: rust-src (needed for `-Z build-std=core`), rustfmt, clippy.
- LLVM MISMATCH (resolved): nixpkgs default `bpf-linker` 0.10.3 links libLLVM **21**,
  but the nightly emits LLVM 22 bitcode -> `ERROR llvm: Invalid record` at link.
  FIX: `pkgs.bpf-linker.override { llvmPackagesForLinker = pkgs.llvmPackages_22; }`
  (override arg is `llvmPackagesForLinker`, NOT `llvmPackages`; defaults to
  `rustc.llvmPackages` = 21). Confirmed bpf-linker then links libLLVM.so.22.1.
  RULE: keep bpf-linker's LLVM major == nightly's LLVM major. If a future nightly
  bumps to LLVM 23, bump llvmPackages_23 (must exist in the pinned nixpkgs).
- aya-build `+nightly` RISK RESOLVED: build logs `which(rustup)=cannot find binary
  path; proceeding with current toolchain`. aya-build falls back to the current Nix
  nightly. No rustup needed.
- Cargo.lock: read-only virtiofs mount can't hold it. Generated on host with
  `cargo generate-lockfile` and committed (also satisfies frozen-deps invariant).
  Build with `cargo build --locked`. For the REAL guest, workshop.yaml mounts the repo
  writable, so this is a spike-only workaround.
- Build invocation (spike): repo mounted RO at /Users/artogahr/workplace/ebpf-firewall-rs;
  `CARGO_TARGET_DIR=/tmp/lima/fw-target` (writable) +
  `nix develop .#guest --command cargo build --locked`. limactl shell mirrors host cwd
  into the guest, so `.#guest` resolves without an explicit cd.
- LOADED + RAN: `sudo RUST_LOG=info /tmp/lima/fw-target/debug/firewall` attached to
  `sys_enter_execve` and logged `[INFO firewall] tracepoint sys_enter_execve called`
  on every execve. FULL STACK PROVEN on Apple Silicon.
- LOGGING MECHANISM: aya-template scaffold uses **aya-log** (logs surface in the
  loader's stdout via `RUST_LOG`, through a perf/ringbuf map), NOT the kernel
  `bpf_printk` -> `/sys/kernel/tracing/trace_pipe`. DECISION (user): show BOTH in
  Step 0. Both proven: aya-log -> `[INFO firewall] execve called`; bpf_printk ->
  `bpf_trace_printk: hello from eBPF: execve called` in /sys/kernel/tracing/trace_pipe.
  `bpf_printk!` macro exists in aya-ebpf 0.1.2 (helpers.rs), takes a `c"..."` literal.

### Task 7/9/10: workshop.yaml + README + finalize (DONE)
- DECISION (user): accept stock nixos-lima v0.2 kernel; SKIP Task 6 (flake kernel pin).
  Reproducibility comes from pinning the image URL + sha512 digest in workshop.yaml.
- workshop.yaml: both-arch nixos-lima v0.2 images (digests from ~/.lima/nixos/lima.yaml),
  `~` mounted WRITABLE (so cargo writes target/ in place, portable to any clone path),
  /tmp/lima writable, memory 8GiB, UDP-68 ignore port-forward (nixos-lima quirk),
  containerd off, vmType unset (Mac=vz, Linux=qemu).
- `nix run .#start` booted instance "workshop" from cached image (no re-download).
  `nix run .#enter` shells in (mirrors host cwd). Confirmed WRITABLE_OK + in-place
  `cargo build --locked` on the fresh instance (cold build ~46s after toolchain fetch).
- RUN COMMAND (proven): `nix develop -c bash -c 'RUST_LOG=info cargo run'`. The
  `.cargo/config.toml` `runner = "sudo -E"` auto-elevates, no manual sudo needed.
- DECISION (user): hand-written code must be MINIMAL (live coding). Step 0 program
  trimmed (dropped scaffold `match try_x()` wrapper). Principle recorded in spec;
  drives Plan 2 (pre-stage boilerplate, tiny per-step live diffs).
- LICENSE-NOTE: aya-template ships dual MIT/Apache (+ GPL2 for eBPF). README keeps it.

## FOUNDATION COMPLETE
Proven stack for Plans 2 and 3 to build on:
- Guest: nixos-lima v0.2 aarch64 qcow2, NixOS 26.05, kernel 7.0.10, BTF + cgroup2.
- Boot: `nix run .#start` (workshop.yaml, instance "workshop"). Enter: `nix run .#enter`.
- Toolchain (flake .#guest): rustc 1.98.0-nightly (LLVM 22) + rust-src;
  bpf-linker 0.10.3 overridden to llvmPackages_22; clang 22; pkg-config.
- Deps: aya 0.13.2 (git a0b8d49), edition 2024, Cargo.lock committed, build `--locked`.
- Build: `nix develop -c cargo build --locked`; run: `RUST_LOG=info cargo run`.
- Step 0 (main): tracepoint sys_enter_execve, aya-log + bpf_printk, both verified.

## STEP LADDER COMPLETE (Plan 2)
All branches step-1..step-6 created, behavior-verified live, and built clean.
`solution` tag = step-6. Tags: step-0, solution. Logging for steps 1-3 via bpf_printk
-> trace_pipe (user decision); aya-log stays the Step 0 showcase.

Per-step verification (on instance `workshop`, kernel 7.0.10):
- step-1: connect4 hook fires on every connect (sh + curl logged). curl allowed.
- step-2: PID logged via `bpf_get_current_pid_tgid() >> 32` (curl child PID seen).
- step-3: dest read from `&*ctx.sock_addr`; `user_ip4`/`user_port` are big-endian
  (`u32::from_be` / `u16::from_be`). Saw `ip 1010101 port 80` for 1.1.1.1:80.
  NOTE: the anticipated verifier moment did NOT bite. The context-pointer deref loads
  cleanly; no verifier objection on kernel 7.0.10. (Plan 3 verifier segment may need a
  deliberately-wrong example to provoke the verifier.)
- step-4: BLOCKLIST HashMap<u32,u8>; loader seeds from argv. Blocked PID LOGGED but
  still connects (ok) -> log-before-enforce hinge proven.
- step-5: `return 0` denies. Blocked PID's connect fails with EPERM
  ("Operation not permitted"). trace shows BLOCKING. Non-blocked PIDs unaffected.
- step-6: connect6 hook shares blocklist via `decide()`. Loader attaches both. The
  cgroup/connect6 hook fires BEFORE routing: with no IPv6 route in the guest, blocking
  changes the v6 error from ENETUNREACH ("Network is unreachable") to EPERM
  ("Operation not permitted"), proving the hook denies. 42 BLOCKING lines observed.

DEMO TECHNIQUE (important for the talk): block a process by a STABLE, KNOWN PID. A
`curl` spawns a child with a fresh PID each run, so you can't pre-block it. Instead use
the shell's own PID: `: <>/dev/tcp/HOST/PORT` runs connect() in the current shell
process (PID = `echo $$`). So the demo is "this shell's PID is N; block N; now THIS
shell cannot open connections". Used a detached bash loop hitting /dev/tcp for testing.

## Verifier example (Plan 3, Task 1) - VERIFIED
Goal: a snippet that compiles+links but the KERNEL VERIFIER rejects at load, for the
verifier teaching segment. Findings on kernel 7.0.10 (modern, strong verifier):
- Candidate A (u64 runtime-bounded loop): FAILS AT LINK (bpf-linker), not verifier:
  "A call to built-in function '__multi3' is not supported" / "only small returns
  supported". 64-bit math. Wrong kind of failure (link, not load). Rejected as example.
- Candidate A' (u32 unbounded `while i < n` loop): LOADS FINE. The modern verifier proves
  the bounded loop terminates. Not a verifier trip.
- aya's `HashMap::get`/`get_ptr` both return Option (null-checked by aya), so the classic
  "forgot the null check" verifier error cannot be reproduced via the safe API.
- WINNER - genuine infinite loop:
  ```rust
  #[cgroup_sock_addr(connect4)]
  pub fn connect4(_ctx: SockAddrContext) -> i32 {
      loop { unsafe { bpf_printk!(c"spinning forever") }; }
  }
  ```
  Compiles and links cleanly; the kernel verifier REJECTS at `program.load()` with:
  ```
  infinite loop detected at insn 4
  processed 12 insns (limit 1000000) ...
  Caused by: Invalid argument (os error 22)   # EINVAL
  ```
  Plus a full register/instruction-trace dump. This is the instructor-notes verifier
  example. Teaching point: fails at LOAD (verifier), not compile; verifier guarantees
  termination; the dump is your debugging tool.

## CI (Plan 3, Task 3)
- `.github/workflows/ci.yml`: matrix over [main, step-1..step-6] on ubuntu-latest;
  Determinate Nix installer + magic-nix-cache; `nix develop .#guest --command cargo build --locked`.
- A Linux runner builds eBPF NATIVELY via the flake (no VM needed), unlike participant Macs.
- Build command re-confirmed on the aarch64 guest for main. x86_64 CI runners are
  UNVERIFIED locally (only aarch64 hardware here) but use the same flake `.#guest` output
  (rust-overlay nightly + llvmPackages_22 bpf-linker both exist for x86_64-linux).

## PLAN 3 COMPLETE
- Verifier example verified (infinite loop -> EINVAL at load). Instructor notes written
  at docs/instructor-notes.md with agenda, per-step talking points, the block-by-PID demo,
  the verifier example, LAN-cache (nix-serve), and troubleshooting.
- CI (.github/workflows/ci.yml) on main and all step branches: builds each branch with
  `nix develop .#guest`. solution tag -> step-6. README links instructor notes.
- All three plans (foundation, step ladder, docs+CI) complete and verified.
