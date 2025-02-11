let nixpkgs = import ./nixpkgs.nix;
in
{
  pkgs ? import nixpkgs {
    overlays = import ./overlay.nix {

    };
  }
}:
with pkgs;

let callPackage = lib.callPackageWith haskellPackages;
    pkg = callPackage ./pkg.nix {inherit lib;};
    systemDeps = [ ];
    testDeps = [ postgresql_13 ];
in
  haskell.lib.overrideCabal pkg (drv: {
    setupHaskellDepends =
      if drv ? "setupHaskellDepends"
      then drv.setupHaskellDepends ++ systemDeps
      else systemDeps;
    testSystemDepends =
      if drv ? "testSystemDepends"
      then drv.testSystemDepends ++ testDeps
      else testDeps;
    isExecutable = false;
    enableSharedExecutables = false;
    enableLibraryProfiling = false;
    isLibrary = true;
    doCheck = true;
    doHaddock = false;
    prePatch = "hpack --force";
  })
