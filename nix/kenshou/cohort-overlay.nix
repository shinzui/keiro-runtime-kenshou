{ pkgs, lock }:
hself: _hsuper:
let
  lib = pkgs.lib;
  haskellLib = pkgs.haskell.lib.compose;
  gitSource = entry: pkgs.fetchFromGitHub {
    inherit (entry) owner repo rev hash;
  };
  package = name: entry:
    let
      raw =
        if entry.source == "hackage" then
          hself.callHackageDirect
            {
              pkg = name;
              ver = entry.version;
              inherit (entry) sha256;
            }
            { }
        else if entry.source == "git" then
          let
            src = gitSource entry;
            packageDir = if entry.subdir == "" then src else src + "/${entry.subdir}";
          in
          hself.callCabal2nix name packageDir { }
        else
          throw "unsupported cohort source for ${name}: ${entry.source}";
    in
    haskellLib.dontCheck (haskellLib.doJailbreak raw);
in
lib.mapAttrs package lock.packages
