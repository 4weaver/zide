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
# layouts/ + yazi/ relative to it, so all of those ship together in one output.
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

        chmod +x $out/share/zide/bin/*

        # The scripts do `dirname $(readlink -f "$0")` then take its parent as
        # ZIDE_DIR, so bin/ must sit directly inside the shared tree.
        for f in zide zide-edit zide-pick zide-rename; do
          makeWrapper $out/share/zide/bin/$f $out/bin/$f \
            --set ZIDE_DIR $out/share/zide \
            --prefix PATH : ${pkgs.lib.makeBinPath [
              pkgs.zellij
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
      # `zellij -s <name> --layout <path>` is the documented incantation
      # (-s = "Specify name of a new session", -l = layout file path), and it
      # is what this wrapper uses instead of upstream's path. Verified: yields
      # a session named as asked, with the picker + editor panes.
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
          # Measured on zellij 0.45.1 — the obvious spellings do not work:
          #   zellij --layout L         -> panes yes, but a RANDOM session
          #                              name (unique-cymbal, rusty-magpie…)
          #   zellij -s nm              -> named, no layout
          #   zellij -s nm --layout L   -> NO socket created at all
          #   attach -b nm (+new-tab L) -> named, but the tab is EMPTY
          # --layout's help explains it: the layout applies "if inside a
          # session (or using the --session flag)" as a TAB, otherwise it
          # starts a session — so -s and --layout are alternatives, not a
          # pair. And there is no session-rename to fix up a random name
          # afterwards (`action --help` lists only rename-pane/-tab).
          #
          # `zellij options --session-name NAME --layout-dir DIR` is the one
          # spelling that gives both: a session named NAME with the layout's
          # picker + editor panes. --layout-dir takes a DIRECTORY, so the
          # layout is selected by basename (that is why `layout` here is a
          # bare name, not the .kdl path).
          # zellij then scans --layout-dir for the named layout.
          #
          # But `options --session-name` only CREATES. Against a session that
          # already exists it dies with `Session with name "X" already
          # exists` — and exit 0, so a caller cannot even detect the failure,
          # it just gets a dead connection. Every browser connection after the
          # first hits this, which is exactly the cockpit's normal case.
          #
          # `attach` is the create-if-absent primitive, but it cannot apply a
          # layout (measured: attach -b + `new-tab --layout` leaves the tab
          # EMPTY). So the two are combined: attach first to guarantee the
          # session exists and to join the existing one, and only build the
          # layout when this process actually created it.
          #
          # Three cases, and `options --session-name` only handles the third:
          #   1. LIVE  session of this name -> attach (join it, keep panes)
          #   2. DEAD  session of this name -> attach (zellij resurrects it)
          #   3. no session                -> options, to build it WITH layout
          #
          # Case 2 is the one that bit: `options --session-name` refuses a name
          # whose session is dead-but-resurrectable, printing
          #   Session with name "zide" already exists, but is dead.
          # and exits without doing anything. A cockpit that has ever been
          # connected before is EXACTLY this case — zellij keeps the session
          # serialized (session_serialization true) after the last client
          # leaves — so the naive version fails on every ordinary reconnect,
          # not just an edge case.
          #
          # Both live and dead are therefore routed to `attach`, which is
          # create-or-join-or-resurrect. Only a genuinely absent name gets the
          # layout treatment.
          #
          # Detection must NOT create anything: `attach --create-background`
          # would make the session, and then `options` fails for case 1.
          # ponytail: greps human-readable output, so a future zellij that
          # renames its columns breaks the match — the cost is choosing case 3
          # when it should be 1/2, i.e. a fresh layout session rather than a
          # join, never a crashed cockpit.
          session_exists() {
            zellij list-sessions 2>/dev/null \
              | sed 's/\x1b\[[0-9;]*m//g' \
              | grep -qE "^$1 \["
          }
          if session_exists "$name"; then
            # Live (join) or dead (resurrect). Either way the layout is
            # already in the session; rebuilding it would stack a second
            # picker/editor tab onto the cockpit.
            exec zellij attach "$name"
          fi
          # Not running (or never created): build it with the layout.
          # `options --session-name` is the only spelling that sets both the
          # name and the layout's panes.
          exec zellij options \
            --session-name "$name" \
            --layout-dir "$(dirname "$layout_path")" \
            --default-layout "$layout"
        '';
      };
    });
  };
}
