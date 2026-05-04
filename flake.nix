{
  description = "OpenClaw NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    # Build seam reuse: we consume upstream's openclaw-gateway.nix +
    # openclaw-gateway-common.nix when constructing overlay packages via
    # `lib.mkGateway`. We do NOT consume their source pin — that's the point.
    nix-openclaw.url = "github:openclaw/nix-openclaw";
    nix-openclaw.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, agenix, nix-openclaw, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      nixosModules.default = import ./modules/openclaw-agent.nix;

      packages.${system}.openclaw-agent-cli = pkgs.callPackage ./pkgs/openclaw-agent-cli.nix {};
      checks.${system}.openclaw-agent-cli = import ./checks/openclaw-agent-cli.nix { inherit pkgs; };

      lib.${system}.mkGateway = import ./lib/mkGateway.nix {
        inherit nixpkgs nix-openclaw system;
      };

      # Example host; copy/adapt for your actual machines.
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          agenix.nixosModules.default
          self.nixosModules.default
          ./hosts/example/configuration.nix
        ];
      };
    };
}
