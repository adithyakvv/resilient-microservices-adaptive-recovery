# P1 — Resilient Microservices Adaptive Recovery

An evidence-first capstone for fault handling in a three-service Java system. I built Product, Inventory, and Order services; a Recovery Engine with bounded, profile-specific decisions; six experiment runners; live GUI progress and JSON reports; and Prometheus/Grafana telemetry. The work demonstrates Docker, Kubernetes, fault injection, automation, metrics, diagnosis, action verification, and guaranteed cleanup. **A decision, an executed action, signal recovery, and cleanup are different facts** in this project.

Companion fixed-restart baseline: [B1 — Fixed Pod-Restart Recovery Baseline](https://github.com/adithyakvv/b1-fixed-recovery-baseline).

```text
Browser :18080 → GUI/experiment runners → Product / Inventory / Order (Spring Boot)
                          │                    └→ PostgreSQL (Kubernetes namespace)
                          ├→ Chaos Mesh or bounded application fault
                          ├→ Recovery Engine :8090 → Metrics API + safe actuator
                          └→ event/sample handoff → project Prometheus :19090 → Grafana :13000
```

## Experiments

| Run | Fault and target | Actual policy result to inspect |
| --- | --- | --- |
| E1 | Chaos Mesh CPU StressChaos on Inventory | Bounded `INCREASE_CPU`, followed by exact restoration |
| E2 | Chaos Mesh memory StressChaos on Inventory | E2-only `INCREASE_MEMORY` profile, guard/cap, exact restoration |
| E3 | **Application-level** Order→Inventory delay | Non-mutating Engine observation; not packet loss or NetworkChaos |
| E4 | Bounded Order→Inventory delay | `SIMULATED_DELAY_MITIGATION` disables the delay; no pod restart required |
| E5 | Fixed local HTTP 500 probe | Records a restart **decision only**; no Kubernetes service/Pod restart |
| E6 | Product PodChaos kill | Kubernetes replacement and Engine observation, with UID/readiness evidence |

Saved JSON reports are authoritative for decisions, source timestamps, before/during/after measurements, readiness, and cleanup. `reports/` contains a *small* set of genuine example reports; no historical log, database, or bulk report archive is published. Prometheus graphs are separate scrape-time evidence and may miss brief events. Never count repeated scrapes of one held gauge as new Metrics API observations.

## Stack and setup

Java 21, Spring Boot, Maven, PostgreSQL 17, Python/PowerShell GUI runners, Docker Desktop Kubernetes, Chaos Mesh, Micrometer, Prometheus, and Grafana. This project expects a local Windows/Docker Desktop environment and a working Chaos Mesh installation. Use a dedicated namespace and inspect the manifests before applying them. The checked-in deployment image tags document the developed environment; on a new machine, build/publish images and align tags/pull policy with the available node image workflow rather than assuming host Docker images are available in Kubernetes.

```powershell
mvn clean verify
docker build -t adaptive-product-service:phase2 .\adaptive-product-service
docker build -t adaptive-inventory-service:phase2 .\adaptive-inventory-service
docker build -t adaptive-order-service:phase2 .\adaptive-order-service
# Inspect scripts/load-kubernetes-images.ps1 and the manifest image tags before loading.
powershell -ExecutionPolicy Bypass -File .\scripts\load-kubernetes-images.ps1
```

`infrastructure/kubernetes/postgres.yaml` intentionally contains **no password**. Create a local Secret before applying the stack; never commit it. The service `DB_PASSWORD` environment variable has no public default. Use your own namespace-specific password:

```powershell
$ns = 'resilient-microservices-adaptive-recovery'
kubectl apply -f .\infrastructure\kubernetes\namespace.yaml
$dbPassword = Read-Host 'New project PostgreSQL password'
kubectl -n $ns create secret generic adaptive-postgres-credentials --from-literal=username=postgres --from-literal=password=$dbPassword --from-literal=database=resilient_microservices_adaptive_recovery
kubectl apply -k .\infrastructure\kubernetes
kubectl -n $ns get deployments,statefulsets,pods
```

The database URL in each Deployment and Secret database name must match. Deploy project monitoring from `infrastructure/monitoring/prometheus` only after reviewing its storage and scrape settings. The local Engine is scraped through `host.docker.internal:8090`; verify that **your** Docker Desktop cluster can reach it before trusting Grafana. Do not use a production cluster or shared database for fault experiments.

## Start, stop, health, and tests

With the application, monitoring, images, and Chaos Mesh in place:

```powershell
$env:KUBECTL_BIN = (Get-Command kubectl).Source
mvn -pl recovery-engine -am package
powershell -ExecutionPolicy Bypass -File .\scripts\start-demo-gui.ps1
Invoke-RestMethod http://127.0.0.1:8090/actuator/health
Invoke-RestMethod http://127.0.0.1:18080/api/e1/status
powershell -ExecutionPolicy Bypass -File .\scripts\check-demo-port-forwards.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\stop-demo-gui.ps1
```

GUI `http://127.0.0.1:18080/`; Engine `:8090`; Product/Inventory/Order forwards `:18081–18083`; project Prometheus `:19090`; project Grafana `:13000`. Start/stop scripts manage those local demo processes. **Do not run this demo side by side with another project using those ports.** The scripts and the Engine use `KUBECTL_BIN` when supplied; no personal executable path is required.

Useful offline checks, before connecting to a live cluster:

```powershell
mvn test
powershell -ExecutionPolicy Bypass -File .\scripts\test-e1-preflight.ps1
python -m unittest discover -s .\gui -p 'test_*.py'
```

`gui/index.html` has inline JavaScript; run the included `gui/test_*.js` regression scripts with Node. Runner `-CheckOnly` paths perform server-side dry runs and **contact Kubernetes**; use them only after confirming the intended namespace/context. They do not inject faults.

## Runbook and research limits

- **Preflight `FAIL_SAFE`:** inspect the exact unavailable signal, Metrics API freshness, pod identity, Engine process/JAR, `KUBECTL_BIN`, and dependency health. Do not inject when required signals are missing.
- **Stale GUI state:** compare `/api/e*/status`, progress/run ID, runner PID **command line**, and final JSON. Check-only artifacts are not live experiments.
- **Cleanup disagreement:** independently verify this run's Chaos UID/absence, saved baseline resources, rollout, and readiness. A delete request or matching “After” snapshot alone is not cleanup verification.
- **Flat Grafana line:** compare report source timestamps with Prometheus scrape timestamps. Publish a fresh post-cleanup Metrics API reading if observed; never backfill or write zero for unavailable data.
- **Known evidence limits:** P1 E1 has repeated observations of one Metrics API source sample in some saved runs; do not call those distinct fresh persistence samples. An old P1 E4 `recovery.criteria` phrase says “replacement pod,” but the active E4 action is delay mitigation, not pod replacement. Historical reports remain unchanged.
- **No broad superiority claim:** P1 and [B1](https://github.com/adithyakvv/b1-fixed-recovery-baseline) use different workloads, clusters, faults, signals, thresholds, and actions. Single unmatched E1–E6/BE1–BE6 runs are descriptive or comparable only with limitations. They do **not** establish lower MTTR or universal superiority. A defensible timing comparison requires matched fault/workload/measurement definitions and repeated trials.
