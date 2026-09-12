# Repro/dev environment for zide on arachnet.
#   nix-shell path/to/this/shell.nix
#
# Why a shell and not just "install the tools": zide is a set of bash scripts
# that resolve their own location via $ZIDE_DIR and shell out to zellij, a file
# picker, and $EDITOR. This shell pins all of them together so the versions
# cannot drift apart from each other or from the production cockpit.
{ pkgs ? import <nixpkgs> { } }:
let
  # zellij from the SAME rev the production service uses (tty.nix pins
  # aff8a0b2 for web-terminal-go, whose package comes from nixpkgs-unstable).
  # The flake channel carries zellij 0.44.3, but production runs 0.45.1; both
  # speak socket contract_version_1 (verified), yet keeping them identical means
  # no cross-version surprises when attaching to the live cockpit.
  # ponytail: hardcoded rev — bump it here and in tty.nix together.
  unstable = builtins.getFlake "github:NixOS/nixpkgs/aff8a0b28396750446e5537a96461bc4facdb287";
  unstablePkgs = unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
pkgs.mkShell {
  packages = [
    unstablePkgs.zellij # must match the service's 0.45.1
    pkgs.yazi           # default file picker (zide's ZIDE_FILE_PICKER)
    pkgs.bc             # zide-edit divides path length by 150 to time its writes
    pkgs.kakoune        # the editor; zide has kak mappings, wired up later
  ];

  # zide locates its own files relative to the script, so this must point at
  # THIS checkout — a hardcoded home dir silently breaks elsewhere (the same
  # failure mode kak-config's shell.nix had).
  ZIDE_DIR = toString ./.;
  # The layout's `editor` pane runs `command "$EDITOR"`; an empty EDITOR makes
  # zellij try to exec nothing and the pane dies, so it is set explicitly here
  # rather than inherited.
  EDITOR = "kak";

  shellHook = ''
    # zide's bin/ is not installed anywhere; put this checkout's scripts on PATH
    # so `zide` and `zide-edit` resolve.
    export PATH="$ZIDE_DIR/bin:$PATH"
    export ZIDE_LAYOUT_DIR="$ZIDE_DIR/layouts"

    echo "zide ready ($(zellij --version)) — run: zide <dir> [layout]"
  '';
}
