{ arguments, named, haskellPackages, systemPackages, compilerPackages }:
let
  missing = builtins.filter
    (argument: !(builtins.hasAttr argument haskellPackages) && !(builtins.hasAttr argument systemPackages))
    arguments;
  unavailableHaskell = argument:
    builtins.elem argument missing
    || (builtins.hasAttr argument haskellPackages && haskellPackages.${argument} == null
    && !(builtins.hasAttr argument compilerPackages));
  productionNames = builtins.concatMap (key: named.${key} or [ ]) [
    "libraryHaskellDepends"
    "executableHaskellDepends"
    "setupHaskellDepends"
    "libraryToolDepends"
    "executableToolDepends"
    "setupToolDepends"
  ];
  nativeKeys = suffixes: builtins.concatMap
    (component: map (suffix: component + suffix) suffixes)
    [ "library" "executable" "setup" ];
  nativeProductionNames = builtins.concatMap (key: named.${key} or [ ])
    ((nativeKeys [ "SystemDepends" "PkgconfigDepends" "FrameworkDepends" ])
      ++ [ "extraLibraries" "pkg-configDepends" ]);
  nativeNames = builtins.concatMap (key: named.${key} or [ ])
    ((nativeKeys [ "SystemDepends" "PkgconfigDepends" "FrameworkDepends" ])
      ++ [
      "testSystemDepends"
      "testPkgconfigDepends"
      "testFrameworkDepends"
      "benchmarkSystemDepends"
      "benchmarkPkgconfigDepends"
      "benchmarkFrameworkDepends"
      "extraLibraries"
      "pkg-configDepends"
    ]);
  unavailableNative = argument:
    !(builtins.hasAttr argument systemPackages) || systemPackages.${argument} == null;
in
{
  inherit missing;
  # cabal2nix's generated package set passes native inputs explicitly. Its
  # default callPackage scope gives Haskell packages precedence, so a native
  # zlib input would otherwise recursively resolve to the Haskell zlib package.
  systemOverrides = builtins.listToAttrs (map
    (name: { inherit name; value = systemPackages.${name} or null; })
    nativeNames);
  unavailableProduction = builtins.filter unavailableHaskell productionNames
    ++ builtins.filter unavailableNative nativeProductionNames
    ++ builtins.filter (name: builtins.elem name nativeNames) productionNames;
}
