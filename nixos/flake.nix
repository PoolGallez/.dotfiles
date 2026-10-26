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
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = inputs @ { self, nixpkgs, home-manager, sops-nix, plasma-manager, ... }:
	let
	   lib = nixpkgs.lib;
	   system = "x86_64-linux";
	   pkgs = import nixpkgs {inherit system; };
  	in {
		nixosConfigurations = {
			triskelion = lib.nixosSystem {
				inherit system;
				modules = [
				      ./hosts/triskelion/configuration.nix
				      sops-nix.nixosModules.sops
				];
				specialArgs = {
				inherit inputs;
				};
			};
			getriebe = lib.nixosSystem {
				inherit system;
				modules = [
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
				      ./hosts/rocky/configuration.nix
				      sops-nix.nixosModules.sops
				];
				specialArgs = {
				inherit inputs;
				};

			};
		};
		# One home configuration per desktop host, named user@host so a plain
		# `home-manager switch --flake .` picks the right one. Each follows
		# its host's my.desktop.environment — switching DE there switches
		# the user-level desktop settings too.
		homeConfigurations = let
		  homeFor = host: home-manager.lib.homeManagerConfiguration {
			  inherit pkgs;
			  modules = [
			  plasma-manager.homeModules.plasma-manager
			  ./home.nix
			  (let os = self.nixosConfigurations.${host}.config; in {
			    my.home.desktop.environment = os.my.desktop.environment;
			    my.home.desktop.tabletSwitch = os.my.hardware.tablet-switch.enable;
			  })
			  ];
			  extraSpecialArgs = {inherit inputs;};
		  };
		in {
		     "pool@getriebe" = homeFor "getriebe";
		     "pool@triskelion" = homeFor "triskelion";
		};

  	};
}
