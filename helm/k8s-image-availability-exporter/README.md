# k8s-image-availability-exporter Helm chart

Helm chart for deploying `k8s-image-availability-exporter` into a Kubernetes
cluster.

## Install

```sh
helm upgrade --install k8s-image-availability-exporter \
  ./helm/k8s-image-availability-exporter \
  --namespace monitoring \
  --create-namespace
```

Render manifests locally:

```sh
helm template k8s-image-availability-exporter ./helm/k8s-image-availability-exporter
```

## Important Values

| Value | Default | Description |
| --- | --- | --- |
| `image.repository` | `ghcr.io/zystem/k8s-image-availability-exporter` | Exporter image repository. |
| `image.tag` | chart `appVersion` | Exporter image tag. |
| `rbac.create` | `true` | Create ClusterRole and binding. |
| `rbac.readSecrets` | `false` | Allow cluster-wide Secret reads for private registry credentials. Enable only after accepting this broad permission. |
| `serviceAccount.create` | `true` | Create a ServiceAccount for the exporter. |
| `env.REFRESH_INTERVAL_SECONDS` | `60` | Metrics refresh interval. |
| `env.NAMESPACE_LABEL` | empty | Only scan namespaces with this label. |
| `env.IGNORED_IMAGES` | empty | Tilde-separated image regexes to skip. |
| `env.ALLOWED_IMAGES` | empty | Tilde-separated image regexes to include. |
| `env.ALLOWED_REGISTRY_HOSTS` | `registry-1.docker.io~auth.docker.io` | Exact outbound hosts; a leading `*.` allows subdomains. |
| `env.IMAGE_MIRRORS` | empty | Tilde-separated `original=mirror` image prefix mappings. |
| `env.DEFAULT_REGISTRY` | `index.docker.io` | Registry for unqualified images. |
| `env.ALLOW_PLAIN_HTTP` | `false` | Use HTTP for registry checks. |
| `env.SKIP_REGISTRY_CERT_VERIFICATION` | `false` | Skip registry TLS verification. |
| `env.REGISTRY_CA_FILE` | empty | CA bundle path for registry HTTPS checks. |
| `podMonitor.enabled` | `false` | Create a Prometheus Operator `PodMonitor`. |
| `prometheusRule.enabled` | `false` | Create alerting rules. |

Additional environment variables can be appended with `extraEnv`.

## Private Registries

Private registry support depends on Kubernetes `imagePullSecrets`. Secret reads
are disabled by default because Kubernetes RBAC cannot limit them to pull
secrets. Enabling `rbac.readSecrets` grants cluster-wide Secret reads.

The exporter can scan public images without Secret access. Private images that
depend on `imagePullSecrets` will usually report authentication failures.
Add private registry and separate bearer-token hosts to
`env.ALLOWED_REGISTRY_HOSTS` before enabling their checks.

## Prometheus Operator

Enable scraping and alerts when the cluster has the Prometheus Operator CRDs:

```sh
helm upgrade --install k8s-image-availability-exporter \
  ./helm/k8s-image-availability-exporter \
  --namespace monitoring \
  --set podMonitor.enabled=true \
  --set prometheusRule.enabled=true
```

Use `podMonitor.labels` and `prometheusRule.labels` to match your operator
selectors.
