# mc-environment

`mc-environment` renders a single Argo CD `ApplicationSet` that produces one `Application` per environment defined in `values.yaml`. Each generated `Application` targets the `mycarrier-helm` chart and receives an environment-specific values bundle so overrides remain isolated.

## How it works

1. The chart pins Argo CD settings (namespace `argocd`, project `default`, destination `https://kubernetes.default.svc`, and the in-repo `mycarrier-helm` chart) so you only need to supply environment-specific application data.
2. At template time a `list` generator is built out of `environments`, and each element carries the pre-rendered values payload plus any Helm overrides.
3. For every entry in `environments` it builds a final values document by layering:
   - global defaults from `values.yaml` → `.Values.global`
   - optional per-environment overrides under `environments[].global`
   - optional extra values supplied alongside the environment (for example `applications`, `jobs`, `infrastructure`).
4. The merged values are serialized into the Argo CD `Application.spec.source.helm.values` field by the ApplicationSet template, so Argo CD deploys `mycarrier-helm` with those settings.

Go templating is supported where the chart still calls `tpl` (such as `environments[].helm.releaseNameTemplate`, helm value files, and parameters). Templates render with access to `.Values`, `.Release`, and `.Environment` so you can derive names from the current environment when needed before the ApplicationSet is emitted.

## Key values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global` | Base values passed to every `mycarrier-helm` deployment | See [values.yaml](./values.yaml) |
| `environments` | Array of environment definitions that each produce an Argo CD Application | `[]` |

## Example

See [example.yaml](./example.yaml) for a full sample covering dev and prod environments.

```yaml
global:
  appStack: carriers
  gitbranch: main

environments:
  - name: dev
    destinationNamespace: platform-dev
    global:
      gitbranch: dev
    applications:
      example-api:
        image:
          repository: ghcr.io/mycarrier/example-api
          tag: "1.0.0"
  - name: prod
    releaseName: carriers-prod
    global:
      gitbranch: prod
    environment:
      dependencyenv: prod
```

Apply the chart with your preferred Helm workflow and Argo CD will manage one `mycarrier-helm` release per configured environment.
