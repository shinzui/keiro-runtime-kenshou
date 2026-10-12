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
in
assert valid.missing == [ "missing-test" "missing-library" ];
assert valid.unavailableProduction == [ ];
assert absent.unavailableProduction == [ "missing-library" ];
assert disabled.unavailableProduction == [ "broken" ];
assert unauthenticated.unavailableProduction == [ "base" ];
{ passed = true; cases = [ "compiler-provided" "disabled-test" "missing-production" "null-production" "unauthenticated-compiler" "system-tool" ]; }
