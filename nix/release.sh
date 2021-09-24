#!/bin/sh

set -e

./nix/bootstrap.sh

nix-build ./nix/default.nix \
  --option sandbox false \
  -v --show-trace
