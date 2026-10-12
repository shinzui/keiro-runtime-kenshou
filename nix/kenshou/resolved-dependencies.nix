{ arguments, named, haskellPackages, systemPackages, compilerPackages }:
let
  missing = builtins.filter
    (argument: !(builtins.hasAttr argument haskellPackages) && !(builtins.hasAttr argument systemPackages))
    arguments;
  unavailable = argument:
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
in
{
  inherit missing;
  unavailableProduction = builtins.filter unavailable productionNames;
}
