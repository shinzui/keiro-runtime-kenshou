{ inputs, pkgs, cohort, variant }:
let
  lib = pkgs.lib;
  descriptor = builtins.fromJSON (builtins.readFile (../../cohort + "/${cohort}.json"));
  lock = builtins.fromJSON (builtins.readFile (../cohort-locks + "/${cohort}.lock.json"));
  descriptorHash = builtins.hashFile "sha256" (../../cohort + "/${cohort}.json");
  channel = inputs.haskell-nix.lib.mkChannelExtension {
    channel = "hackage";
    disableProfiling = variant != "profiled";
  };
  infoTables = _: hsuper: lib.optionalAttrs (variant == "info-table") {
    mkDerivation = args: hsuper.mkDerivation (args // {
      configureFlags = (args.configureFlags or [ ]) ++ [
        "--ghc-option=-finfo-table-map"
        "--ghc-option=-fdistinct-constructor-tables"
      ];
    });
  };
  localNames = lib.filter
    (name: lib.hasPrefix "kenshou-" name && builtins.pathExists (../.. + "/${name}/${name}.cabal"))
    (builtins.attrNames (builtins.readDir ../..));
  local = hself: _: lib.genAttrs localNames (name:
    pkgs.haskell.lib.compose.dontCheck
      (hself.callCabal2nix name
        (lib.cleanSourceWith {
          name = "${name}-source";
          src = ../.. + "/${name}";
          filter = _: _: true;
        })
        { }));
  hp = pkgs.haskell.packages.ghc9124.override {
    overrides = lib.composeManyExtensions [
      infoTables
      (channel pkgs.haskell.lib.compose pkgs)
      (import ./cohort-overlay.nix { inherit pkgs lock; })
      local
    ];
  };
  identity = import ./identity.nix {
    inherit inputs pkgs hp lock descriptor cohort variant localNames;
  };
  cli =
    let
      haskellLib = pkgs.haskell.lib.compose;
      base = hp.kenshou-cli;
      lean = haskellLib.disableSharedLibraries
        (haskellLib.disableSharedExecutables
          (haskellLib.disableLibraryProfiling base));
      selected = if variant == "profiled" then haskellLib.enableExecutableProfiling lean else lean;
    in
    haskellLib.justStaticExecutables selected;
  revision = inputs.self.rev or (lib.removeSuffix "-dirty" (inputs.self.dirtyRev or "unknown"));
  dirty = if inputs.self ? rev then "false" else "true";
  package = pkgs.runCommand "kenshou-${cohort}-${variant}"
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
      passthru = {
        cohortIdentity = identity.value;
        cohortIdentityFile = identity.file;
        payloadIdentity = identity.payloadValue;
        inherit hp lock;
      };
    } ''
    mkdir -p "$out/bin" "$out/share/kenshou"
    cp "${cli}/bin/kenshou" "$out/bin/kenshou"
    chmod u+w "$out/bin/kenshou"
    cp "${identity.file}" "$out/share/kenshou/cohort-identity.json"
    cp "${identity.payloadFile}" "$out/share/kenshou/payload-identity.json"
    wrapProgram "$out/bin/kenshou" \
      --set-default KENSHOU_COHORT_IDENTITY "$out/share/kenshou/cohort-identity.json" \
      --set-default KENSHOU_PAYLOAD_IDENTITY "$out/share/kenshou/payload-identity.json" \
      --set-default KENSHOU_HARNESS_REVISION "${revision}" \
      --set-default KENSHOU_HARNESS_DIRTY "${dirty}" \
      --set-default KENSHOU_PG17_BIN "${pkgs.postgresql_17}/bin" \
      --set-default KENSHOU_PG18_BIN "${pkgs.postgresql_18}/bin"
  '';
in
assert lib.assertMsg (descriptorHash == lock.descriptorSha256)
  "cohort lock is stale; run just payload-lock ${cohort}";
package
