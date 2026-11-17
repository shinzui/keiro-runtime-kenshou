# Unmanaged, project-specific flake-parts module. This file must be tracked so
# Nix includes it in the flake source.
{ inputs, ... }:
{
  imports = [ ./nix/kenshou ];

  perSystem = { pkgs, system, ... }:
    let
      unfreePkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      # PostgreSQL's major version is a run-time dimension. PostgreSQL 18 stays
      # on PATH while both bin directories remain directly addressable. The
      # partitioned-queue scenarios need pg_partman available to each server.
      postgres17 = pkgs.postgresql_17.withPackages (ps: [ ps.pg_partman ]);
      postgres18 = pkgs.postgresql_18.withPackages (ps: [ ps.pg_partman ]);
      released = import ./nix/kenshou/packages.nix {
        inherit inputs pkgs;
        cohort = "released";
        variant = "default";
      };
      pgEnvHook = pkgs.makeSetupHook { name = "kenshou-pg-env"; }
        (pkgs.writeText "kenshou-pg-env.sh" ''
          export KENSHOU_PG17_BIN="${postgres17}/bin"
          export KENSHOU_PG18_BIN="${postgres18}/bin"
        '');

    in
    {
      haskellProject.extraDevPackages =
        [ pkgs.git pkgs.dhall pkgs.dhall-json pkgs.check-jsonschema pkgs.zstd pkgs.google-cloud-sdk unfreePkgs.redpanda-client pgEnvHook ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.procps pkgs.lsof ];

      treefmt.programs.fourmolu.package = pkgs.haskell.packages.ghc9124.fourmolu;

      packages.kenshou-core = released.hp.kenshou-core;
      packages.kenshou-remote = released.hp.kenshou-remote;
      # Keep the existing executable output while exposing its consumer owner.
      packages.kenshou-cli = released;
      packages.kenshou-suite = released;
    };
}
