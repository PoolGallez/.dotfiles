{
  description = "Paolos Nixos configuration framework";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    # Sops for secrets management
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, home-manager, sops-nix, ... }:
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
				      sops-nix.nixosModules.sops
				];
				specialArgs = {
				inherit inputs; 
				};

			};
			rocky = lib.nixosSystem {
				system = "aarch64-linux";
				modules = [ 
				      ./pkgs-db/pkgs.nix
				      ./hosts/rocky/configuration.nix
				      sops-nix.nixosModules.sops
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
