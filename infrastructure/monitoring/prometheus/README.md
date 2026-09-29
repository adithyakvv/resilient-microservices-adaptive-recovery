# Isolated Prometheus Storage and Selection

This Kustomize package is the project-isolated Phase 3 monitoring stack. It is applied only in the new project namespace.

When a later phase deliberately applies the package, the Prometheus Operator will create a project-local Prometheus instance in the `resilient-microservices-adaptive-recovery` namespace. Its time series are stored on a dedicated 10 Gi persistent volume rather than in the shared Prometheus data directory.

Discovery is isolated in two ways:

- namespace selectors admit monitor resources only from `resilient-microservices-adaptive-recovery`;
- resource selectors admit only `ServiceMonitor`, `PodMonitor`, `Probe`, and `PrometheusRule` objects labeled `app.kubernetes.io/part-of: resilient-microservices-adaptive-recovery`.

The shared Grafana installation may later add this instance as a separate data source. Do not point new-project dashboards at the historical shared Prometheus data source when collecting experiment measurements.

Deployment command:

```powershell
kubectl apply -k infrastructure/monitoring/prometheus
```

The Prometheus Operator instance stores data on the `prometheus-adaptive-recovery-db-*` PVC. Grafana uses its own `adaptive-recovery-grafana-data` PVC and the in-namespace Prometheus service. The dashboard deliberately labels the Recovery Engine decision as unavailable because that component is not deployed in Phase 3.
