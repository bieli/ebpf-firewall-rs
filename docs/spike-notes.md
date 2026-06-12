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
