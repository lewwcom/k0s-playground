select(.kind == "Cluster" and .metadata.name == "postgres-nexus") | .spec.imageName // empty
