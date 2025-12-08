{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }:
	let 
	   lib = nixpkgs.lib;
	   system = "x86_64-linux"; 
	   pkgs = nixpkgs.legacyPackages.${system};
  	in {
		nixosConfigurations = {
			triskelion = lib.nixosSystem {
				inherit system ;
				modules = [./hosts/triskelion/configuration.nix];
			};
			getriebe = lib.nixosSystem {
				inherit system;
				modules = [ ./hosts/getriebe/configuration.nix];
			};

		};
		homeConfigurations = {
		     pool = home-manager.lib.homeManagerConfiguration {

                          inherit pkgs;
			  modules = [./home.nix];
		     };


	};

  	};
}
