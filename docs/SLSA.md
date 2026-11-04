# Supply-chain security against SLSA v1.0 (Feature 2)

[SLSA](https://slsa.dev/spec/v1.0/) ("Supply-chain Levels for Software Artifacts") grades how
much you can trust that an artifact was built from the source you think, by the builder you
think, without tampering. v1.0 defines the **Build track**, levels L0-L3.

## What every build produces
| Artifact | Produced by | Bound to the image how | Verified where |
|---|---|---|---|
| Image | stage 5 (BuildKit, multi-stage, distroless) | content digest `sha256:...` | deployed by digest only |
| Signature | stage 10, `cosign sign` (pipeline key) | signs the digest | **Kyverno at admission** (`verify-images.yaml`) |
| SBOM (CycloneDX) | stage 7, Syft | `cosign attest --type cyclonedx` | **Kyverno at admission** (`require-attestations.yaml`) |
| Vulnerability scan | stage 6, Trivy | `cosign attest --type vuln` | **Kyverno at admission** |
| **Build provenance (SLSA v1)** | stage 10, `tools/provenance` | `cosign attest --type slsaprovenance1` | `make provenance-check` |

The provenance predicate records:
- `buildDefinition.externalParameters`: repository, branch, mode and image reference.
- `buildDefinition.internalParameters`: Jenkins job, build number and Risk Score decision.
- `resolvedDependencies`: the git commit, the base images (by digest when pinned), and SHA-256 hashes of `app/requirements.txt`, `versions.env` and `policy/risk.yaml`.
- `runDetails`: builder id, build URL as `invocationId`, start and finish times, and hashes of the SBOM, Trivy and DRS reports as byproducts.

It never reads secrets; a unit test checks this.

```bash
make provenance-check
#   OK  signature
#   OK  cyclonedx        predicateType=https://cyclonedx.org/bom
#   OK  vuln             predicateType=https://cosign.sigstore.dev/attestation/vuln/v1
#   OK  slsaprovenance1  builder=http://localhost:8080/#sentinelops-pipeline
#       source=git+https://github.com/rohan-0024/sentinelops.git@main commit=<sha>
```

## Level assessment (Build track)
| Requirement | L1 | L2 | L3 | SentinelOps |
|---|:-:|:-:|:-:|---|
| Consistent, scripted build process | ✓ | ✓ | ✓ | ✅ Declarative Jenkinsfile; nobody builds release images by hand |
| Provenance exists | ✓ | ✓ | ✓ | ✅ SLSA v1 predicate on every image |
| Provenance is distributed with the artifact | ✓ | ✓ | ✓ | ✅ OCI attestation next to the image in the registry |
| Build runs on a **hosted** build platform | | ✓ | ✓ | ✅ AWS mode (dedicated Jenkins EC2) · ⚠ local mode runs on a laptop |
| Provenance is **signed** by the platform and verifiable | | ✓ | ✓ | ✅ signed with the pipeline's Cosign key; verified with the public key |
| Signing material is **not accessible to build steps** | | | ✓ | ❌ the key is a Jenkins credential that pipeline steps can read |
| Builds are **isolated** from each other (ephemeral, no shared cache influence) | | | ✓ | ❌ shared executor workspace and Docker daemon |
| Provenance is unforgeable by the build's own steps | | | ✓ | ❌ follows from the two rows above |

**Result: SLSA Build L2 in AWS mode, Build L1 in local mode.** L3 is not claimed.

### Beyond SLSA: controls the levels do not require
- **Admission enforcement**: the cluster refuses images without a valid signature, SBOM and vulnerability attestations, images not pinned by digest, and images from untrusted registries. SLSA only requires that provenance *can* be verified; we enforce it.
- **Vulnerability gate**: a fixable CRITICAL CVE fails the build. HIGH findings and the rest feed the Deployment Risk Score.
- **Secret scanning** of the full git history on every build.
- **Pinned toolchain**: `versions.env` pins every tool, and the base images are pinned in the Dockerfile.

## Road to L3 (if this were production)
1. **Isolated signer:** keep the key in AWS KMS (`cosign ... --key awskms://alias/sentinelops-cosign`) and grant `kms:Sign` only to a separate signing job, not to user-defined build steps. Alternatively use keyless Sigstore with the CI's OIDC identity.
2. **Ephemeral builders:** run each build in a fresh agent (Kubernetes pod agents or EC2 spot agents), with no shared Docker daemon.
3. **Enforce provenance at admission:** add a Kyverno attestation rule for `https://slsa.dev/provenance/v1` that checks `builder.id` and that the source repository is `rohan-0024/sentinelops`.
4. **Transparency log:** sign with `--tlog-upload=true` (public Rekor or a private instance) so signatures are auditable.
5. **Source track:** protected `main` branch, required reviews and the GitHub `verify` check, signed commits.

## Mapping to the demos
| Demo | Shows |
|---|---|
| `make demo-supply-chain` | Unsigned, tag-referenced and untrusted-registry images are denied; the pipeline-signed image is admitted |
| `make demo-attack` (step 4/5) | An image pushed straight to the trusted registry, bypassing CI, is denied |
| `make provenance-check` | The running image carries a valid signature, SBOM, vulnerability scan and SLSA provenance |
