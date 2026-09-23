# Woodpecker publication credentials

GitHub releases use `woodpeckerci/plugin-release:0.3.1` with the existing
`github_token` secret. Its current global restriction to tag events and the
release plugin is compatible with this configuration.

Docker image and Helm chart publication require a separate `ghcr_token`
secret for the GitHub account matching `CI_REPO_OWNER` (currently `zystem`).
Use a token with `write:packages` and access to the destination GHCR packages.
The secret has not been provisioned by this configuration change.

Allow `tag` events. Do not allow pull-request events.
The Helm step uses commands, so a plugin-image filter on this secret would
prevent it from working. Prefer a repository-scoped secret without an image
filter; it is referenced only by the Helm and Docker publication steps.

Validate the workflow without publishing:

```sh
woodpecker-cli --disable-update-check lint --strict \
  --plugins-privileged woodpeckerci/plugin-docker-buildx:5.2.0
```

Woodpecker 3.18 no longer treats Docker Buildx as privileged by default.
The agent running these image-build steps must include
`woodpeckerci/plugin-docker-buildx:5.2.0` in `WOODPECKER_PLUGINS_PRIVILEGED`.
The lint flag above declares that agent capability; it does not configure the
agent. Confirm the agent setting before running image publication.
