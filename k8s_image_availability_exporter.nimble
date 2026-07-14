import std/os

# Package

version       = "0.1.0"
author        = "zystem"
description   = "Prometheus exporter that checks Kubernetes workload image availability"
license       = "MIT"

srcDir = "src"

bin = @["k8s_image_availability_exporter"]

# Dependencies

requires "nim >= 2.2.4"
requires "yyjson == 1.0.0"
requires "promlite == 0.2.0"
requires "yaml == 2.2.0"

# Tasks

task test, "Run tests":
  exec "nimble c -r -d:ssl --threads:on --mm:orc" &
    " --nimcache:build/nimcache" &
    " tests/t_basic.nim"

task release, "Build release binary":
  var releaseVersion = getEnv("VERSION")
  if releaseVersion.len == 0:
    releaseVersion = getEnv("CI_COMMIT_TAG")
  if releaseVersion.len == 0:
    releaseVersion = version
  if releaseVersion[0] == 'v':
    releaseVersion = releaseVersion[1 .. ^1]

  exec "nimble c -d:release -d:ssl --threads:on --mm:orc" &
    " -d:Version=" & releaseVersion &
    " --nimcache:build/nimcache" &
    " --out:build/k8s-image-availability-exporter" &
    " src/k8s_image_availability_exporter.nim"
