# Unmanaged, project-specific flake-parts module. This file must be tracked so
# Nix includes it in the flake source.
{ inputs, ... }:
{
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
      pgEnvHook = pkgs.makeSetupHook { name = "kenshou-pg-env"; }
        (pkgs.writeText "kenshou-pg-env.sh" ''
          export KENSHOU_PG17_BIN="${postgres17}/bin"
          export KENSHOU_PG18_BIN="${postgres18}/bin"
        '');

      haskellPackages = pkgs.haskell.packages.ghc9124.override {
        overrides = inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs;
      };
      gitRev = inputs.self.shortRev or "dirty";
      kenshou-core =
        haskellPackages.callCabal2nix "kenshou-core" (inputs.self + "/kenshou-core") { };
      kenshou-check =
        haskellPackages.callCabal2nix "kenshou-check" (inputs.self + "/kenshou-check") {
          inherit kenshou-core;
        };
      kenshou-measure =
        haskellPackages.callCabal2nix "kenshou-measure" (inputs.self + "/kenshou-measure") {
          inherit kenshou-core;
        };
      kenshou-diagnose =
        haskellPackages.callCabal2nix "kenshou-diagnose" (inputs.self + "/kenshou-diagnose") {
          inherit kenshou-core kenshou-measure;
        };
      kenshou-telemetry =
        haskellPackages.callCabal2nix "kenshou-telemetry" (inputs.self + "/kenshou-telemetry") {
          inherit kenshou-core kenshou-measure;
        };
      kenshou-pgmq =
        haskellPackages.callCabal2nix "kenshou-pgmq" (inputs.self + "/kenshou-pgmq") {
          inherit kenshou-check kenshou-core kenshou-diagnose kenshou-measure kenshou-telemetry;
        };
      kenshou-cli = pkgs.haskell.lib.compose.overrideCabal
        (drv: {
          configureFlags = (drv.configureFlags or [ ]) ++ [
            "--ghc-option=-DGIT_HASH=\"${builtins.substring 0 7 gitRev}\""
          ];
        })
        (haskellPackages.callCabal2nix "kenshou-cli" (inputs.self + "/kenshou-cli") {
          inherit kenshou-check kenshou-core kenshou-diagnose kenshou-measure kenshou-pgmq kenshou-telemetry;
        });
    in
    {
      haskellProject.extraDevPackages =
        [ pkgs.git pkgs.dhall pkgs.dhall-json pkgs.check-jsonschema unfreePkgs.redpanda-client pgEnvHook ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.procps pkgs.lsof ];

      treefmt.programs.fourmolu.package = pkgs.haskell.packages.ghc9124.fourmolu;

      packages.kenshou-core = kenshou-core;
      packages.kenshou-cli = kenshou-cli;
      packages.default = kenshou-cli;
    };
}
