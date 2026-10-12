{ pkgs, resolved }:
hself: _:
let
  lib = pkgs.lib;
  package = name: entry:
    let
      source = pkgs.fetchzip {
        url = "mirror://hackage/${name}-${entry.version}/${name}-${entry.version}.tar.gz";
        inherit (entry) sha256;
      };
      description = pkgs.fetchurl {
        url = "mirror://hackage/${name}-${entry.version}/revision/${toString entry.descriptionRevision}.cabal";
        sha256 = entry.descriptionSha256;
      };
      flags = lib.mapAttrsToList
        (flag: enabled: "--flag=${if enabled then "" else "-"}${flag}")
        resolved.flags.${name};
      expression = hself.haskellSrc2nix {
        inherit name;
        src = description;
        extraCabal2nixOptions = lib.escapeShellArgs ([ "--no-check" ] ++ flags);
      };
      arguments = builtins.attrNames (builtins.functionArgs (import expression));
      # Inspect names before resolving them: nixpkgs represents GHC-provided
      # libraries with null. Cabal's independent plan authenticates those names;
      # an absent production argument must still fail before compilation.
      named = (import expression) (lib.genAttrs arguments
        (argument:
          if argument == "mkDerivation" then (args: args)
          else if argument == "lib" then lib else argument));
      dependencies = import ./resolved-dependencies.nix {
        inherit arguments named;
        haskellPackages = hself;
        systemPackages = pkgs;
        compilerPackages = resolved.compilerPackages;
      };
      base = hself.callPackage expression (lib.genAttrs dependencies.missing (_: null));
    in
    pkgs.haskell.lib.compose.overrideCabal
      (args:
        assert lib.assertMsg
          (dependencies.unavailableProduction == [ ])
          "resolved production dependency is unavailable for ${name}: ${lib.concatStringsSep ", " dependencies.unavailableProduction}";
        {
          src = source;
          revision = toString entry.descriptionRevision;
          editedCabalFile = entry.descriptionSha256;
          doCheck = false;
          doBenchmark = false;
        })
      base;
in
assert resolved.schema == "kenshou.perf-resolved-lock/v1";
lib.mapAttrs package resolved.packages
