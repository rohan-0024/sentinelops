# Security notes: supply-chain events that changed this project

## Trivy release compromise (2026), CVE-2026-33634

**What happened**
- **2026-02-28:** an attacker ("hackerbot-claw") gained access to Trivy's GitHub
  automation and deleted GitHub Releases **v0.27.0 through v0.69.1**.
- **2026-03-19:** a malicious **v0.69.4** was published (binaries and images), and
  `latest` pointed to it for about 3 hours. Docker Hub tags 0.69.5 and 0.69.6 were
  also malicious and were removed later. Mutable tags (`latest`, re-pointable
  Git tags in `trivy-action`) were the delivery mechanism.

**Impact on SentinelOps**
- The project originally pinned Trivy **0.58.1**. During Phase 3 verification,
  `make ansible-test` failed with **HTTP 404** for the 0.58.1 `.deb`, because that
  release had been deleted.
- Pinning prevented silently pulling the malicious `latest`, but the deleted
  asset broke the build. That is the intended failure mode: fail closed rather
  than run something unverified.

**Decision**
- Pin **Trivy 0.69.3**, the last known-good release. It is protected by GitHub
  immutable releases, and Homebrew and Docker Hub rolled back to it.
- Never use `latest` for scanners or CI actions. Pin exact versions (and image
  digests where possible).
- If any pipeline had run v0.69.4 or the Docker Hub 0.69.5/0.69.6 images, every
  secret reachable from that pipeline would have to be rotated. SentinelOps never
  ran them.

**Why this matters for the project (viva talking point)**
A *security scanner* became the attack vector. This is the threat that Feature 2
(zero-trust supply chain: SBOM, Cosign signatures, Kyverno admission) is designed
to contain, and why every tool in `versions.env` is pinned.

Sources:
- [StepSecurity: Trivy compromised a second time (v0.69.4)](https://www.stepsecurity.io/blog/trivy-compromised-a-second-time---malicious-v0-69-4-release)
- [Docker Scout: CVE-2026-33634](https://scout.docker.com/vulnerabilities/id/CVE-2026-33634)
