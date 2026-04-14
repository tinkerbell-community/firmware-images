#!/bin/sh

if [ -f /etc/secrets ]; then
  set -a
  # shellcheck disable=SC1091
  . /etc/secrets
  set +a
fi
