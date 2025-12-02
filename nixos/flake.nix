{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
	let 
	   lib = nixpkgs.lib;
  	in {
		nixosConfigurations = {
			triskelion = lib.nixosSystem {
				system = "x86_64-linux";
				modules = [ ../hosts/triskelion/configuration.nix];
			};
		};

  	};
}
