`test-cosign.pub` is a throwaway P-256 public key (private half discarded) used only by
`make helm-lint` to render the chart. Real deployments pass `policy/keys/cosign.pub`.
