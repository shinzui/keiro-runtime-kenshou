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
      # cabal2nix includes disabled test arguments in its function signature.
      # Permit absent arguments only when they disappear from the production
      # dependency lists; the assertion below rejects any required null input.
      missing = lib.filter
        (argument: !(builtins.hasAttr argument hself) && !(builtins.hasAttr argument pkgs))
        (builtins.attrNames (builtins.functionArgs (import expression)));
      base = hself.callPackage expression (lib.genAttrs missing (_: null));
    in
    pkgs.haskell.lib.compose.overrideCabal
      (args:
        assert lib.assertMsg
          (lib.all (dependency: dependency != null)
            (lib.concatMap (key: args.${key} or [ ]) [
              "libraryHaskellDepends"
              "executableHaskellDepends"
              "setupHaskellDepends"
              "libraryToolDepends"
              "executableToolDepends"
              "setupToolDepends"
            ]))
          "resolved production dependency is unavailable for ${name}";
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
