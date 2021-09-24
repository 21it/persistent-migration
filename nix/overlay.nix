{
  vimBackground ? "light",
  vimColorScheme ? "PaperColor"
}:
[
  (self: super:
    {
      haskell-ide = import (
        fetchTarball "https://github.com/tkachuk-labs/ultimate-haskell-ide/tarball/25049f90d58e8671fbb79c6026d9f4c36dfc2706"
        ) {
          inherit vimBackground vimColorScheme;
        };
      haskellPackages = super.haskell.packages.ghc901;
    }
  )
]
