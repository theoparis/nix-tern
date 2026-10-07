{
  stdenv,
}:
let
  inherit (stdenv.hostPlatform) system;

  # Tern is a closed-beta Stencil Labs product. There is no public
  # source or download URL (build.stencil.so is auth-gated).
  version = "0.5.1";
  filename = "Tern-${version}-linux-x86_64.tar.gz";

  # Tern ships no public download, so the tarball lives in the store,
  # added by hand. It stays out of version control.
  #
  # fetchurl copies the content and does not reference this path, so the
  # path has a GC root. Without it, `nix store gc` deletes the tarball and
  # every build fails. To move to a new release:
  #
  #   let version = "0.5.1"
  #
  #   (nix store add-file --name $"Tern-($version)-linux-x86_64.tar.gz"
  #     ~/Downloads/Tern-($version)-linux-x86_64.tar.gz)
  #
  #   (sudo ln -sfn <PATH FROM LAST COMMAND OUTPUT> /nix/var/nix/gcroots/per-user/(id -u)/tern)
  #
  # then update below with the new path and hash.
  #
  # A running Tern pins the old version, so a bump needs all three:
  #
  #   1. Close every Tern window, then stop the daemon:
  #
  #    pkill -f 'tern'
  #
  #   2. Remove symlinks created by Tern
  #
  #   rm ~/.local/bin/tern
  #
  #   3. Rebuild the system.
  #
  release = {
    storePath = "/nix/store/mj4fs9ja1wijnng55yc7zrkkknnbr26a-Tern-0.5.1-linux-x86_64.tar.gz";
    hash = "sha256-DP15+l9LTdXcKAAJdcLcyHcNEj15BY02CblBkRn8qlU=";
  };

  supportedSystems = [
    "x86_64-linux"
  ];

  # DT_NEEDED holds only libc/libm/libdl/libpthread/librt/libutil/
  # libgcc_s, plus libstdc++ as of 0.4.0. Everything else is dlopen()'d
  # at runtime, so autoPatchelf would miss it entirely; this set comes
  # from `strings` on the binary, diffed against the previous release:
  # wgpu's Vulkan + EGL/GLES chain, the Wayland and X11 windows, the
  # WebKitGTK / WPEWebKit bindings for the browser block, and libpipewire
  # for screen sharing. X11 came with 0.5.0 (STENCIL_DISPLAY_SERVER);
  # tern dlopens libxcb.so.1 there, and libxkbcommon covers
  # libxkbcommon-x11.so.0 too, since both ship in one lib/ directory.
  # libX11 itself is still not in the binary -- webkitgtk_4_1 pulls it in
  # through libsoup and gtk3's X11 backend.
  runtimeLibs = with pkgs; [
    stdenv.cc.cc.lib
    vulkan-loader
    libglvnd
    wayland
    libxkbcommon
    libxcb
    glib
    gtk3
    webkitgtk_4_1
    libwpe
    libwpe-fdo
    # tern dlopens libpipewire for screen sharing itself, so the library
    # has to be reachable, not just the daemon.
    pipewire
  ];

  # Programs tern runs at runtime. LD_LIBRARY_PATH cannot supply a
  # program, so these need PATH, not an rpath entry:
  #
  # zenity - the file/save/confirmation dialogs; without it tern reports
  #          "no dialog tool (install zenity or kdialog)"
  # glib   - gdbus, for the settings portal (it lives in glib.bin; plain
  #          `glib` has no bin/ at all)
  # perf   - drives the `perf since` marks
  runtimePrograms = with pkgs; [
    zenity
    glib.bin
    perf
  ];

  # WebKitGTK's TLS backend is a GIO module that libsoup dlopens, and
  # neither webkitgtk nor libsoup carries glib-networking. Without it the
  # browser block cannot make https requests.
  #
  # tern reads the org.gnome.desktop.interface schema itself, so the
  # desktop schemas must be on XDG_DATA_DIRS or the read fails and the
  # settings fall back to tern's own defaults.
  #
  # WebKitGTK plays media through gstreamer; without the plugin path it
  # cannot find a decoder.
  webkitRuntimeEnv = with pkgs; [
    "--prefix GIO_EXTRA_MODULES : ${glib-networking}/lib/gio/modules"
    "--prefix XDG_DATA_DIRS : ${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}"
    "--prefix GST_PLUGIN_SYSTEM_PATH_1_0 : ${lib.getLib gst_all_1.gst-plugins-base}/lib/gstreamer-1.0"
  ];

  runtimeLibraryPath = lib.makeLibraryPath runtimeLibs;

  # Tern learns the login environment by running a probe through the
  # login shell in a pty:
  #
  #   $SHELL -l -i -c 'echo __tern_login_path__; printenv PATH; echo __tern_login_path__'
  #
  # It takes the program from $SHELL (or the passwd database), not from
  # the settings' `shell`, so the configured nushell is asked to answer a
  # POSIX probe. Nushell cannot: it prints only the final pipeline's
  # value, so the leading marker never appears and the reader times out.
  # It also needs `printenv` on PATH, which the probe's scrubbed PATH does
  # not hold on NixOS. On a timeout Tern falls back to the libc default
  # PATH, which has no profile directories: panes and the agents Tern
  # spawns (omp, carly) then lose jj, cargo and everything else from
  # /etc/profiles/per-user/$USER/bin.
  #
  # Give the probe the shell its protocol was written for, and leave
  # every other use of $SHELL on nushell. The probe keeps the same
  # argument list, because Tern adds no nushell-specific flags.
  loginProbe = pkgs.writeShellScript "tern-login-shell-probe" ''
    case " $* " in
      *__tern_login_path__*)
        exec ${lib.getExe pkgs.bashInteractive} "$@"
        ;;
    esac
    exec ${lib.getExe pkgs.nushell} "$@"
  '';

  # Tern links ~/.local/bin/tern to the binary it was started from, so it
  # can be started by a path the wrapper never touched, where its
  # environment is missing. (Since 0.5.0 a Tern under /nix/store writes no
  # such link and no desktop entries, so this is only a safety net for a
  # Tern started some other way.) The session's SHELL points at this shim
  # (see modules/env.nix) as well, so the probe works however Tern was
  # started.
  #
  # The program is installed as bin/nu so $SHELL keeps the file name of a
  # real shell, and Tern's shell detection sees the shell it configured.
  loginShell = pkgs.runCommand "tern-login-shell" { } ''
    install -Dm755 ${loginProbe} $out/bin/nu
  '';

  # Flake packages build against the flake-level pkgs, not the host's, so
  # a host's `unfree.allowedNames` never reaches this derivation. The gate
  # binds at nixpkgs import time, so `pkgs.extend` cannot open it: only a
  # re-import can, and it gets an allowlist for this name alone.
  unfreePkgs = import pkgs.path {
    hostPlatform = pkgs.stdenv.hostPlatform;
    inherit system;
    config = pkgs.config // {
      allowUnfreePredicate = name: lib.getName name == "tern";
    };
  };

in
{
  packages.tern-login-shell = loginShell;

  packages.tern =
    let
      fail = msg: throw "tern: ${msg}";
    in
    unfreePkgs.stdenvNoCC.mkDerivation {
      pname = "tern";
      inherit version;

      src =
        if system == "x86_64-linux" then
          unfreePkgs.fetchurl {
            name = filename;
            url = "file://${release.storePath}";
            inherit (release) hash;
          }
        else
          fail "only x86_64-linux builds are packaged (got ${system})";

      nativeBuildInputs = [
        pkgs.makeWrapper
        pkgs.patchelf
        pkgs.binutils
      ];

      dontConfigure = true;
      dontBuild = true;
      # Doesn't do anything yet but a future release that does ship symbols
      # will get stripped.
      #
      # dontPatchELF keeps the generic fixupPhase from rewriting the
      # RPATH set below; autoPatchelf has no work to do, because everything
      # outside libc/libstdc++ is dlopen()'d at runtime.
      dontPatchELF = true;

      installPhase = ''
        runHook preInstall

        # unpackPhase sets sourceRoot=tern, so cwd is already the tarball's
        # tern/ directory and the only file in it is ./tern.
        appDir="$out/opt/tern"
        mkdir -p "$appDir" "$out/bin"
        cp -a . "$appDir/"
        chmod -R u+w "$appDir"

        # Before the wrapper, so strip sees a real file.
        strip --strip-unneeded "$appDir/tern" || true

        rpath="${runtimeLibraryPath}:\''$ORIGIN/../lib:\''$ORIGIN"
        patchelf --set-rpath "$rpath" "$appDir/tern"
        patchelf --set-interpreter "${pkgs.stdenv.cc.bintools.dynamicLinker}" "$appDir/tern"

        # The wrapper supplies the runtime programs and the WebKit
        # environment.
        #
        # SHELL is the login shell the environment capture spawns; the
        # shim above keeps that probe on bash while everything else stays
        # on nushell. The session sets the same shim, so the wrapper is
        # not needed for the probe -- it keeps Tern working in a session
        # that started before the shim landed.
        makeWrapper "$appDir/tern" "$out/bin/tern" \
          --prefix LD_LIBRARY_PATH : "${runtimeLibraryPath}" \
          --prefix PATH : "${lib.makeBinPath runtimePrograms}" \
          --set SHELL ${loginShell}/bin/nu \
          ${lib.concatStringsSep " " webkitRuntimeEnv}

        runHook postInstall
      '';

      meta = {
        description = "Rust-native, Kitty-compatible terminal multiplexer";
        homepage = "https://stencil.so/tern";
        license = lib.licenses.unfree;
        mainProgram = "tern";
        platforms = supportedSystems;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      };
    };
}
