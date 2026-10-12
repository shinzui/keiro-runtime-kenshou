let
  validate = import ../nix/kenshou/resolved-dependencies.nix;
  inputs = {
    arguments = [ "base" "text" "missing-test" "broken" "missing-library" "tool" ];
    named = { libraryHaskellDepends = [ "base" "text" ]; testHaskellDepends = [ "missing-test" ]; executableToolDepends = [ "tool" ]; };
    haskellPackages = { base = null; text = { }; broken = null; };
    systemPackages = { tool = { }; };
    compilerPackages = { base = "4.21.0.0"; };
  };
  valid = validate inputs;
  absent = validate (inputs // { named = inputs.named // { libraryHaskellDepends = [ "missing-library" ]; }; });
  disabled = validate (inputs // { named = inputs.named // { setupHaskellDepends = [ "broken" ]; }; });
  unauthenticated = validate (inputs // { compilerPackages = { }; });
  nativeInputs = inputs // {
    arguments = inputs.arguments ++ [ "zlib" ];
    named = inputs.named // { libraryPkgconfigDepends = [ "zlib" ]; };
    haskellPackages = inputs.haskellPackages // { zlib = throw "native input forced Haskell package"; };
    systemPackages = inputs.systemPackages // { zlib = { name = "native-zlib"; }; };
  };
  native = validate nativeInputs;
  missingNative = validate (nativeInputs // { systemPackages = inputs.systemPackages; });
  collision = validate (nativeInputs // {
    haskellPackages = inputs.haskellPackages // { zlib = { }; };
    named = nativeInputs.named // { libraryHaskellDepends = [ "zlib" ]; };
  });
in
assert valid.missing == [ "missing-test" "missing-library" ];
assert valid.unavailableProduction == [ ];
assert absent.unavailableProduction == [ "missing-library" ];
assert disabled.unavailableProduction == [ "broken" ];
assert unauthenticated.unavailableProduction == [ "base" ];
assert native.unavailableProduction == [ ];
assert native.systemOverrides.zlib.name == "native-zlib";
assert missingNative.unavailableProduction == [ "zlib" ];
assert collision.unavailableProduction == [ "zlib" ];
{ passed = true; cases = [ "compiler-provided" "disabled-test" "missing-production" "null-production" "unauthenticated-compiler" "system-tool" "native-collision" "missing-native" "ambiguous-input" ]; }
