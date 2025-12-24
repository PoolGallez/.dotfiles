{ config, pkgs,  ...} : 

{


  time.timeZone = "Europe/Rome";
  # Select internationalisation properties.
  # Default system language
  i18n.defaultLocale = "en_US.UTF-8";

  # Other properties (settigs metric systems i.e)
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "it_IT.UTF-8";
    LC_IDENTIFICATION = "it_IT.UTF-8";
    LC_MEASUREMENT = "it_IT.UTF-8";
    LC_MONETARY = "it_IT.UTF-8";
    LC_NAME = "it_IT.UTF-8";
    LC_NUMERIC = "it_IT.UTF-8";
    LC_PAPER = "it_IT.UTF-8";
    LC_TELEPHONE = "it_IT.UTF-8";
    LC_TIME = "it_IT.UTF-8";
  };


  # Enable networking
  networking.networkmanager.enable = true;

  # Enable flakes experimental feature (in replacement for channels)
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable garbage collector
  nix.gc.dates = "weekly";
  nix.gc.options = "--delete-older-than 15d";

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

}

