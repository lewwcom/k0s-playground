# k0s playground

Spins up a single-node [k0s](https://k0sproject.io/) Kubernetes cluster in
Docker and bootstraps it with a GitOps stack:

- [ArgoCD](https://argo-cd.readthedocs.io/) for continuous delivery;
- [Gogs](https://gogs.io/) as an in-cluster Git remote that ArgoCD syncs from;
- [Radar](https://radarhq.io/) as K8s UI, and;
- [Kong](https://konghq.com/) as the Gateway API ingress.

All container images can be mirrored through the self-hosted Harbor registry
rather than pulled from public registries.

## Prerequisites

- Docker (with the `compose` plugin)
- `make`, `curl`, `jq`, `kislyuk/yq`, `kubectl kustomize`
- [Optional, if use Harbor] A `.env` file with Harbor credentials (copy
  `.env.example` and fill in `HARBOR_USER` / `HARBOR_PASSWORD`)

## Quick start

```bash
cp .env.example .env   # [Optional] fill in HARBOR_USER / HARBOR_PASSWORD
./bootstrap-k0s.sh
```

`./bootstrap-k0s.sh --help` describes all modes. In the default (no-argument)
mode it:

1. Mirrors the k0s core images listed in `airgap-images.txt` into an airgap
   bundle (`image-bundle.tar`). Set `USE_SUDO=1` if docker requires sudo in your
   environment.
2. Starts the `k0s-controller` container via `docker compose` (see
   `compose.yaml`, `k0s.yaml`).
3. [Optional] Configures containerd to authenticate against Harbor.
4. Applies the core kustomize apps directly: `gateway-api-crds`,
   `local-path-provisioner`, `ArgoCD`, `Gogs`.
5. Pushes this repository to the in-cluster Gogs instance and applies the ArgoCD
   app-of-apps (`gitops/applications`), which takes over deploying everything
   else (Kong, cert-manager, ...) - see
   [`gitops/applications/README.md`](gitops/applications/README.md).

Once it finishes, the stack is reachable at:

- ArgoCD: <http://argocd.k0s.localhost:30080> (`admin:password`)
- Gogs: <http://gogs.k0s.localhost:30080> (`gogs-admin:password`)
- Radar: <http://radar.k0s.localhost:30080>

## External compose integration

This repo can be embedded as a git submodule in a larger compose project (e.g. a
devcontainer), with the k0s-controller managed by the parent stack.

### Step 1 — add as a submodule

```bash
git submodule add <k0s-repo-url> .devcontainer/k0s
```

### Step 2 — pre-bundle images

Run on the host before `docker compose up`, e.g. in a VS Code devcontainer
`initializeCommand`:

```bash
.devcontainer/k0s/bootstrap-k0s.sh bundle-images
```

### Step 3 — add services to your `compose.yml`

```yaml
services:
  devcontainer:
    build: .
    extra_hosts:
      - "argocd.k0s.host.docker.internal:host-gateway"
      - "gogs.k0s.host.docker.internal:host-gateway"

  k0s-controller:
    container_name: k0s-controller
    image: k0sproject/k0s:v1.31.14-k0s.0
    command: ["k0s", "controller", "--enable-worker", "--no-taints"]
    hostname: k0s-controller
    network_mode: bridge
    ports:
      - 6443:6443   # Kubernetes API
      - 30080:30080 # Kong
      - 30018:30018 # Gogs
    volumes:
      - /var/lib/k0s
      - ./k0s/image-bundle.tar:/var/lib/k0s/images/image-bundle.tar
      - /var/log/pods
      - /dev/kmsg:/dev/kmsg:ro
      - ./k0s/k0s.yaml:/etc/k0s/k0s.yaml
    tmpfs:
      - /run
    devices:
      - /dev/kmsg
    privileged: true
    security_opt:
      - seccomp:unconfined

  k0s-controller-bootstrap:
    # Any image with bash, git, make, kubectl and docker CLI
    image: nixery.dev/[arm64/]shell/gnumake/docker-client/kubectl
    env_file: .env # [optional] contains HARBOR_USER and HARBOR_PASSWORD
    environment:
      K0S_HOST: host.docker.internal  # k0s ports are on the Docker host
      USE_SUDO: "true"                # bootstrap container can sudo but not access docker directly

      # Unlike the main devcontainer, VS Code does not inject committer info
      # into this service, so git commit will fail without these
      GIT_AUTHOR_NAME: gogs-admin
      GIT_COMMITTER_NAME: gogs-admin
      EMAIL: gogs-admin@local

      # Git may fail with "detected dubious ownership" due to owner mismatch
      GIT_CONFIG_COUNT: 1
      GIT_CONFIG_KEY_0: safe.directory
      GIT_CONFIG_VALUE_0: "*"
    command:
      - /workspace/.devcontainer/k0s/bootstrap-k0s.sh
      - config-cluster-only
    volumes:
      # k0s content is pushed to Gogs; as a submodule, its .git lives in the
      # root project
      - ..:/workspace
      - /var/run/docker.sock:/var/run/docker.sock
    restart: "no"
```

Key points:

- `k0s-controller` uses `network_mode: bridge`; its ports are exposed on the
  Docker host and reachable from other containers via `host.docker.internal`.
- `k0s-controller-bootstrap` passes `config-cluster-only` because `docker
  compose up` is handled by the parent stack — the script only configures the
  already-running cluster.
- `USE_SUDO=true` is for environments where the bootstrap container's user can
  run `sudo` but cannot access the Docker socket directly.
- `K0S_HOST=host.docker.internal` tells `Makefile` targets (used internally by
  the bootstrap) to reach Gogs and the Kubernetes API via the Docker host
  gateway.

## Repository layout

```plaintext
bootstrap-k0s.sh   Bootstraps the cluster end-to-end (see --help)
compose.yaml       Docker Compose definition for the k0s-controller container
k0s.yaml           k0s ClusterConfig mounted into the controller
airgap-images.txt  k0s core images mirrored (from Harbor, probably) before cluster start
Makefile           Helper targets used by bootstrap-k0s.sh and for day-to-day use
gitops/            Everything ArgoCD manages once the cluster is up
  applications/    App-of-apps Helm chart - see gitops/applications/README.md
  core/
    in-repo/       Kustomize/Helm apps sourced straight from this repo
    external-helm/ Config-driven external Helm chart deployments (e.g. cert-manager)
```

## Common tasks

- `make` targets: run `make help` for the full list (kubeconfig generation,
  waiting on ArgoCD apps, tearing the cluster down, etc.).
- Destroy the cluster: `make destroy-k0s` (runs `docker compose down --volumes`).
- Re-run the bootstrap after a teardown: `./bootstrap-k0s.sh`.

