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
  USE_SUDO                        Set to any non-empty value to prefix docker commands with sudo.
  K0S_HOST                        Host where k0s ports are exposed (default: localhost).
                                  Used by Makefile targets, not by this script directly.'
        exit
        ;;
esac

cd "$(dirname "$0")"

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

    # Configure containerd for Nexus with Step-CA
    setup_nexus_containerd

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

    until make APP=authentik wait-argocd-app; do :; done
    print_headline "Apply OpenTofu configuration for Authentik"
    tofu -chdir=gitops/core/external-helm/authentik/opentofu init
    tofu -chdir=gitops/core/external-helm/authentik/opentofu apply -auto-approve

    if command -v step > /dev/null 2>&1 || command -v step.exe > /dev/null 2>&1; then
        make trust-ca
    fi
    print_headline "Done!"
    # shellcheck disable=SC2016
    echo 'You can access the stack at:
- ArgoCD: https://argocd.k0s.localhost:30443 or http://argocd.k0s.localhost:30080 (admin:password)
- Gogs: https://gogs.k0s.localhost:30443 or http://gogs.k0s.localhost:30080 (gogs-admin:password)
- Ceph: https://ceph.k0s.localhost:30443 or http://ceph.k0s.localhost:30080 (admin:password)
- Authentik: https://authentik.k0s.localhost:30443 or http://authentik.k0s.localhost:30080 (akadmin:password)
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
    print_headline "Pull k0s core and application images"
    local prefix="nexus.k0s.localhost:30443/"

    local cache_dir="${ORAS_CACHE:-$HOME/.cache/oras}/layout"
    local arch=amd64
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then arch=arm64; fi
    local bundled_images=()

    if command -v oras > /dev/null 2>&1; then
        mkdir -p "$cache_dir"
        pull_and_tag() {
            until oras cp --platform "linux/$arch" --to-oci-layout-path "$cache_dir" "$1" "$2"; do :; done
        }
        export_bundle() {
            tar -cf image-bundle.tar -C "$cache_dir" .
        }
    else
        pull_and_tag() {
            until dockerz pull "$1"; do :; done
            dockerz tag "$1" "$2"
            bundled_images+=("$2")
        }
        export_bundle() {
            dockerz image save --output image-bundle.tar "${bundled_images[@]}"
        }
    fi

    while IFS= read -r image; do
        [ -z "$image" ] && continue
        local src_img="$image"
        local dest_tag="$image"

        if [[ "$image" == "$prefix"* ]]; then
            src_img="${image#"$prefix"}"
            dest_tag="${image%@*}"
        fi

        pull_and_tag "$src_img" "$dest_tag"
    done <airgap-images.txt

    export_bundle
}

setup_nexus_containerd() {
    print_headline "Configure containerd for Nexus with Step-CA"
    dockerz exec k0s-controller mkdir -p /etc/k0s/certs /etc/k0s/containerd.d/certs.d/nexus.k0s.localhost:30443

    # Ensure local resolution fallback if container was not recreated with new compose.yaml
    dockerz exec k0s-controller grep -q "nexus.k0s.localhost" /etc/hosts ||
        dockerz exec k0s-controller sh -c "echo '127.0.0.1 nexus.k0s.localhost' >> /etc/hosts"

    # Download Step-CA root certificate
    dockerz exec k0s-controller wget --no-check-certificate -q -O /etc/k0s/certs/step-ca.crt https://host.docker.internal:9000/roots.pem

    # Configure containerd CRI registry directory (containerd 2.x v3 format)
    echo 'version = 3

[plugins."io.containerd.cri.v1.images".registry]
config_path = "/etc/k0s/containerd.d/certs.d"
' | dockerz exec --interactive k0s-controller tee /etc/k0s/containerd.d/cri-registry.toml > /dev/null

    # Configure hosts.toml for nexus.k0s.localhost:30443
    cat <<EOF | dockerz exec --interactive k0s-controller tee /etc/k0s/containerd.d/certs.d/nexus.k0s.localhost:30443/hosts.toml > /dev/null
server = "https://nexus.k0s.localhost:30443"

[host."https://nexus.k0s.localhost:30443"]
capabilities = ["pull", "resolve"]
ca = "/etc/k0s/certs/step-ca.crt"

# [host."https://nexus.k0s.localhost:30443".header]
# authorization = "Basic $(printf 'admin:password' | base64)"
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

    print_headline "Apply OpenTofu configuration for Nexus"
    tofu -chdir=gitops/core/in-repo/nexus/opentofu init
    tofu -chdir=gitops/core/in-repo/nexus/opentofu apply -auto-approve
}

main "$@"

