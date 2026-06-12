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
  `bpf_printk` -> `/sys/kernel/tracing/trace_pipe`. Step 0 framing decision pending
  with user (aya-log vs trace_pipe).
