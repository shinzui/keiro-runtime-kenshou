{ inputs, pkgs, hp, cli, descriptor, cohort, variant, strictBounds }:
let
  lib = pkgs.lib;
  # getCabalDeps is the pinned nixpkgs builder's dependency interface. Its
  # upstream contract is unstable, so missing attributes fail evaluation.
  # Canonical owner: mori://nixos/nixpkgs (artifact-level URI pending),
  # project-relative pkgs/development/haskell-modules/generic-builder.nix.
  roots = [ cli ] ++ lib.concatMap
    (component: map (pin: hp.${pin.name}) component.packages)
    descriptor.components;
  dependencies = drv: lib.filter (value: lib.isDerivation value && value ? getCabalDeps)
    (lib.concatLists (builtins.attrValues drv.getCabalDeps));
  closure = builtins.genericClosure {
    startSet = map (drv: { key = drv.drvPath; inherit drv; }) roots;
    operator = item: map (drv: { key = drv.drvPath; inherit drv; }) (dependencies item.drv);
  };
  nativeNames = [
    "buildTools"
    "executableFrameworkDepends"
    "executablePkgconfigDepends"
    "executableSystemDepends"
    "executableToolDepends"
    "extraLibraries"
    "libraryFrameworkDepends"
    "libraryPkgconfigDepends"
    "librarySystemDepends"
    "libraryToolDepends"
    "pkg-configDepends"
  ];
  record = item:
    let
      drv = item.drv;
      inspected = pkgs.haskell.lib.compose.overrideCabal
        (args: {
          passthru = (args.passthru or { }) // {
            perfBuildSettings = {
              configureFlags = args.configureFlags or [ ];
              buildFlags = args.buildFlags or [ ];
              patches = map toString (args.patches or [ ]);
              jailbreak = args.jailbreak or false;
              editedCabalFile = args.editedCabalFile or null;
              descriptionRevision = args.revision or null;
              enableLibraryProfiling = args.enableLibraryProfiling or null;
              enableExecutableProfiling = args.enableExecutableProfiling or null;
              enableSharedLibraries = args.enableSharedLibraries or null;
              enableSharedExecutables = args.enableSharedExecutables or null;
            };
          };
        })
        drv;
      configureFlags = inspected.perfBuildSettings.configureFlags;
      cabalFlags = lib.filter (flag: lib.hasPrefix "-f" flag) configureFlags;
      flagRecord = flag:
        let disabled = lib.hasPrefix "-f-" flag; in {
          name = lib.removePrefix (if disabled then "-f-" else "-f") flag;
          value = !disabled;
        };
    in
    {
      name = drv.pname;
      version = drv.version;
      source = {
        path = toString drv.src;
        description = {
          sha256 = inspected.perfBuildSettings.editedCabalFile;
          revision = inspected.perfBuildSettings.descriptionRevision;
        };
      };
      flags = builtins.listToAttrs (map flagRecord cabalFlags);
      settings = inspected.perfBuildSettings // {
        nativeInputs = lib.genAttrs nativeNames
          (name: map toString (drv.getCabalDeps.${name} or [ ]));
      };
    };
in
{
  resolver = "nix";
  compiler = "ghc-${hp.ghc.version}";
  platform = pkgs.stdenv.hostPlatform.system;
  toolchain = {
    harnessRevision = inputs.self.rev or "dirty";
    nixpkgsRevision = inputs.nixpkgs.rev;
    haskellNixRevision = inputs.haskell-nix.rev;
    flakeLockSha256 = "sha256:" + builtins.hashFile "sha256" ../../flake.lock;
    inherit variant strictBounds;
  };
  packages = lib.sort (left: right: left.name < right.name) (map record closure);
}
