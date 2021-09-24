#!/bin/sh

set -e

stack build --flag persistent-migration:dev --test --no-run-tests --fast

DIR=$(stack path --dist-dir)/build/persistent-migration-test
${DIR}/persistent-migration-test --no-create

TEST_USER=test
if id "$TEST_USER" &>/dev/null; then
  echo "$TEST_USER ===> user already exist"
else
  echo "$TEST_USER ===> creating user"
  /usr/sbin/adduser -S "$TEST_USER" -s /bin/sh
fi

DIR=$(stack path --dist-dir)/build/persistent-migration-integration
/bin/su "$TEST_USER" -c "${DIR}/persistent-migration-integration"
