# Applications

An ArgoCD "app-of-apps" Helm chart. It doesn't deploy workloads itself ΓÇö it
generates the ArgoCD `AppProject` and `ApplicationSet` resources that discover
and deploy the apps under each project's own `<gitopsPath>` tree, read from that
project's own `repoURL`.

`app.yaml` is a sample ArgoCD `Application` manifest showing how this chart is
meant to be deployed (pointed at a Git repo containing a tree laid out as
described below).

## Values

`projects` is a list of objects, each describing one project/`AppProject`:

| Key          | Description                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| `name`       | Project name. Used as the `AppProject` name.                                                            |
| `repoURL`    | Git repository this project's `ApplicationSet`s read from (both app definitions and Helm values files). |
| `gitopsPath` | Path within `repoURL` to this project's directory (the one containing `in-repo/` and `external-helm/`). |

See `values.yaml` for the current projects/defaults.

## What it generates (`templates/appset.yaml`)

For each project in `.Values.projects`:

- **`AppProject "<project>"`** ΓÇö an ArgoCD project allowing any source repo
  and any destination namespace/cluster.
- **`ApplicationSet "<project>-in-repo"`** ΓÇö scans `<gitopsPath>/in-repo/*` in
  `repoURL` and creates one ArgoCD `Application` per subdirectory:

  - A plain directory is deployed via **kustomize**.
  - A directory containing a `Chart.yaml` is deployed via **Helm** instead.
  - Namespace and release/app name are both derived from the directory name.

- **`ApplicationSet "<project>-external-helm"`** ΓÇö reads
  `<gitopsPath>/external-helm/config.yaml` and creates one ArgoCD `Application`
  per entry in its `apps` list, deploying an external Helm chart with a values
  file also stored in `repoURL`. Each entry looks like:

  ```yaml
  apps:
    - name: cert-manager
      repo: quay.io/jetstack/charts    # Helm repo (or OCI registry)
      chart: cert-manager
      revision: v1.20.2
      values: cert-manager.values.yaml # relative to <gitopsPath>/external-helm/
  ```

Every generated `Application` syncs automatically with pruning enabled
(`CreateNamespace=true`, `ServerSideApply=true`).

## Adding a project

Add a new `{name, repoURL, gitopsPath}` entry to `values.yaml` under `projects`,
then create the matching `<gitopsPath>/in-repo/` and/or
`<gitopsPath>/external-helm/config.yaml` layout in that project's `repoURL`.

## Adding an app

- **In-repo kustomize app**: add a new directory under
  `<gitopsPath>/in-repo/<name>/` with a `kustomization.yaml`. It's picked up
  automatically on the next ArgoCD sync.
- **In-repo Helm app**: same, but the directory needs a `Chart.yaml`.
- **External Helm app**: add an entry to
  `<gitopsPath>/external-helm/config.yaml` and a corresponding values file.

