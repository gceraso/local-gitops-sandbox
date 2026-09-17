# Sandbox GitOps repository

This directory is the content of the Git repository ArgoCD reconciles from.
`push-gitea.sh` copies it, overlays `private/git_dir_skel/`, substitutes
`${VAR}` templates, and force-pushes the result into Gitea.

Edit files here, run `./push-gitea.sh`, and ArgoCD picks up the change within
about 30 seconds.

## Layout

| Path | Synced? | Contents |
|------|---------|----------|
| `app-of-apps/` | yes | Applications and ApplicationSets. The root app-of-apps recurses this tree, so anything added here deploys. |
| `projects/` | yes | AppProject definitions, managed by the `appprojects` Application. |
| `charts/` | yes | Kustomize bases and overlays referenced by ApplicationSets. |
| `workflows/` | on demand | Argo WorkflowTemplates and examples. Nothing syncs these unless an Application points at them. |
| `resources/` | no | Manifests applied by hand for testing. |
| `examples/` | no | Reference material. See `examples/self-managed/README.md` before borrowing from it. |

## Templating

Manifests may use `${VAR}` for any name listed in `RENDER_VARS` in
`config.sh` — `${GITEA_INTERNAL_URL}`, `${ARGO_HOST}`, `${AWS_REGION}` and so
on. ArgoCD's own `{{placeholder}}` syntax is a different form and is passed
through untouched.

A `${VAR}` that is not in `RENDER_VARS` fails the push rather than shipping
the literal text into the cluster.

Because of the templating, files here are not directly `kubectl apply`-able.
Run `./push-gitea.sh` and let ArgoCD apply them, or render one by hand:

```bash
. config.sh && . lib/common.sh && render < git_dir_skel/some/file.yaml
```
