{ inputs, ... }:

{
  # Define nixos packages with the overlay and use it in the hosts
  nixpkgs = {
    overlays = [
        inputs.emacs-overlay.overlays.default
    ];

    config = {
      allowUnfree = true;
      allowUnfreePredicate = _: true;
    };
  };
}
