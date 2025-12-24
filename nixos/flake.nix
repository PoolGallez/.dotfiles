{
  description = "Paolos Nixos configuration framework";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, home-manager, ... }:
	let 
	   lib = nixpkgs.lib;
	   system = "x86_64-linux"; 
	   pkgs = import nixpkgs {inherit system; };
  	in {
		nixosConfigurations = {
			triskelion = lib.nixosSystem {
				inherit system;
				modules = [./hosts/triskelion/configuration.nix];
			};
			getriebe = lib.nixosSystem {
				inherit system;
				modules = [ 
				      ./pkgs-db/pkgs.nix
				      ./hosts/getriebe/configuration.nix
				];
				specialArgs = {
				inherit inputs; 
				};

			};

		};
		homeConfigurations = {
		     pool = home-manager.lib.homeManagerConfiguration {
			  inherit pkgs;
			  modules = [
			  ./home.nix];
			  extraSpecialArgs = {inherit inputs;};
		     };


	};

  	};
}
