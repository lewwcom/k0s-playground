#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
if [ "${TRACE-0}" = "1" ]; then
    set -o xtrace
fi

case "${1-}" in
    -h|--help|-help|help)
        echo "Usage: ./$(basename "$0") [csv-images | images-file]"
        echo '
Verifies Nexus proxy caching by performing none-cache pulls
of images provided as a CSV string (or an images file, falling
back to airgap-images.txt) using an isolated containerd namespace
inside the k0s-controller container.

Environment variables:
  CTR_NAMESPACE  Containerd namespace to use for verification (default: verify-nexus).
  USE_SUDO       Set to any non-empty value to prefix docker commands with sudo.'
        exit 0
        ;;
esac

cd "$(dirname "$0")"

main() {
    local input="${1:-airgap-images.txt}"
    local prefix="nexus.k0s.localhost:30443/"
    local hosts_dir="/etc/k0s/containerd.d/certs.d"
    local ctr_ns="${CTR_NAMESPACE:-verify-nexus}"

    local raw_images=()

    print_headline "Verifying Nexus Images (None-Cache Pull via containerd)"
    echo "Containerd namespace: $ctr_ns"

    if [[ "$input" == *","* ]]; then
        IFS=',' read -r -a raw_images <<< "$input"
    else
        if [ ! -f "$input" ]; then
            echo "Error: Image file '$input' not found." >&2
            exit 1
        fi
        echo "Image source: $input"
        while IFS= read -r line || [ -n "$line" ]; do
            raw_images+=("$line")
        done < "$input"
    fi

    local nexus_images=()
    for image in "${raw_images[@]}"; do
        image="$(echo "$image" | xargs)"
        [ -z "$image" ] && continue
        [[ "$image" =~ ^# ]] && continue

        if [[ "$image" != "$prefix"* ]]; then
            image="${prefix}${image}"
        fi
        nexus_images+=("$image")
    done

    local total=${#nexus_images[@]}
    if [ "$total" -eq 0 ]; then
        echo "Warning: No valid images found to verify."
        exit 0
    fi

    echo "Total images to verify: $total"

    # Reset isolated containerd namespace to guarantee empty cache
    cleanup_namespace "$ctr_ns"
    ctrz namespaces create "$ctr_ns"

    # Clean up test namespace upon exit
    trap 'cleanup_namespace "'"$ctr_ns"'"' EXIT

    local passed=0
    local failed=0
    local failed_images=()
    local index=0

    TIMEFORMAT="  -> Time: %Rs"
    for img in "${nexus_images[@]}"; do
        index=$((index + 1))
        printf "\n[%d/%d] %s\n" "$index" "$total" "$img"

        # Pull through Nexus proxy using containerd hosts.toml configuration
        printf "  -> Pulling through Nexus into namespace '%s'...\n" "$ctr_ns"
        if time ctrz --namespace "$ctr_ns" image pull --hosts-dir "$hosts_dir" "$img" > /dev/null 2>&1; then
            echo "  -> [OK] Successfully pulled"
            passed=$((passed + 1))
        else
            echo "  -> [FAILED] Failed to pull" >&2
            failed=$((failed + 1))
            failed_images+=("$img")
        fi
    done

    print_headline "Verification Summary"
    echo "Total:  $total"
    echo "Passed: $passed"
    echo "Failed: $failed"

    if [ "$failed" -gt 0 ]; then
        echo ""
        echo "Failed images:"
        for failed_img in "${failed_images[@]}"; do
            echo "  - $failed_img"
        done
        exit 1
    fi

    print_headline "All Nexus images verified successfully!"
}

print_headline() {
    local highlight_style='\033[1;36m'
    local color_off='\033[0m'
    printf "\n${highlight_style}%s${color_off}\n" "${1}"
}

dockerz() {
    ${USE_SUDO:+sudo} docker "$@"
}

ctrz() {
    dockerz exec k0s-controller k0s ctr "$@"
}

cleanup_namespace() {
    local ns="${1}"
    dockerz exec k0s-controller sh -c "
        k0s ctr -n '${ns}' images ls -q 2>/dev/null | xargs -r -n 50 k0s ctr -n '${ns}' images rm >/dev/null 2>&1 || true
        k0s ctr -n '${ns}' content ls -q 2>/dev/null | xargs -r -n 50 k0s ctr -n '${ns}' content rm >/dev/null 2>&1 || true
        k0s ctr namespaces rm '${ns}' >/dev/null 2>&1 || true
    " >/dev/null 2>&1 || true
}

main "$@"
