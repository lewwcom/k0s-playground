.. | .args? // empty | .[]? | strings | select(test("^--acme-http01-solver-image=")) | sub("^--acme-http01-solver-image="; "")
