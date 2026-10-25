#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
if [ "${TRACE-0}" = "1" ]; then
    set -o xtrace
fi

case "${1-}" in
    -h|--help|-help|help)
        echo "Usage: ./$(basename "$0") [bundle-images | config-cluster-only]"
        echo '
Bootstraps a local k0s Kubernetes cluster with ArgoCD and Gogs.

  (no argument)        Pull and bundle airgap images, start the k0s controller
                       via docker compose, then configure the cluster.
  bundle-images        Pull and bundle airgap images only — no cluster setup.
                       Used as a pre-step when compose is managed externally.
  config-cluster-only  Skip docker compose up and image bundling; configure an
                       already-running k0s controller. Used when the controller
                       is started by an external compose stack.

Environment variables:
  HARBOR_USER / HARBOR_PASSWORD   Harbor registry credentials (see .env.example).
  USE_SUDO                        Set to any non-empty value to prefix docker commands with sudo.
  K0S_HOST                        Host where k0s ports are exposed (default: localhost).
                                  Used by Makefile targets, not by this script directly.'
        exit
        ;;
esac

cd "$(dirname "$0")"
# shellcheck disable=SC1091
. ./.env

main() {
    case "${1-}" in
        bundle-images)
            bundle_images
            exit 0
            ;;
        config-cluster-only) : ;;
        *)
            bundle_images
            dockerz compose up --detach
            ;;
    esac

    print_headline "Waiting for k0s..."
    until kubectlz cluster-info > /dev/null 2>&1; do :; done
    kubectlz cluster-info

    # TODO: Self-host Harbor
    # add_harbor_auth

    # Wait for loop device
    dockerz exec k0s-controller sh -c '
        until losetup -a | grep loop99; do :; done
    '

    # Deploy core apps
    deploy_cilium

    local core_apps=("rook-ceph-operator" "ceph-csi-drivers")
    local app; for app in "${core_apps[@]}"; do
        local namespace
        namespace="$(
            # shellcheck disable=SC2016
            yq --raw-output --arg name "$app" \
                '.apps[] | select(.name == $name) | .namespace // .name' \
                gitops/core/external-helm/config.yaml
        )"

        kubectl create namespace "$namespace" --dry-run=client --output=yaml |
            kubectlz_apply
        make --no-print-directory APP="$app" helm-template |
            kubectlz_apply --namespace "$namespace"
    done

    core_apps=("gateway-api-crds" "ceph-cluster" "ArgoCD" "Gogs")
    local app; for app in "${core_apps[@]}"; do
        print_headline "Deploy $app"
        local app_path=${app,,}
        kubectl kustomize --enable-helm gitops/core/in-repo/"$app_path"/ |
            kubectlz_apply
    done

    make set-ceph-dashboard-password
    kubectlz --namespace rook-ceph rollout restart deploy rook-ceph.cephfs.csi.ceph.com-ctrlplugin
    make set-up-gogs-repo
    make commit-to-gogs
    cat gitops/applications/app.yaml | kubectlz_apply

    until make APP=cert-manager wait-argocd-app; do :; done
    until make APP=kgateway wait-argocd-app; do :; done

    setup_nexus

    if command -v step > /dev/null 2>&1 || command -v step.exe > /dev/null 2>&1; then
        make trust-ca
    fi
    print_headline "Done!"
    # shellcheck disable=SC2016
    echo 'You can access ArgoCD, Gogs, Ceph and Radar at:
- ArgoCD: https://argocd.k0s.localhost:30443 or http://argocd.k0s.localhost:30080 (admin:password)
- Gogs: https://gogs.k0s.localhost:30443 or http://gogs.k0s.localhost:30080 (gogs-admin:password)
- Ceph: https://ceph.k0s.localhost:30443 or http://ceph.k0s.localhost:30080 (admin:password)
- Nexus: https://nexus.k0s.localhost:30443 or http://nexus.k0s.localhost:30080 (admin:password)
- Radar: https://radar.k0s.localhost:30443 or http://radar.k0s.localhost:30080

To access the cluster with kubectl, `source activate.sh`'
}

print_headline() {
    local highlight_style='\033[1;36m'
    local color_off='\033[0m'
    printf "\n${highlight_style}%s${color_off}\n" "${1}"
}

dockerz() {
    ${USE_SUDO:+sudo} docker "$@"
}

kubectlz() {
    dockerz exec --interactive k0s-controller k0s kubectl "$@"
}

kubectlz_apply() {
    local manifest
    manifest=$(mktemp)
    tee "$manifest" > /dev/null
    if cat "$manifest" | kubectlz apply --server-side --force-conflicts --filename - "$@"; then
        rm "$manifest"
        return
    fi
    local i; for i in {1..5}; do
        echo "Wait ${i}s..."
        sleep "$i"
        if cat "$manifest" | kubectlz apply --server-side --force-conflicts --filename - "$@"; then
            rm "$manifest"
            return
        fi
    done
    rm "$manifest"
    false
}

bundle_images() {
    print_headline "Pull k0s core images"
    # local prefix="harbor.example.com/"
    local upstream_images=()

    while IFS= read -r image; do
        [ -z "$image" ] && continue
        until dockerz pull "$image"; do :; done
        # TODO: Self-host Harbor
        # local upstream="${image#"$prefix"}"
        # dockerz tag "$image" "$upstream"
        # upstream_images+=("$upstream")
        upstream_images+=("$image")
    done <airgap-images.txt

    dockerz image save --output image-bundle.tar "${upstream_images[@]}"
}

add_harbor_auth() {
    dockerz exec k0s-controller mkdir -p /etc/k0s/containerd.d/certs.d/harbor.example.com
    echo 'version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
config_path = "/etc/k0s/containerd.d/certs.d"
' | dockerz exec --interactive k0s-controller tee /etc/k0s/containerd.d/cri-registry.toml > /dev/null

    cat <<EOF | dockerz exec --interactive k0s-controller tee /etc/k0s/containerd.d/certs.d/harbor.example.com/hosts.toml > /dev/null
server = "https://harbor.example.com"

[host."https://harbor.example.com"]
capabilities = ["pull", "resolve"]
skip_verify = true

[host."https://harbor.example.com".header]
authorization = "Basic $(printf '%s:%s' "$HARBOR_USER" "$HARBOR_PASSWORD" | base64)
EOF
}

deploy_cilium() {
    # Download Cilium CLI
    if ! [ -f cilium ]; then
        local version
        version=$(curl --silent https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
        local arch=amd64
        if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then arch=arm64; fi
        local os=linux
        if [ "$(uname -s)" = "Darwin" ]; then os=darwin; fi

        curl --location --fail --output cilium.tar.gz \
            "https://github.com/cilium/cilium-cli/releases/download/${version}/cilium-${os}-${arch}.tar.gz"
        tar xzvf cilium.tar.gz
        rm cilium.tar.gz
    fi

    # Deploy Cilium
    make --no-print-directory APP=cilium helm-template |
        yq --raw-output 'select(.metadata.namespace != "cilium-secrets")' |
        kubectlz_apply --namespace kube-system
    make --no-print-directory APP=cilium helm-template |
        yq --raw-output 'select(.metadata.namespace == "cilium-secrets")' |
        kubectlz_apply --namespace cilium-secrets
    make --no-print-directory gen-kubeconfig > kubeconfig.tmp
    ./cilium --kubeconfig kubeconfig.tmp status --wait
}

setup_nexus() {
    print_headline "Waiting for Nexus to be ready..."
    local status; until
        status="$(
            curl --silent --output /dev/null --write-out "%{http_code}" \
                http://nexus.k0s.localhost:30080/service/rest/v1/status/writable ||
                true
        )" &&
        [ "$status" = "200" ]
    do :; done

    print_headline "Accept Nexus EULA"
    local eula_payload
    eula_payload=$(
        curl --silent --insecure \
            --user "admin:password" \
            http://nexus.k0s.localhost:30080/service/rest/v1/system/eula 2>/dev/null |
            sed 's/"accepted" : false/"accepted" : true/' ||
            true
    )
    if [ -n "$eula_payload" ]; then
        curl --silent --insecure \
            --user "admin:password" \
            --request POST http://nexus.k0s.localhost:30080/service/rest/v1/system/eula \
            --header "Content-Type: application/json" \
            --data "$eula_payload" > /dev/null 2>&1 ||
            true
    fi
}

main "$@"

