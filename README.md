# resource-state-metrics

A Crossplane Configuration that deploys [resource-state-metrics](https://github.com/kubernetes-sigs/resource-state-metrics), a Kubernetes controller that generates Prometheus metrics for custom resources based on `ResourceMetricsMonitor` configurations.

## Background

This project follows the approach outlined in the [Crossplane Metrics Proposal (crossplane/crossplane#6865)](https://github.com/crossplane/crossplane/pull/6865) and the decision to converge on [resource-state-metrics (RSM)](https://github.com/kubernetes-sigs/resource-state-metrics) as the primary, shared solution for custom resource metrics in the Kubernetes ecosystem.

Rather than building and maintaining a parallel implementation (crossplane-state-metrics), the Crossplane community is aligning with the upstream Kubernetes SIG Instrumentation effort. See the [full comment](https://github.com/crossplane/crossplane/pull/6865#issuecomment-3767353784) for details.

**What this means:**
- **RSM as the long-term path** - resource-state-metrics is a community-owned, SIG Instrumentation project that serves the entire Kubernetes ecosystem, not just Crossplane
- **Bridge, not a fork** - This Configuration package provides Crossplane-specific deployment, RBAC, documentation and examples while converging upstream as RSM stabilises
- **CEL as the default resolver** - Covers the majority of Crossplane use-cases (condition checks, label extraction, timestamp conversion). Starlark is available for complex iteration scenarios

## Install

### 1. Install the RSM Configuration

```bash
kubectl apply -f examples/configuration-rsm.yaml
```

This installs the Crossplane Configuration package that provides the `ResourceStateMetrics` XRD and Composition.

### 2. Create the RSM XR

```bash
kubectl apply -f examples/xr-rsm.yaml
```

This creates a `ResourceStateMetrics` XR that provisions:
- Namespace (`resource-state-metrics`)
- ServiceAccount, ClusterRole, ClusterRoleBinding
- Deployment (resource-state-metrics controller)
- Service (metrics endpoint on port 9999)
- ResourceMetricsMonitor CRD

### RBAC: allowedAPIGroups

The controller needs read access (get/list/watch) to the API groups you want to monitor. Configure this in `examples/xr-rsm.yaml`:

```yaml
spec:
  parameters:
    rbac:
      # Production: least-privilege - only the API groups you need
      allowedAPIGroups:
        - apiextensions.crossplane.io
        - metrics.crossplane.io
        - pkg.crossplane.io           # Provider, Configuration, Function
        - aws.platform.upbound.io     # EKS XRs

      # Development: wildcard access to all API groups
      # allowedAPIGroups: []
```

If you add new API groups to monitor (e.g., a new XRD), update `allowedAPIGroups` and re-apply:

```bash
kubectl apply -f examples/xr-rsm.yaml
```

## Deploy Sample XRs

The examples use a Crossplane EKS composite resource as the monitoring target.

```bash
# Install the EKS Configuration (provides the XRD and Composition)
kubectl apply -f examples/configuration-eks.yaml

# Create team namespaces
kubectl create namespace team-a
kubectl create namespace team-b

# Deploy sample EKS XRs with team labels
kubectl apply -f examples/metrics/eks/xrs.yaml
```

This creates three EKS XRs:

| XR | Namespace | Team | Region | Nodes |
|----|-----------|------|--------|-------|
| production-eks | team-a | team-a | us-west-2 | 3x m5.xlarge |
| staging-eks | team-a | team-a | eu-west-1 | 2x t3.medium |
| dev-eks | team-b | team-b | us-east-1 | 1x t3.small |

## Apply Metric Configurations

```bash
# Apply all metrics (recursive)
kubectl apply -R -f examples/metrics/

# Apply specific resource type
kubectl apply -f examples/metrics/eks/
kubectl apply -f examples/metrics/provider/

# Apply a single metric
kubectl apply -f examples/metrics/eks/ready-status.yaml
```

### Verify

```bash
# Check ResourceMetricsMonitor status
kubectl get resourcemetricsmonitor -A

# Look for Processed: True and cardinality info
kubectl describe resourcemetricsmonitor xr-ready-status -n resource-state-metrics

# Access metrics
kubectl port-forward -n resource-state-metrics svc/resource-state-metrics 9999:9999
curl -s http://localhost:9999/metrics | grep kube_customresource_
```

All metric family names are auto-prefixed with `kube_customresource_` (e.g., `eks_ready` becomes `kube_customresource_eks_ready`). Every metric automatically includes `group`, `version`, `kind`, `name`, and `namespace` labels.

## Resolver Types

### CEL (Common Expression Language) - Recommended

Best for conditional logic, null-safety, and checking Kubernetes conditions.

```yaml
resolver: cel
value: "o.status.conditions.exists(c, c.type == 'Ready' && c.status == 'True') ? 1 : 0"
```

Custom CEL functions provided by RSM:

| Function | Example | Description |
|----------|---------|-------------|
| `unixSeconds(string)` | `unixSeconds(o.status.conditions.filter(c, c.type == 'Ready')[0].lastTransitionTime)` | RFC3339 timestamp to Unix epoch seconds |
| `quantity(string)` | `quantity("100m")` → `0.1`, `quantity("1Gi")` → `1073741824.0` | Kubernetes quantity to float |
| `labelPrefix(map, string)` | `labelPrefix(o.metadata.labels, "label_")` | Prefix all keys in a label map |

### Starlark (Python-like scripting)

Best for complex iterations, multiple metrics from one resource, quantity conversion.

```python
for condition in obj.get("status", {}).get("conditions", []):
    samples.append(metric(
        labels={"type": condition.get("type")},
        value=1.0 if condition.get("status") == "True" else 0.0
    ))
```

Starlark builtins: `obj` (resource dict), `metric(labels, value)`, `family(name, help, kind, samples)`, `quantity_to_float(string)`.

### Resolver Hierarchy

Resolvers can be set at three levels (most specific wins):
1. **Metric level** - overrides family and store (see `conditions-cel-map.yaml`)
2. **Family level** - overrides store (see `all-conditions-starlark.yaml`)
3. **Store level** - default for all families/metrics in the store

## Multi-Tenancy

RSM watches `ResourceMetricsMonitor` resources across **all namespaces**. Teams can own their metric definitions in their own namespace:

```yaml
# team-a namespace: only monitors team-a's EKS clusters
apiVersion: resource-state-metrics.instrumentation.k8s-sigs.io/v1alpha1
kind: ResourceMetricsMonitor
metadata:
  name: eks-ready-status
  namespace: team-a        # RMM lives in team namespace
spec:
  configuration:
    stores:
      - group: "aws.platform.upbound.io"
        version: "v1alpha1"
        kind: "EKS"
        resource: "eks"
        resolver: "cel"
        selectors:
          label: "team=team-a"   # Only watches team-a resources
        families:
          - name: "eks_team_ready"
            help: "Ready status of EKS XRs per team"
            metrics:
              - value: "o.status.conditions.exists(c, c.type == 'Ready' && c.status == 'True') ? 1 : 0"
```

See `examples/metrics/eks/ready-status-per-team.yaml` for the full example.

## Metric Naming

> **Important: Use unique family names across all ResourceMetricsMonitors.**
> If multiple RMMs define the same family name (e.g., `eks_ready`) with different label sets, Prometheus will receive conflicting metric definitions. This leads to duplicate time series and unpredictable scrape results. Always use distinct family names — for example, use `eks_team_ready` for per-team monitors and `eks_ready` for the cluster-wide monitor.

- Names ending with `_total` are automatically treated as **counters** (monotonically increasing, generates `_created` timestamp)
- All other names are **gauges** (values that go up and down)
- Avoid `_total` suffix for non-monotonic values like ready status or resource counts

## Cardinality Management

Every unique combination of metric name + label values creates a time series. Protect Prometheus with cardinality limits:

```yaml
stores:
  - group: "aws.platform.upbound.io"
    cardinalityLimit: 1000      # Store-level: max across all families
    families:
      - name: "eks_ready"
        cardinalityLimit: 500   # Family-level: max for this family
```

- 80% of limit → `CardinalityWarning` condition
- 100% of limit → `CardinalityCutoff` condition (family dropped entirely)

See `examples/metrics/eks/cardinality-limits.yaml`.

## Troubleshooting

```bash
# Check RMM status
kubectl describe resourcemetricsmonitor <name> -n <namespace>

# Verify Processed: True condition
kubectl get resourcemetricsmonitor -A

# Check controller logs
kubectl logs -n resource-state-metrics -l app.kubernetes.io/name=resource-state-metrics

# Verify API group access
kubectl api-resources | grep <your-resource>
```

Common issues:
- **RBAC errors**: Add the API group to `allowedAPIGroups` in `xr-rsm.yaml` and re-apply
- **Cardinality 0**: Resources exist but have no status conditions yet
- **Metric not appearing**: Check that `group`, `version`, `kind`, `resource` match `kubectl api-resources`

## Links

- [Crossplane Metrics Proposal](https://github.com/crossplane/crossplane/pull/6865) - Original proposal and decision to converge on RSM
- [RSM Alignment Decision](https://github.com/crossplane/crossplane/pull/6865#issuecomment-3767353784) - Community comment on the RSM path
- [resource-state-metrics (upstream)](https://github.com/kubernetes-sigs/resource-state-metrics) - Kubernetes SIG Instrumentation project
- [CEL Language Specification](https://github.com/google/cel-spec)
- [Starlark Language](https://github.com/google/starlark-go)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/instrumentation/)
