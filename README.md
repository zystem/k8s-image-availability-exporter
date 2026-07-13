# k8s-image-availability-exporter

Prometheus exporter that checks whether images used by Kubernetes workloads are
available in their registries.

The exporter reads Deployments, StatefulSets, DaemonSets and CronJobs, resolves
`imagePullSecrets` from pod specs or their ServiceAccounts, and checks image
manifests through the Docker Registry HTTP API v2. Private registries such as
Harbor are supported through Docker auth secrets and Bearer token challenges.
Regular containers, init containers and ephemeral containers are checked.

## Build

Install dependencies:

```sh
nimble install --depsOnly -y
```

Run only tests:

```sh
nimble test
```

Build only the release binary:

```sh
nimble release
```

## Configuration

The exporter is configured with environment variables.

| Variable | Default | Description |
| --- | --- | --- |
| `BIND_ADDRESS` | `0.0.0.0` | HTTP bind address. |
| `EXPORTER_PORT` | `9090` | HTTP port. |
| `REFRESH_INTERVAL_SECONDS` | `60` | Metrics refresh interval. Supports plain seconds, `60s`, `5m`, `1h`. |
| `PROM_LITE_DATA_DIR` | `/data` | Directory used by `promlite` for metrics and healthz files. |
| `NAMESPACE_LABEL` | empty | If set, only namespaces with this label are checked. |
| `IGNORED_IMAGES` | empty | Tilde-separated image regexes to skip. |
| `ALLOWED_IMAGES` | empty | Tilde-separated image regexes to include. |
| `IMAGE_MIRRORS` | empty | Tilde-separated `original=mirror` image prefix mappings. |
| `FORCE_CHECK_DISABLED_CONTROLLERS` | empty | Comma-separated controller kinds or `*`. Values are case-insensitive. |
| `DEFAULT_REGISTRY` | `index.docker.io` | Registry used for unqualified images. |
| `ALLOW_PLAIN_HTTP` | `false` | Use `http://` for registry checks. |
| `SKIP_REGISTRY_CERT_VERIFICATION` | `false` | Skip registry TLS verification. |
| `REGISTRY_CA_FILE` | empty | CA bundle for registry HTTPS checks. |
| `KUBECONFIG` | `~/.kube/config` | Kubeconfig path for local runs outside a cluster. |

The binary also prints this list:

```sh
k8s-image-availability-exporter --help
```

## Kubernetes Permissions

In cluster, the exporter uses the pod ServiceAccount token. Outside a cluster,
it falls back to `KUBECONFIG` or `~/.kube/config`. The kubeconfig fallback
is parsed with NimYAML and supports token, tokenFile, client certificate, client
certificate data, certificate authority, certificate authority data and
`insecure-skip-tls-verify`. Relative file paths are resolved from the
kubeconfig directory. Exec-auth plugins are not run by the exporter.

The ServiceAccount needs cluster-wide read access to:

- `namespaces`
- `serviceaccounts`
- `secrets`
- `deployments`
- `daemonsets`
- `statefulsets`
- `cronjobs`

`secrets` access is required for private registries. Without it the exporter can
still check public images, but images that rely on `imagePullSecrets` will report
authentication failures.

## Helm

Install with the included chart:

```sh
helm upgrade --install k8s-image-availability-exporter \
  ./helm/k8s-image-availability-exporter \
  --namespace monitoring \
  --create-namespace
```

Render locally:

```sh
helm template k8s-image-availability-exporter ./helm/k8s-image-availability-exporter
```

## Real-cluster smoke test

Install the chart into a test namespace:

```sh
helm upgrade --install k8s-image-availability-exporter \
  ./helm/k8s-image-availability-exporter \
  --namespace monitoring \
  --create-namespace \
  --set podMonitor.enabled=false
kubectl -n monitoring rollout status deploy/k8s-image-availability-exporter
```

Check the HTTP endpoints:

```sh
kubectl -n monitoring port-forward svc/k8s-image-availability-exporter 9090:9090
curl -fsS http://127.0.0.1:9090/healthz
curl -fsS http://127.0.0.1:9090/metrics | grep k8s_image_availability_exporter_build_info
```

For private registry coverage, deploy a small workload that uses the same
`imagePullSecret` pattern as production and verify the image label appears in
metrics:

```sh
kubectl -n default create secret docker-registry smoke-registry-auth \
  --docker-server=harbor.example.com \
  --docker-username='robot$smoke' \
  --docker-password='REDACTED' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n default create deploy image-availability-smoke \
  --image=harbor.example.com/team/app:tag \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n default patch deploy image-availability-smoke \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"smoke-registry-auth"}]}}}}'
curl -fsS http://127.0.0.1:9090/metrics | grep 'image="harbor.example.com/team/app:tag"'
kubectl -n default delete deploy image-availability-smoke
kubectl -n default delete secret smoke-registry-auth
```

## Metrics

The exporter serves:

- `/metrics`
- `/healthz`

Image availability is emitted as one gauge per state:

- `k8s_image_availability_exporter_available`
- `k8s_image_availability_exporter_absent`
- `k8s_image_availability_exporter_bad_image_format`
- `k8s_image_availability_exporter_registry_unavailable`
- `k8s_image_availability_exporter_authentication_failure`
- `k8s_image_availability_exporter_authorization_failure`
- `k8s_image_availability_exporter_unknown_error`

The exporter also emits `k8s_image_availability_exporter_build_info` with the
binary version, refresh duration, object counters, Kubernetes API error count,
and `k8s_image_availability_exporter_registry_checks_total{mode=...}`.

Kubernetes list calls use API pagination, so large clusters can be scanned
without relying on a single unbounded list response.

Registry checks try `HEAD` first and fall back to `GET` for registries that do
not support manifest `HEAD`.

## CI

The Woodpecker pipeline in `.woodpecker.yaml` runs:

- `nimble install --depsOnly`, `nimble test` and `nimble release`
- release artifact packaging and checksum generation on `v*` tags
- `helm lint`
- `helm template` with `PodMonitor` and `PrometheusRule` enabled
- Helm chart package
- Docker multi-arch build and GHCR publish on `v*` tags
- Helm chart OCI publish on `v*` tags
- GitHub release asset upload on `v*` tags

Release publishing uses Woodpecker's GitHub App credentials exposed through
`CI_NETRC_USERNAME` and `CI_NETRC_PASSWORD`. The GitHub App must have permission
to publish GHCR packages and manage releases.

Docker image publishing uses `woodpeckerci/plugin-docker-buildx` and requires
the Woodpecker agent to allow that privileged plugin, for example:

```yaml
WOODPECKER_PLUGINS_PRIVILEGED=woodpeckerci/plugin-docker-buildx
```
