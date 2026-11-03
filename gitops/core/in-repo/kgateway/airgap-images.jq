.. | .envoyContainer? // empty | .image? // empty | select(type == "object" and .registry != null) | "\(.registry)/\(.repository):\(.tag)"
