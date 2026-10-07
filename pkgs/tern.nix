{
  lib,
  stdenv,
  requireFile,
  makeWrapper,
  patchelf,
  binutils,
  bashInteractive,
  nushell,
  vulkan-loader,
  libglvnd,
  wayland,
  libxkbcommon,
  libxcb,
  glib,
  gtk3,
  webkitgtk_4_1,
  libwpe,
  libwpe-fdo,
  pipewire,
  zenity,
  perf,
  glib-networking,
  gsettings-desktop-schemas,
  gst_all_1,
  writeShellScript,
  runCommand,
}:

let
  version = "0.5.3";

  arch =
    if stdenv.hostPlatform.isx86_64 then
      "linux-x86_64"
    else if stdenv.hostPlatform.isAarch64 then
      "linux-arm64"
    else
      throw "Unsupported platform: ${stdenv.hostPlatform.system}";

  filename = "Tern-${version}-${arch}.tar.gz";

  # Hashes per platform (update when bumping versions)
  hashes = {
    "linux-x86_64" = "0b4ryq80y8llb1yzzql750bf2y292kdw18d9af8g60zccmw4rrj4";
    "linux-arm64" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  src = requireFile {
    name = filename;
    sha256 = hashes.${arch};
    message = ''
      Tern is an auth-gated closed-beta product and cannot be fetched automatically.

      1. Download '${filename}' from https://build.stencil.so/ (via GitHub login).
      2. Add the tarball to your local Nix store:

         nix-prefetch-url file://$HOME/Downloads/${filename}

      3. Re-run your nix build or system rebuild.
    '';
  };

  runtimeLibs = [
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
    pipewire
  ];

  runtimePrograms = [
    zenity
    glib.bin
    perf
  ];

  webkitRuntimeEnv = [
    "--prefix GIO_EXTRA_MODULES : ${glib-networking}/lib/gio/modules"
    "--prefix XDG_DATA_DIRS : ${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}"
    "--prefix GST_PLUGIN_SYSTEM_PATH_1_0 : ${lib.getLib gst_all_1.gst-plugins-base}/lib/gstreamer-1.0"
  ];

  runtimeLibraryPath = lib.makeLibraryPath runtimeLibs;

  loginProbe = writeShellScript "tern-login-shell-probe" ''
    case " $* " in
      *__tern_login_path__*)
        exec ${lib.getExe bashInteractive} "$@"
        ;;
    esac
    exec ${lib.getExe nushell} "$@"
  '';

  loginShell = runCommand "tern-login-shell" { } ''
    install -Dm755 ${loginProbe} $out/bin/nu
  '';

in
stdenv.mkDerivation {
  pname = "tern";
  inherit version src;

  nativeBuildInputs = [
    makeWrapper
    patchelf
    binutils
  ];

  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    appDir="$out/opt/tern"
    mkdir -p "$appDir" "$out/bin"
    cp -a . "$appDir/"
    chmod -R u+w "$appDir"

    strip --strip-unneeded "$appDir/tern" || true

    rpath="${runtimeLibraryPath}:\$ORIGIN/../lib:\$ORIGIN"
    patchelf --set-rpath "$rpath" "$appDir/tern"
    patchelf --set-interpreter "${stdenv.cc.bintools.dynamicLinker}" "$appDir/tern"

    makeWrapper "$appDir/tern" "$out/bin/tern" \
      --prefix LD_LIBRARY_PATH : "${runtimeLibraryPath}" \
      --prefix PATH : "${lib.makeBinPath runtimePrograms}" \
      --set SHELL ${loginShell}/bin/nu \
      ${lib.concatStringsSep " " webkitRuntimeEnv}

    runHook postInstall
  '';

  passthru = {
    inherit loginShell;
  };

  meta = {
    description = "Rust-native, Kitty-compatible terminal multiplexer";
    homepage = "https://stencil.so/tern";
    license = lib.licenses.unfree;
    mainProgram = "tern";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
