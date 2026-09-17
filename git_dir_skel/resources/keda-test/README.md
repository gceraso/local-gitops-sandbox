# KEDA test fixtures

Three ScaledObjects covering the states worth alerting on. Nothing syncs this
directory; apply them by hand once the `keda` Application is healthy. The
manifests pin themselves to the `default` namespace.

```bash
kubectl apply -f git_dir_skel/resources/keda-test/
```

| File | State it produces |
|------|-------------------|
| `test-deployment.yaml` | The workload the ScaledObjects target. Apply first. |
| `scaledobject-working.yaml` | `READY=True`, `ACTIVE` reflecting the trigger. The healthy baseline. |
| `scaledobject-broken.yaml` | `READY=False` — the trigger points at a Prometheus that does not exist. What a misconfigured scaler looks like. |
| `scaledobject-paused.yaml` | Annotated `autoscaling.keda.sh/paused-replicas`. Reconciles fine but never scales, which is the state most easily mistaken for healthy. |

Useful because a KEDA alert that only checks whether the operator is running
will miss all three of the interesting failures.

```bash
kubectl get scaledobjects
kubectl describe scaledobject test-app-broken-scaledobject
```

Clean up with `kubectl delete -f git_dir_skel/resources/keda-test/`.
