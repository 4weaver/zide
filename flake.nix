# zide as a flake — the IDE-like zellij layout environment, packaged so the
# NixOS cockpit can consume it directly.
#
# Two things this flake exists to pin, neither of which upstream's plain
# "clone it somewhere" gives you:
#
#   1. zellij comes from nixpkgs-unstable at the SAME rev the tty.nix service
#      pins. The cockpit's zellij session lives on a unix socket under
#      contract_version_1; keeping both sides on one build means no version
#      skew between the pane-owning server and the client that attaches.
#   2. $EDITOR is baked in. zide's default layout declares the editor pane as
#      `command "$EDITOR"`; if that variable is empty zellij execs nothing and
#      the pane dies, so the wrapper always sets it.
#
# The upstream scripts resolve their own directory ($ZIDE_DIR) and read
# layouts/ + yazi/ + lf/ relative to it, so all of those ship together in one
# output. (`lf/` was already in the repo but never copied or wired: the picker
# had been running as yazi. See bin/zide-pick for why lf is now the default.)
{
  description = "zide — zellij IDE-like layout environment (packaged for the arachnet cockpit)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/aff8a0b28396750446e5537a96461bc4facdb287";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAll (pkgs: let
      # Upstream ships shell scripts, not a build. Installing the tree verbatim
      # is the whole job — a build system here would only add a way to drift
      # from the checked-in scripts.
      zide-unwrapped = pkgs.runCommand "zide-${self.shortRev or "dev"}" {
        # makeWrapper is used below; without this it is not on PATH in the
        # build sandbox and the derivation fails at the wrap step.
        nativeBuildInputs = [pkgs.makeWrapper];
      } ''
        mkdir -p $out/share/zide $out/bin
        cp -r ${./bin} $out/share/zide/bin
        cp -r ${./layouts} $out/share/zide/layouts
        cp -r ${./yazi} $out/share/zide/yazi
        # The lf picker's config, read via `lf -config` (see bin/zide-pick;
        # lf has no LF_CONFIG_HOME). It must sit at the tree root as lf/.
        #
        # substituteInPlace rewrites the @lf@ placeholder to the absolute store
        # path of this lf. lf runs on-redraw bodies with `sh -c` and exports
        # only a fixed set of vars, so a bare `lf` there resolves only if the
        # parent PATH happens to carry it — it does not in the zellij pane, and
        # the failure is silent apart from "lf: command not found" on the
        # status line, leaving the pane at lf's stock ratios. An absolute path
        # removes the dependency entirely.
        cp -r ${./lf} $out/share/zide/lf
        substituteInPlace $out/share/zide/lf/lfrc \
          --replace-fail '@lf@' '${pkgs.lf}/bin/lf'

        chmod +x $out/share/zide/bin/*

        # The scripts do `dirname $(readlink -f "$0")` then take its parent as
        # ZIDE_DIR, so bin/ must sit directly inside the shared tree.
        for f in zide zide-edit zide-pick zide-rename; do
          makeWrapper $out/share/zide/bin/$f $out/bin/$f \
            --set ZIDE_DIR $out/share/zide \
            --prefix PATH : ${pkgs.lib.makeBinPath [
              pkgs.zellij
              # Both pickers ship so either can be selected at runtime
              # (zide-pick defaults to lf; ZIDE_FILE_PICKER / -p switches).
              pkgs.lf
              pkgs.yazi
              pkgs.bc
              pkgs.bash
              pkgs.coreutils
            ]}
        done
      '';
    in {
      # EDITOR is deliberately NOT baked in here: the cockpit wants kak, a
      # plain shell user may want something else, so it stays a call-site
      # decision (see the cockpit wrapper in nixos-config).
      default = zide-unwrapped;
      zide = zide-unwrapped;

      # A session-named launcher. Upstream's bin/zide runs plain
      # `zellij --layout <path>` when started outside a session, which lets
      # zellij pick a RANDOM name (observed: unique-cymbal, oblong-apple,
      # auspicious-diplodocus). That breaks any caller that must attach to a
      # KNOWN session — the browser cockpit above all, where a new random
      # session per connection would defeat `attach --create <name>`.
      #
      # `zellij -s <name> -n <layout>` is the incantation that does both:
      # -s names the session, -n/--new-session-with-layout applies the
      # layout. (`-s --layout` alone does NOT work: with a named session
      # --layout is treated as a new TAB and the session never gets created.)
      #
      # Kept as a SEPARATE attr so upstream's `zide` stays byte-identical and
      # can still do its own random-naming thing for interactive use.
      launcher = pkgs.writeShellApplication {
        name = "zide-session";
        runtimeInputs = [zide-unwrapped pkgs.zellij pkgs.coreutils];
        text = ''
          # usage: zide-session <session-name> [working-dir] [layout]
          name="''${1:?usage: zide-session <session-name> [dir] [layout]}"
          dir="''${2:-$PWD}"
          layout="''${3:-default}"
          # Interpolated at BUILD time: $out is a builder variable, not a
          # runtime one, so it must be spliced in here rather than left as $out.
          layout_path="''${ZIDE_LAYOUT_DIR:-${zide-unwrapped}/share/zide/layouts}/$layout.kdl"
          [ -f "$layout_path" ] || {
            echo "zide-session: no such layout: $layout_path" >&2
            exit 1
          }
          cd "$dir" || exit 1
          # How to get BOTH a chosen session name AND the layout's panes.
          # Measured on zellij 0.45.1, each spelling run for real (PTY, not
          # inferred from --help):
          #   zellij --layout L          -> layout YES, session name RANDOM
          #                                 (circular-accordion, …)
          #   zellij -s nm               -> named, NO layout
          #   zellij -s nm --layout L    -> does NOT create; fails with
          #                                 `Session 'nm' not found` (because
          #                                 --layout applies as a TAB when the
          #                                 session is named, and there is none)
          #   zellij -s nm -n L          -> named AND layout  <-- this one
          #
          # -n / --new-session-with-layout is the flag the earlier version of
          # this wrapper missed; it takes a layout PATH and is documented as
          # "Will start a new session". Verified: `-s vF -n <path>` produces
          # one named session whose tab has the layout's picker+editor panes
          # (selectable_tiled_panes_count 2), where `-s vF` alone gives 1.
          #
          # So there is no need for the old three-case dance around
          # `options --session-name` (which only CREATES, and refuses a
          # dead-but-resurrectable name — i.e. every ordinary reconnect,
          # since session_serialization keeps the session after the last
          # client leaves) plus a human-output `list-sessions` grep.
          #
          # But -s only ever CREATES. Against an existing session it dies
          # with `Session with name "X" already exists. Use attach command…`
          # and exit 1 — a dead connection on every reconnect, which is the
          # cockpit's normal case (every browser connection after the first).
          #
          # So the only question is: does it already exist? That must be
          # answered WITHOUT creating anything — `zellij attach` is
          # create-if-absent, so probing with it always "succeeds" and the
          # bare session it makes is exactly the one-pane bug.
          #
          # Detect on the socket instead of on zellij's own output: zellij
          # puts one file per live session in $XDG_RUNTIME_DIR/zellij/
          # <contract_version>/ and has no other session there. A dead
          # (serialized) session has NO socket, and `attach` resurrects it,
          # which is what we want for that case anyway.
          runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          if [ -S "$runtime_dir/zellij/contract_version_1/$name" ] \
             || [ -S "$runtime_dir/zellij/0.45.1/$name" ]; then
            exec zellij attach "$name"
          fi
          # No socket means no live session: build it, layout and all.
          # `-s` names it, `-n` applies the layout's panes.
          exec zellij -s "$name" -n "$layout_path"
          # ponytail: one socket test, no output parsing. The socket stat is
          # the only zellij-internal detail here; if a future zellij renames
          # the runtime dir the failure mode is a bare single-pane session
          # (because -s -n then hits "already exists"), visible immediately
          # in the browser — not a hang.
        '';
      };
    });
  };
}
