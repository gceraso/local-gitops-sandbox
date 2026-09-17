# Self-managed bootstrap (not synced)

These manifests make ArgoCD and Gitea manage *themselves* through ArgoCD, the
way a real cluster usually does. They live outside `app-of-apps/`, so the root
app-of-apps never picks them up.

They are here as reference, not as something to apply. Locally they are a trap:

- **`gitea.yaml`** sets `persistence.enabled: false`, while
  `helm-values/gitea.yaml` — the values `setup.sh` installs with — sets it to
  `true`. Sync this and ArgoCD reconciles Gitea to the persistence-less
  version, deleting the PVC. The repository ArgoCD reads from lives in that
  PVC, so it takes its own source of truth with it.

- **`argocd.yaml`** flips the ArgoCD server Service to `NodePort` and drops the
  ingress. `http://argocd.<domain>` stops resolving, and you lose the UI you
  would use to undo it.

- **`bootstrap-app-of-apps.yaml`** duplicates the root `bootstrap/app-of-apps.yaml`
  that `setup.sh` renders and applies.

Both failure modes are the same shape: the component that reconciles the
cluster is also the thing being reconciled, so a bad sync removes your ability
to fix it. On a real cluster you have a second cluster, a break-glass path, or
at least a Terraform state to re-apply from. Here you have `./teardown.sh`.

To experiment with self-management anyway, move a file under
`app-of-apps/orchestration/` and make sure the Helm values match
`helm-values/` exactly. Then expect to rebuild at some point.
