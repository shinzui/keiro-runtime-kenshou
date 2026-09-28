{ inputs, pkgs, hp, lock, descriptor, cohort, variant, localNames }:
let
  lib = pkgs.lib;
  sourceFor = component: pin:
    let
      entry = lock.packages.${pin.name};
    in
    if component.source.type == "hackage" then
      { type = "hackage"; sha256 = entry.tarballSha256; }
    else
      {
        type = "git";
        location = component.source.location;
        rev = component.source.rev;
        subdir = pin.subdir or null;
      };
  resolved = component: {
    inherit (component) id moriUri;
    packages = map
      (pin: {
        name = pin.name;
        version = hp.${pin.name}.version;
        source = sourceFor component pin;
      })
      component.packages;
  };
  components = map resolved descriptor.components;
  sourceText = source:
    if source.type == "hackage" then
      "hackage:${source.sha256}"
    else
      "git:${source.location}@${source.rev}#${if source.subdir == null then "-" else source.subdir}";
  packageLines = lib.concatMap
    (component: map
      (package: "${package.name} ${package.version} ${sourceText package.source} -")
      component.packages)
    components;
  compiler = "ghc-${hp.ghc.version}";
  planLines = packageLines ++ [
    "compiler ${compiler}"
    "resolver nix"
    "nixpkgs ${inputs.nixpkgs.rev}"
    "haskell-nix ${inputs.haskell-nix.rev}"
  ];
  planHash = "sha256:${builtins.hashString "sha256" (lib.concatStringsSep "\n" (lib.sort builtins.lessThan planLines))}";
  hostParts = lib.splitString "-" pkgs.stdenv.hostPlatform.system;
  value = {
    schema = "kenshou.cohort-identity/v1";
    resolver = "nix";
    inherit cohort compiler planHash components;
    cabalVersion = "nix";
    arch = builtins.head hostParts;
    os = builtins.elemAt hostParts 1;
    indexState = descriptor.indexState;
    descriptorSha256 = lock.descriptorSha256;
  };
  payloadValue = {
    schema = "kenshou.payload-identity/v1";
    inherit cohort variant compiler;
    system = pkgs.stdenv.hostPlatform.system;
    nixpkgsRevision = inputs.nixpkgs.rev;
    haskellNixRevision = inputs.haskell-nix.rev;
    packages = map (name: { inherit name; version = hp.${name}.version; }) localNames;
  };
in
{
  inherit value payloadValue;
  file = pkgs.writeText "kenshou-${cohort}-cohort-identity.json" (builtins.toJSON value);
  payloadFile = pkgs.writeText "kenshou-${cohort}-${variant}-payload-identity.json" (builtins.toJSON payloadValue);
}
