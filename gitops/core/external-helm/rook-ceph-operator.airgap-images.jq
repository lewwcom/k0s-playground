select(.kind == "ConfigMap" and .metadata.name == "rook-csi-operator-image-set-configmap") | .data[]
