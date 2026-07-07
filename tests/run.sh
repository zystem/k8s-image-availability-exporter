#!/bin/sh
set -eu

nim c -r -d:ssl --threads:on --mm:orc \
  --nimcache:build/nimcache \
  tests/t_basic.nim
