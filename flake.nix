{
  description = "eBPF + Rust firewall workshop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
    nixos-lima.url = "github:nixos-lima/nixos-lima";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, nixos-lima }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        # aya-template generates no rust-toolchain.toml. The eBPF crate is built via
        # aya-build's cargo-in-cargo step which needs `-Z build-std`, so a nightly
        # toolchain with rust-src is required. selectLatestNightlyWith is reproducible
        # once flake.lock pins rust-overlay.
        rustNightly = pkgs.rust-bin.selectLatestNightlyWith (toolchain:
          toolchain.default.override {
            extensions = [ "rust-src" "rustfmt" "clippy" ];
          });

        # bpf-linker reads the LLVM bitcode that rustc emits, so it MUST be built
        # against the same LLVM major version as the nightly toolchain. The nixpkgs
        # default bpf-linker links LLVM 21, but the current nightly bundles LLVM 22,
        # which produces "ERROR llvm: Invalid record" at link time. Pin bpf-linker to
        # LLVM 22 to match. (If a future nightly bumps to LLVM 23, bump this too.)
        bpfLinker = pkgs.bpf-linker.override { llvmPackagesForLinker = pkgs.llvmPackages_22; };

        # Host shell (laptop, macOS or Linux): the tools to launch the guest.
        hostShell = pkgs.mkShell {
          packages = [ pkgs.lima ];
          shellHook = ''
            echo "Host shell ready. Boot the workshop guest with:"
            echo "  nix run .#start   (or: limactl start ./workshop.yaml)"
          '';
        };

        # Guest shell (inside the Linux VM): the eBPF/Rust toolchain.
        guestShell = pkgs.mkShell {
          packages = [
            rustNightly
            bpfLinker
            pkgs.llvmPackages_22.clang
            pkgs.pkg-config
          ];
        };
      in {
        # Default = guest toolchain (typed most often, inside the VM).
        # `.#host` = the one-time laptop bootstrap that provides Lima.
        devShells.default = guestShell;
        devShells.host = hostShell;
        devShells.guest = guestShell;

        # VM lifecycle as flake apps, so the host commands are pure Nix:
        #   nix run .#start    boot the guest
        #   nix run .#enter    shell into the guest
        #   nix run .#stop     stop the guest
        # `limactl start ./workshop.yaml` names the instance "workshop".
        apps.start = {
          type = "app";
          program = toString (pkgs.writeShellScript "start" ''
            # Lima instances are global (~/.lima), not per-clone. If a "workshop"
            # instance already exists, start it instead of trying to recreate it.
            if ${pkgs.lima}/bin/limactl list -q 2>/dev/null | grep -qx workshop; then
              ${pkgs.lima}/bin/limactl start workshop "$@" 2>/dev/null \
                || echo "Guest 'workshop' is already running. Shell in with: nix run .#enter"
            else
              ${pkgs.lima}/bin/limactl start --name=workshop ./workshop.yaml "$@"
            fi
          '');
        };
        apps.enter = {
          type = "app";
          program = toString (pkgs.writeShellScript "enter" ''
            exec ${pkgs.lima}/bin/limactl shell workshop "$@"
          '');
        };
        apps.stop = {
          type = "app";
          program = toString (pkgs.writeShellScript "stop" ''
            exec ${pkgs.lima}/bin/limactl stop workshop "$@"
          '');
        };
      });
}
