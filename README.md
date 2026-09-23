# K3s Infrastructure POC

A client-commissioned proof of concept for evaluating the migration of a single-server Docker Compose application to Kubernetes.

The project was developed to validate a practical migration path before committing to a larger infrastructure change. The main focus was application availability, PostgreSQL failover, workload isolation, ingress, and behaviour under infrastructure failures.

This repository is a **sanitized public version** of the original private client project. Client names, domains, infrastructure details, proprietary application artifacts, credentials, certificates, and private container images have been removed or replaced with generic equivalents.

## Client context

The original application was running on a single server using Docker Compose.

The client wanted to evaluate moving the application to Kubernetes in order to improve workload isolation and resilience and to establish a foundation for further infrastructure scaling.

The POC was deliberately scoped as an infrastructure validation exercise rather than a production migration.

The key questions were:

- Can the existing application workload run reliably on Kubernetes?
- Can application workloads be separated from the Kubernetes control plane?
- Can PostgreSQL replication and automatic failover be introduced without changing the application architecture?
- What happens when a worker node fails?
- What happens when the Kubernetes control plane becomes unavailable?
- How does the application behave under degraded network conditions?
- Can the infrastructure be kept simple enough to operate and extend later?

The POC provided the client with a working environment in which these scenarios could be tested before making further production infrastructure decisions.

## Scope

The work focused on:

- designing the Kubernetes deployment model;
- creating a small K3s cluster;
- migrating the application workload from Docker Compose to Kubernetes manifests;
- configuring Traefik as the ingress controller;
- deploying PostgreSQL through CloudNativePG;
- configuring PostgreSQL replication and automatic failover;
- enforcing workload placement across worker nodes;
- configuring TLS for the test environment;
- performing infrastructure failure tests;
- testing application behaviour under network degradation.

The original application source code and container image remain client-owned and are not included in this repository.

## Architecture

```text
                         HTTPS
                           │
                           ▼
                    ┌─────────────┐
                    │   Traefik   │
                    │   Ingress   │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │ Application │
                    │   Service   │
                    └──────┬──────┘
                           │
                 ┌─────────▼─────────┐
                 │   Application     │
                 │      Pods         │
                 │    (replicated)   │
                 └─────────┬─────────┘
                           │
                    ┌──────▼──────┐
                    │ CNPG RW      │
                    │   Service    │
                    └──────┬──────┘
                           │
                 ┌─────────▼─────────┐
                 │     PostgreSQL    │
                 │ Primary ↔ Standby│
                 └───────────────────┘

        ┌──────────────────────────────────────┐
        │              k3s cluster             │
        │                                      │
        │  server-0       agent-0    agent-1  │
        │  control-plane    worker     worker  │
        └──────────────────────────────────────┘
```

## Why k3s

k3s was selected for the POC because it provides a lightweight Kubernetes distribution with the standard Kubernetes API and core orchestration capabilities, while keeping the infrastructure footprint and operational overhead small.

For the local POC environment, k3d also provides a convenient way to run the cluster locally with a local container registry.

### Cluster

- k3d / k3s
- 1 server (control-plane)
- 2 agents (workers)
- local Docker registry
- Traefik Ingress Controller
- application scheduled only on workers
- PostgreSQL scheduled only on workers

### PostgreSQL

PostgreSQL is managed by [CloudNativePG](https://cloudnative-pg.io/).

- 2 PostgreSQL instances
- required pod anti-affinity
- instances placed on different worker nodes
- application connects through the CNPG read/write service
- database credentials are generated during installation and stored in a Kubernetes Secret
- no database credentials are committed to the repository

The database is deployed using a raw CNPG manifest; Helm is not required for this POC.

## Requirements

- Docker / Docker Desktop
- k3d
- kubectl

The application image must already be available locally in Docker:

```text
app/branch/development:latest
```

## Installation

Create the local k3d environment and deploy the infrastructure:

```bash
./scripts/install.sh
```

The installation script:

1. creates a local k3d registry;
2. creates a K3s cluster with one server and two agents;
3. taints the control-plane node to keep application workloads on workers;
4. restricts K3s ServiceLB to the worker nodes;
5. creates the `app` namespace;
6. generates PostgreSQL credentials and stores them in a Kubernetes Secret;
7. installs CloudNativePG;
8. deploys the PostgreSQL cluster;
9. deploys the application workload;
10. deploys the Service and Traefik Ingress;
11. waits for the PostgreSQL cluster and application rollout.

## Verification

```bash
kubectl get nodes
kubectl get pods -A
kubectl get cluster -n app
kubectl get ingress -n app
```

Check the PostgreSQL primary:

```bash
kubectl get cluster app-db -n app \
  -o jsonpath='{.status.currentPrimary}{"\n"}'
```

## Failure testing

The POC includes a simple network impairment test which uses a temporary `netshoot` container to apply Linux `tc/netem` rules to a k3d worker network namespace.

Example:

```bash
./scripts/network-test.sh
```

The test applies approximately:

- 200 ms latency
- 50 ms jitter
- 10% packet loss

The script removes the impairment automatically when it exits.

### Worker failure

A worker failure was tested by stopping a k3d agent containing the PostgreSQL primary.

Observed behaviour:

```text
Primary instance unavailable
        ↓
CNPG detects unhealthy primary
        ↓
Replica is promoted
        ↓
Application remains available
```

CNPG reported an automatic failover from `app-db-1` to `app-db-2`.

### Control-plane failure

The single k3s server was stopped while the application was running.

Observed behaviour:

- application traffic continued;
- PostgreSQL continued serving requests;
- CoreDNS continued running on a worker;
- the CNPG controller temporarily lost access to the Kubernetes API;
- Kubernetes control-plane operations were unavailable while the server was down;
- after the server returned, the control plane and CNPG controller recovered.

This demonstrates an important distinction between **data-plane availability** and **control-plane availability**.

### Network degradation

The application was tested with approximately 200 ms latency and 10% packet loss.

Observed behaviour:

- application remained available;
- HTTP requests continued to return successfully;
- increased request latency was visible;
- no unnecessary PostgreSQL failover was triggered under this level of network degradation.

## Results and trade-offs

### What the POC demonstrates

- Application workloads can be distributed across workers.
- CNPG can automatically fail over PostgreSQL after loss of the primary instance.
- PostgreSQL instances can be separated across worker nodes using Kubernetes affinity rules.
- The application data plane can remain available during loss of the single k3s control-plane node.
- Moderate network degradation does not automatically cause a database failover.

## Production considerations

The POC is intentionally minimal. A production implementation would require additional decisions around:

- multiple k3s control-plane nodes / external datastore;
- storage replication and recovery guarantees;
- backup and restore strategy;
- monitoring and alerting;
- secret management;
- certificate lifecycle automation;
- resource requests/limits and disruption policies.

These are intentionally outside the scope of this POC.
