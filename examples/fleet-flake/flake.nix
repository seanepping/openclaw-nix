{
  description = "Example fleet flake using openclaw-nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    openclaw-nix.url = "path:../..";
    openclaw-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, agenix, openclaw-nix, ... }:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.emacagent = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          agenix.nixosModules.default
          openclaw-nix.nixosModules.default
          ./hosts/emacagent/configuration.nix
        ];
      };
    };
}
