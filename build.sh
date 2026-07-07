#!/bin/sh
set -eu

version="${VERSION:-0.1.0}"

nim c -d:release -d:ssl --threads:on --mm:orc \
  -d:Version="$version" \
  --nimcache:build/nimcache \
  --out:build/k8s-image-availability-exporter \
  k8s_image_availability_exporter.nim
