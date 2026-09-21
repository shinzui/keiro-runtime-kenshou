# Unmanaged, project-specific flake-parts module. This file must be tracked so
# Nix includes it in the flake source.
{ ... }:
{
  perSystem = { pkgs, ... }:
    let
      # PostgreSQL's major version is a run-time dimension. PostgreSQL 18 stays
      # on PATH while both bin directories remain directly addressable.
      pgEnvHook = pkgs.makeSetupHook { name = "kenshou-pg-env"; }
        (pkgs.writeText "kenshou-pg-env.sh" ''
          export KENSHOU_PG17_BIN="${pkgs.postgresql_17}/bin"
          export KENSHOU_PG18_BIN="${pkgs.postgresql_18}/bin"
        '');
    in
    {
      haskellProject.extraDevPackages =
        [ pkgs.git pkgs.dhall pkgs.dhall-json pgEnvHook ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.procps pkgs.lsof ];

      treefmt.programs.fourmolu.package = pkgs.haskell.packages.ghc9124.fourmolu;
    };
}
