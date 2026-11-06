# k0s playground

Spins up a single-node [k0s](https://k0sproject.io/) Kubernetes cluster in
Docker and bootstraps it with a GitOps stack:

- [ArgoCD](https://argo-cd.readthedocs.io/) for continuous delivery;
- [Gogs](https://gogs.io/) as an in-cluster Git remote that ArgoCD syncs from;
- [Crossplane](https://www.crossplane.io) to manage non-K8s resources;
- [Radar](https://radarhq.io/) as K8s UI;
- [Kgateway](https://kgateway.dev/) as the Gateway API ingress, and;
- [Nexus](https://www.sonatype.com/products/nexus-community-edition-download) as
  artifact repository manager (OCI, etc.);

## Prerequisites

- Docker (with the `compose` plugin)
- `make`, `curl`, `jq`, `kislyuk/yq`, `kubectl kustomize`, `helm` (or run
  `nix develop`)
- [Optional] `step-cli` to trust `step-ca`'s root certificate on the host
  (install on the host or run `nix develop`)

> [!note]
>
> On WSL, install `step-cli` on the Windows host rather than inside the Linux
> VM. `make trust-ca` and `make destroy-k0s` prefer `step.exe` via [WSL
> interop](https://learn.microsoft.com/en-us/windows/dev-environment/wsl-interop#path-translation)
> (using [`wslpath`](https://learn.microsoft.com/en-us/windows/wsl/release-notes#wsl-34)
> for path translation) so the certificate is installed into the Windows trust
> store used by host browsers.

## Quick start

```bash
# Setup git hooks
git config core.hooksPath .githooks

./bootstrap-k0s.sh
```

`./bootstrap-k0s.sh --help` describes all modes. In the default (no-argument)
mode it:

1. Mirrors the k0s core images listed in `airgap-images.txt` into an airgap
   bundle (`image-bundle.tar`). Set `USE_SUDO=1` if docker requires sudo in your
   environment.
2. Starts the `k0s-controller` and `step-ca` containers via `docker compose`
   (see `compose.yaml`, `k0s.yaml`).
3. Configures containerd to trust in-cluster Nexus.
4. Applies the core apps directly: `rook-ceph-operator`, `ceph-csi-drivers`,
   `gateway-api-crds`, `ceph-cluster`, `ArgoCD` and `Gogs`.
   (in simpler deployment, can use `local-path-provisioner` instead of ceph)
5. Pushes this repository to the in-cluster Gogs instance and applies the ArgoCD
   app-of-apps (`gitops/applications`), which takes over deploying everything
   else (cert-manager, ...) - see
   [`gitops/applications/README.md`](gitops/applications/README.md).
6. [Optional] If `step-cli` is available, installs `step-ca`'s root certificate
   into the host trust store (`make trust-ca`).

Once it finishes, the stack is reachable at:

- ArgoCD: <https://argocd.k0s.localhost:30443> or <http://argocd.k0s.localhost:30080> (`admin:password`)
- Gogs: <https://gogs.k0s.localhost:30443> or <http://gogs.k0s.localhost:30080> (`gogs-admin:password`)
- Ceph: <https://ceph.k0s.localhost:30443> or <http://ceph.k0s.localhost:30080> (`admin:password`)
- Nexus: <https://nexus.k0s.localhost:30443> or <http://nexus.k0s.localhost:30080> (`admin:password`)
- Radar: <https://radar.k0s.localhost:30443> or <http://radar.k0s.localhost:30080>

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
    post_start:
      # Loop device for Ceph
      - command:
          - sh
          - -c
          - |
            apk add eudev
            pidof udevd || udevd --daemon
            until pidof udevd; do :; done
            [ -e /dev/loop99 ] || mknod /dev/loop99 b 7 99
            fallocate -l 6G /vol/disk.raw
            losetup -a | grep loop99 || losetup /dev/loop99 /vol/disk.raw
            udevadm trigger --action=add --subsystem-match=block
            udevadm settle
        privileged: true
    hostname: k0s-controller
    network_mode: bridge
    extra_hosts:
      - "nexus.k0s.localhost:127.0.0.1"
      - "nexus.k0s.host.docker.internal:127.0.0.1"
    ports:
      - 6443:6443   # Kubernetes API
      - 30080:30080 # HTTP ingress
      - 30018:30018 # Gogs
    volumes:
      - /var/lib/k0s
      - ./k0s/image-bundle.tar:/var/lib/k0s/images/image-bundle.tar
      - /var/log/pods
      - /dev/kmsg:/dev/kmsg:ro
      - ./k0s/k0s.yaml:/etc/k0s/k0s.yaml
      - /vol
    tmpfs:
      - /run
    devices:
      - /dev/kmsg
    privileged: true
    security_opt:
      - seccomp:unconfined

  step-ca:
    container_name: step-ca
    image: smallstep/step-ca:0.29.0
    command:
      - /usr/local/bin/step-ca
      - --acme-http-port=30080
      - --insecure
      - --password-file=/home/step/secrets/password
      - /home/step/config/ca.json
    network_mode: bridge
    ports:
      - 9000:9000
    environment:
      DOCKER_STEPCA_INIT_NAME: "k0s Local CA"
      DOCKER_STEPCA_INIT_DNS_NAMES: "localhost,host.docker.internal,step-ca"
      DOCKER_STEPCA_INIT_ACME: "true"
    extra_hosts:
      - "argocd.k0s.localhost:host-gateway"
      - "ceph.k0s.localhost:host-gateway"
      - "crossview.k0s.localhost:host-gateway"
      - "gogs.k0s.localhost:host-gateway"
      - "nexus.k0s.localhost:host-gateway"
      - "radar.k0s.localhost:host-gateway"

      - "argocd.k0s.host.docker.internal:host-gateway"
      - "ceph.k0s.host.docker.internal:host-gateway"
      - "crossview.k0s.host.docker.internal:host-gateway"
      - "gogs.k0s.host.docker.internal:host-gateway"
      - "nexus.k0s.host.docker.internal:host-gateway"
      - "radar.k0s.host.docker.internal:host-gateway"
    volumes:
      - /home/step

  k0s-controller-bootstrap:
    # Any image with bash, git, make, kubectl and docker CLI
    image: nixery.dev/[arm64/]shell/gnumake/docker-client/kubectl
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
- `step-ca` runs on port 9000 in bridge network mode, providing the local ACME
  directory for cert-manager to automatically issue TLS certificates.
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
compose.yaml       Docker Compose definition for k0s-controller and step-ca
flake.nix          Nix flake devShell
k0s.yaml           k0s ClusterConfig mounted into the controller
airgap-images.txt  k0s core images mirrored before cluster start
Makefile           Helper targets used by bootstrap-k0s.sh and for day-to-day use
gitops/            Everything ArgoCD manages once the cluster is up
  applications/    App-of-apps Helm chart - see gitops/applications/README.md
  core/
    in-repo/       Kustomize/Helm apps sourced straight from this repo
    external-helm/ Config-driven external Helm chart deployments (e.g. cert-manager)
```

> [!note]
>
> Workload images that are not declared via standard `.image` scalar fields
> (e.g. dynamic sidecars configured via CLI args or custom CRDs like
> CloudNative-PG's `imageName` or Kgateway's `envoyContainer`) are extracted
> dynamically using local `*airgap-images.jq` query files within the component's
> folder (for example: `gitops/core/in-repo/nexus/airgap-images.jq`).
> `./list-images.sh` applies these filters to the rendered manifests.

## Common tasks

- `make` targets: run `make help` for the full list (kubeconfig generation,
  waiting on ArgoCD apps, tearing the cluster down, etc.).
- Destroy the cluster: `make destroy-k0s` (runs `docker compose down --volumes`).
- Re-run the bootstrap after a teardown: `./bootstrap-k0s.sh`.

## Troubleshooting

### CephFS FUSE mounts and recovery

OrbStack lacks the in-tree `ceph.ko` kernel module, requiring CephFS to run
through user-space `ceph-fuse` daemons (one daemon per PVC). When a `ceph-fuse`
daemon exits unexpectedly, the mount point enters an unresponsive `ENOTCONN`
state in the Linux kernel VFS.

#### Failure symptoms

- **Transport endpoint is not connected (`ENOTCONN`)** - `containerd` fails
  during container creation with `CreateContainerError` when attempting `stat()`
  on `/var/lib/k0s/kubelet/pods/<pod-uid>/volumes/.../mount`.
- **Pod stuck in `Terminating`** - Kubelet volume detachment controller hangs
  indefinitely trying to unmount a severed FUSE mount during standard pod
  deletion.
- **Kubelet staging conflict (`file exists`)** - Kubelet `attacher.MountDevice`
  fails with `file exists` on `/globalmount` during volume restaging, aborting
  before Ceph-CSI is invoked over gRPC.

#### Why pods enter a restart deadlock

When a container crashes or is killed inside an existing pod, Kubelet only
invokes CRI (`containerd`) to restart the container process. Because Kubelet's
Volume Manager already considers the volume mounted for that pod UID, Kubelet
never reinvokes CSI volume publishing (`NodePublishVolume`).

Ceph-CSI contains FUSE recovery routines, but they only execute during volume
publishing. Because that call is bypassed, the CSI driver never attempts to
recover the severed mount. `containerd` attempts to `stat()` the dead mount
path, receives `ENOTCONN`, and loops indefinitely in `CreateContainerError`.

#### Recovery procedure

1. Force-delete affected workload pods to release Kubelet volume locks:

   Standard deletion hangs because Kubelet attempts a graceful unmount against
   the severed FUSE mount, which blocks indefinitely in the kernel.
   Force-deleting the pod bypasses the graceful unmount check, terminates the
   pod API object, and releases Kubelet's volume lock for that pod UID.

   ```bash
   kubectl -n <namespace> delete pod <pod-name> --force --grace-period=0
   ```


2. Handle severed FUSE mounts inside `k0s-controller`:

   **Stale mount:** When `ceph-fuse` terminates, the Linux kernel VFS retains
   the broken mount entry, returning `ENOTCONN` or `EEXIST` on subsequent
   access. During volume staging (`NodeStageVolume`), Kubelet's internal
   `attacher.MountDevice` runs `os.MkdirAll` on `.../globalmount` before
   invoking Ceph-CSI; because the stale mount is still attached,
   `os.MkdirAll` fails with `file exists` and aborts staging. Executing
   `umount -l` detaches severed endpoints from the kernel VFS tree immediately.

   ```bash
    docker exec k0s-controller sh -c "
        grep fuse /proc/mounts |
            awk '{print \$2}' |
            xargs -I{} sh -c \"timeout 1 ls {} >/dev/null 2>&1 || umount -l {}\"
    "
   ```

   **Frozen mount:** Dead client disconnected without releasing Ceph capability
   locks. Calls (from newly restarted pod) hang indefinitely in `D` state
   (uninterruptible sleep), Ceph reports `MDS_CLIENT_LATE_RELEASE` and
   `MDS_SLOW_REQUEST`. Check and evict stale MDS sessions:

   ```bash
   # 1. Check if MDS is waiting on dead client capabilities:
   kubectl -n ceph-cluster exec deploy/rook-ceph-tools -- ceph health detail

   # 2. If MDS_CLIENT_LATE_RELEASE is present, evict the stale client ID:
   kubectl -n ceph-cluster exec deploy/rook-ceph-tools -- ceph tell mds.loop-a client evict id=<client_id>
   ```

3. Restart the CephFS CSI nodeplugin if Kubelet reports CSI socket disconnection:

   Deleting the DaemonSet pod re-establishes the gRPC registration socket with
   Kubelet and allows Ceph-CSI to spawn fresh `ceph-fuse` instances for
   subsequent mounts.

   ```bash
   kubectl -n rook-ceph delete pod -l app=rook-ceph.cephfs.csi.ceph.com-nodeplugin --force --grace-period=0
   ```

