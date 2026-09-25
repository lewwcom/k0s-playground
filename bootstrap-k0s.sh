#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

if [[ "${1-}" =~ ^-*h(elp)?$ ]]; then
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
fi

cd "$(dirname "$0")"
source .env

main() {
    case "${1-}" in
        bundle-images)
            bundle-images
            exit 0
            ;;
        config-cluster-only) : ;;
        *)
            bundle-images
            dockerz compose up --detach
            ;;
    esac

    print-headline "Waiting for k0s..."
    until kubectlz cluster-info &> /dev/null; do :; done
    kubectlz cluster-info

    # TODO: Self-host Harbor
    # add-harbor-auth

    # Deploy kustomize apps
    local core_apps=("gateway-api-crds" "local-path-provisioner" "ArgoCD" "Gogs")
    local app; for app in "${core_apps[@]}"; do
        print-headline "Deploy $app"
        local app_path=${app,,}
        kubectl kustomize gitops/core/in-repo/$app_path/ | kubectlz-apply
    done

    make set-up-gogs-repo
    make commit-to-gogs
    cat gitops/applications/app.yaml | kubectlz-apply

    until make APP=kong wait-argocd-app; do :; done
    print-headline "Done!"
    echo "You can access ArgoCD, Gogs and Radar at:"
    echo "- ArgoCD: http://argocd.k0s.localhost:30080 (admin:password)"
    echo "- Gogs: http://gogs.k0s.localhost:30080 (gogs-admin:password)"
    echo "- Radar: http://radar.k0s.localhost:30080"
    echo
    echo 'To access the cluster with kubectl, `source activate.sh`'
}

print-headline() {
    local highlight_style='\033[1;36m'
    local color_off='\033[0m'
    echo; echo -e "${highlight_style}${1}${color_off}"
}

dockerz() {
    ${USE_SUDO:+sudo} docker "$@"
}

kubectlz() {
    dockerz exec --interactive k0s-controller k0s kubectl "$@"
}

kubectlz-apply() {
    local manifest=$(mktemp)
    tee $manifest > /dev/null
    if cat $manifest | kubectlz apply --server-side --force-conflicts --filename -; then
        rm $manifest
        return
    fi
    local i; for i in {1..5}; do
        echo "Wait ${i}s..."
        sleep $i
        if cat $manifest | kubectlz apply --server-side --force-conflicts --filename -; then
            rm $manifest
            return
        fi
    done
    rm $manifest
    false
}

bundle-images() {
    print-headline "Pull k0s core images"
    local prefix="harbor.example.com/"
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

    dockerz image save -o image-bundle.tar "${upstream_images[@]}"
}

add-harbor-auth() {
    dockerz exec k0s-controller mkdir --parents /etc/k0s/containerd.d/certs.d/harbor.example.com
    echo 'version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
config_path = "/etc/k0s/containerd.d/certs.d"
' | dockerz exec --interactive k0s-controller tee /etc/k0s/containerd.d/cri-registry.toml > /dev/null

    echo "server = \"https://harbor.example.com\"

[host.\"https://harbor.example.com\"]
capabilities = [\"pull\", \"resolve\"]
skip_verify = true

[host.\"https://harbor.example.com\".header]
authorization = \"Basic $(echo -n "$HARBOR_USER:$HARBOR_PASSWORD" | base64)\"
" | dockerz exec --interactive k0s-controller tee /etc/k0s/containerd.d/certs.d/harbor.example.com/hosts.toml > /dev/null
}

main "$@"

