{ inputs, ... }:
{
  perSystem = { pkgs, ... }:
    let
      mk = cohort: variant: import ./packages.nix {
        inherit inputs pkgs cohort variant;
      };
    in
    {
      packages = {
        default = mk "released" "default";
        kenshou-released = mk "released" "default";
        kenshou-head = mk "head" "default";
        kenshou-released-info-table = mk "released" "info-table";
        kenshou-head-info-table = mk "head" "info-table";
        kenshou-released-profiled = mk "released" "profiled";
        kenshou-head-profiled = mk "head" "profiled";
      };
    };
}
