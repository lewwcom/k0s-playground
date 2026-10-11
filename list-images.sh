#!/usr/bin/env bash

find gitops/*/in-repo -name Chart.yaml -not -path "*/charts/*" |
    xargs dirname | xargs -n1 helm dependency update 1>&2

{
    VERSION=$(
    yq --raw-output '.services."k0s-controller".image' compose.yaml |
        cut -d ":" -f 2 | tr "-" "+"
    )
    ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then arch=arm64; fi
    curl --location https://github.com/k0sproject/k0s/releases/download/$VERSION/airgap-images-linux-$ARCH.txt

    {
        yq --raw-output '.apps[] | .name' gitops/core/external-helm/config.yaml |
            xargs -I{} make APP={} helm-template
        echo "---"
        find gitops/*/in-repo -name kustomization.yaml |
            xargs dirname | xargs -n1 kubectl kustomize
        echo "---"
        find gitops/*/in-repo -name Chart.yaml -not -path "*/charts/*" |
            xargs dirname | xargs -n1 helm template
        } | yq --raw-output '.. | .image? // empty | select(type == "string")'
} | sort -u

