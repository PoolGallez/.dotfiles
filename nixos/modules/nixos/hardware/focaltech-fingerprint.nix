# Fingerprint login with FocalTech's proprietary libfprint build, for the
# FT9362 sensor (USB 2808:0752) of the GPD Pocket 4 / GPD Duo, which
# upstream libfprint doesn't support.
#
# FocalTech published the build (libfprint 1.94.4+tod1 with their drivers
# compiled in) at github.com/ftfpteams/focaltech-linux-fingerprint-driver;
# that repo was taken down by DMCA (the libfprint authors objected to LGPL
# code shipped inside a closed binary), so it's fetched here from the
# Wayback Machine, pinned by hash. Nothing of it is stored in this repo.
#
# The blob replaces libfprint-2.so wholesale; headers, pkg-config files
# and udev rules come from nixpkgs' libfprint, which fprintd is rebuilt
# against. fprintd then provides PAM fingerprint auth to both desktops:
# NixOS wires it into GDM (gdm-fingerprint) and Plasma (kde-fingerprint,
# lock screen) automatically, plus login and sudo.
{ config, lib, pkgs, ... }:

let
  cfg = config.my.hardware.focaltech-fingerprint;

  installer = pkgs.fetchurl {
    name = "focaltech-libfprint-1.94.4-tod1.install";
    url = "https://web.archive.org/web/20250308002207id_/https://raw.githubusercontent.com/ftfpteams/focaltech-linux-fingerprint-driver/refs/heads/main/Fedora_Redhat/libfprint-2-2_1.94.4%2Btod1_redhat_all_x64_20250219.install";
    hash = "sha256-9sPWh6pUNVuPdHA4SBYbYx8G1m3PVf1cjqL9k6tY83g=";
  };

  # nixpkgs' libfprint with only the shared library swapped for the blob
  # (no rebuild): fprintd still compiles against its headers and .pc.
  libfprint-focaltech = pkgs.stdenv.mkDerivation {
    pname = "libfprint-focaltech";
    version = "1.94.4-tod1";
    src = installer;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = with pkgs; [ glib gusb pixman nss libgudev ];
    # The installer is a shell script with a tar.gz appended after `main $@`.
    installPhase = ''
      mkdir blob $out
      sed '1,/^main \$@/d' $src | tar -xz -C blob
      cp -r ${pkgs.libfprint}/{include,lib} $out/
      chmod -R u+w $out
      rm -r $out/lib/girepository-1.0  # typelib describes upstream's API
      install -m755 blob/usr/lib64/libfprint-2.so.2.0.0 $out/lib/libfprint-2.so.2.0.0
      substituteInPlace $out/lib/pkgconfig/libfprint-2.pc --replace-fail ${pkgs.libfprint} $out
    '';
    meta = {
      description = "libfprint with FocalTech's proprietary drivers (2808:0752)";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  options.my.hardware.focaltech-fingerprint.enable = lib.mkEnableOption
    "fingerprint auth (fprintd) with FocalTech's proprietary libfprint, for the 2808:0752 sensor";

  config = lib.mkIf cfg.enable {
    services.fprintd = {
      enable = true;
      package = (pkgs.fprintd.override { libfprint = libfprint-focaltech; }).overrideAttrs {
        # Its tests drive libfprint's virtual devices, absent from the blob.
        doCheck = false;
        doInstallCheck = false;
      };
    };
  };
}
