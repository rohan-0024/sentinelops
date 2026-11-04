#!/usr/bin/env bash
# Demo attack mode (Phase 8). Every attack is run against the REAL gate that should stop it.
#
#   make demo-attack   attacker's change set in a throw-away clone (branch demo/vulnerable,
#                      never pushed): hardcoded AWS key, vulnerable dependency, root
#                      container, unsigned image -> each must be BLOCKED. Writes a scoreboard.
#   make demo-canary   a signed but faulty release (50 % HTTP 500s) -> the canary analysis
#                      must fail and Argo Rollouts must roll back on its own.
#   make demo-branch   pushes demo/vulnerable (vulnerable dependency + root USER, NO secret)
#                      to GitHub so the Jenkins pipeline blocks it at stage 6 on screen.
#   make demo-fix      removes every demo change, restores the healthy release and re-runs
#                      the same gates against main -> all PASS.
#
# Why the secret is never pushed: `gitleaks git` scans every ref Jenkins has fetched, so a
# pushed fake key would also fail main's builds. The secret attack runs locally only; build
# #24 in Jenkins is real evidence of that gate firing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
PY="${ROOT}/.venv/bin/python"
[[ -x "${PY}" ]] || PY=python3
CTX="${KUBE_CONTEXT:-kind-sentinelops}"
K=(kubectl --context "${CTX}")
NS=sentinelops
APP=sentinelops-app
WORK="${ROOT}/.demo"
OUT="${ROOT}/reports/demo"
BRANCH=demo/vulnerable
VULN_DEP="django==3.2.0" # several CRITICAL CVEs with fixed versions (e.g. CVE-2022-34265)

ROWS=()
FAILS=0
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
record() { # PASS|FAIL attack gate result evidence
  ROWS+=("| ${2} | ${3} | ${1} ${4} | ${5//|//} |")
  [[ "$1" == PASS ]] || FAILS=$((FAILS + 1))
  printf '  %-4s %-34s %-26s %s\n' "$1" "$2" "$3" "$4"
}
scoreboard() { # title
  mkdir -p "${OUT}"
  {
    echo "## $1"
    echo
    echo "_$(date -u '+%Y-%m-%d %H:%M UTC') · $(git -C "${ROOT}" rev-parse --short HEAD)_"
    echo
    echo "| Scenario | Gate | Result | Evidence |"
    echo "|---|---|---|---|"
    printf '%s\n' "${ROWS[@]}"
  } >"${OUT}/scoreboard.md"
  echo
  echo "scoreboard: ${OUT}/scoreboard.md  (${#ROWS[@]} checks, ${FAILS} failed)"
  [[ ${FAILS} -eq 0 ]]
}

need() { for t in "$@"; do command -v "$t" >/dev/null || { echo "missing tool: $t (run 'make tools')" >&2; exit 1; }; done; }

signed_image() { "${K[@]}" -n "${NS}" get rollout "${APP}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true; }

pod_yaml() { # name image uid
  local nonroot=true
  [[ "$3" == 0 ]] && nonroot=false
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $1, namespace: ${NS} }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: ${nonroot}, runAsUser: $3, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: app
      image: $2
      securityContext:
        runAsNonRoot: ${nonroot}
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources: { limits: { cpu: 100m, memory: 64Mi } }
EOF
}

admission() { # image uid -> prints first denial line, returns kubectl rc
  local out rc
  set +e
  out="$(pod_yaml "demo-$RANDOM" "$1" "$2" | "${K[@]}" apply --dry-run=server -f - 2>&1)"
  rc=$?
  set -e
  ADMISSION_MSG="$(tr '\n' ' ' <<<"${out}" | sed -E 's/.*(denied the request|admission webhook)/\1/' | cut -c1-160)"
  return ${rc}
}

gitleaks_scan() { # repo report -> rc (1 = leaks)
  local rc
  set +e
  gitleaks git --redact --no-banner --exit-code 1 --report-format json --report-path "$2" "$1" >/dev/null 2>&1
  rc=$?
  set -e
  return ${rc}
}

fixable_criticals() { # trivy json
  "${PY}" - "$1" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
hits = sorted({f"{v['PkgName']} {v['InstalledVersion']} {v['VulnerabilityID']}"
               for r in doc.get("Results") or [] for v in r.get("Vulnerabilities") or []
               if v.get("Severity") == "CRITICAL" and v.get("FixedVersion")})
print(len(hits))
for h in hits[:3]:
    print(h)
PYEOF
}

checkov_root_user() { # dockerfile outdir -> prints FAILED/PASSED
  (cd "$2" && "${PY}" -m checkov.main -f "$1" --framework dockerfile --check CKV_DOCKER_8 \
    --skip-download --quiet --compact -o json --output-file-path . >/dev/null 2>&1) || true
  "${PY}" -c "import json,sys; d=json.load(open(sys.argv[1])); print('FAILED' if d['results']['failed_checks'] else 'PASSED')" \
    "$2/results_json.json"
}

# --------------------------------------------------------------------------- attack
attack() {
  need git gitleaks trivy docker kubectl
  rm -rf "${WORK}/attack" "${OUT}"
  mkdir -p "${WORK}" "${OUT}"
  local W="${WORK}/attack/repo" R="${OUT}"

  step "0/5 attacker's branch ${BRANCH} in a throw-away clone (never pushed)"
  git clone -q "${ROOT}" "${W}"
  git -C "${W}" checkout -q -b "${BRANCH}"
  # Built at runtime so this script itself never contains a credential-shaped string.
  local key
  key="$("${PY}" -c 'import random,string; print("AK"+"IA"+"".join(random.choices(string.ascii_uppercase+"234567",k=16)))')"
  printf '# Attack 1: a developer hardcodes cloud credentials "just for testing".\nAWS_ACCESS_KEY_ID = "%s"\n' \
    "${key}" >"${W}/app/sentinel_app/cloud_settings.py"
  echo "${VULN_DEP}" >>"${W}/app/requirements.txt"
  sed -i 's/^USER 65532:65532$/USER root/' "${W}/docker/Dockerfile"
  git -C "${W}" add -A
  git -C "${W}" -c user.name=attacker -c user.email=attacker@example.invalid \
    commit -q -m "feat: quick fix (hardcoded key, extra dependency, run as root)"
  git -C "${W}" --no-pager show --stat --format='  commit %h %s' HEAD | sed 's/^/  /'

  echo
  step "1/5 hardcoded secret -> gitleaks (stage 1)"
  if gitleaks_scan "${W}" "${R}/gitleaks.json"; then
    record FAIL "Hardcoded AWS access key" "gitleaks (stage 1)" "NOT detected" "-"
  else
    local n
    n="$("${PY}" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${R}/gitleaks.json")"
    record PASS "Hardcoded AWS access key" "gitleaks (stage 1)" "BLOCKED" \
      "${n} finding(s), rule $("${PY}" -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["RuleID"])' "${R}/gitleaks.json") in cloud_settings.py"
  fi

  step "2/5 vulnerable dependency (${VULN_DEP}) -> Trivy gate (stage 6)"
  trivy fs --quiet --scanners vuln --format json --output "${R}/trivy-fs.json" "${W}/app"
  local crit
  mapfile -t crit < <(fixable_criticals "${R}/trivy-fs.json")
  if ((crit[0] > 0)); then
    record PASS "Vulnerable dependency ${VULN_DEP}" "Trivy gate (stage 6)" "BLOCKED" \
      "${crit[0]} fixable CRITICAL, e.g. ${crit[1]}"
  else
    record FAIL "Vulnerable dependency ${VULN_DEP}" "Trivy gate (stage 6)" "NOT detected" "0 fixable CRITICAL"
  fi

  step "3/5 container runs as root -> checkov (stage 4) + Kyverno admission"
  mkdir -p "${R}/checkov"
  if [[ "$(checkov_root_user "${W}/docker/Dockerfile" "${R}/checkov")" == FAILED ]]; then
    cp "${R}/checkov/results_json.json" "${R}/results_json.json"
    record PASS "Dockerfile 'USER root'" "checkov CKV_DOCKER_8 (stage 4)" "FLAGGED" "\"Ensure the last USER is not root\" (+ DRS points)"
  else
    record FAIL "Dockerfile 'USER root'" "checkov CKV_DOCKER_8 (stage 4)" "NOT detected" "-"
  fi
  local signed
  signed="$(signed_image)"
  if [[ -z "${signed}" ]]; then
    record FAIL "Pod running as UID 0" "Kyverno pod-security" "SKIPPED" "no deployed rollout - run the pipeline once"
  elif admission "${signed}" 0; then
    record FAIL "Pod running as UID 0" "Kyverno pod-security" "ADMITTED" "-"
  else
    record PASS "Pod running as UID 0 (signed image)" "Kyverno pod-security" "DENIED" "${ADMISSION_MSG}"
  fi

  step "4/5 unsigned image -> Kyverno verifyImages (admission)"
  docker build -q -f "${ROOT}/docker/Dockerfile" --label "sentinelops.demo=unsigned-$(date +%s)" \
    -t localhost:5001/sentinelops-app:attacker "${ROOT}/app" >/dev/null
  docker push -q localhost:5001/sentinelops-app:attacker >/dev/null
  local digest
  digest="$(docker image inspect localhost:5001/sentinelops-app:attacker \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep -m1 '^localhost:5001/sentinelops-app@' | cut -d@ -f2)"
  if admission "kind-registry:5000/sentinelops-app@${digest}" 65532; then
    record FAIL "Unsigned image pushed to the trusted registry" "Kyverno verifyImages" "ADMITTED" "-"
  else
    record PASS "Unsigned image pushed to the trusted registry" "Kyverno verifyImages" "DENIED" "${ADMISSION_MSG}"
  fi

  step "5/5 combined change set -> Deployment Risk Score (stage 8)"
  local rc
  set +e
  (cd "${ROOT}" && "${PY}" -m tools.drs --reports "${R}" --config policy/risk.yaml --out "${R}" >/dev/null)
  rc=$?
  set -e
  local score
  score="$("${PY}" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["score"], "->", d["decision"])' "${R}/drs.json")"
  if [[ ${rc} -eq 3 ]]; then
    record PASS "Whole attacker change set" "Deployment Risk Score (stage 8)" "BLOCKED" "DRS ${score} (secret alone = 100)"
  else
    record FAIL "Whole attacker change set" "Deployment Risk Score (stage 8)" "NOT blocked" "DRS ${score}"
  fi

  scoreboard "Demo attack: every attack must be stopped"
  echo "Next: 'make demo-canary' (bad release, auto-rollback), then 'make demo-fix'."
}

# --------------------------------------------------------------------------- canary
canary() {
  need kubectl helm
  local img rc
  img="$(signed_image)"
  [[ -n "${img}" ]] || { echo "no deployed rollout - run the pipeline once first" >&2; exit 1; }
  step "bad release: same signed image, 50 % of requests return HTTP 500 (fault injection)"
  echo "  watch it live:  make rollout-status   or   Grafana -> DevSecOps Command Center"
  set +e
  DRS_DECISION="" bash "${ROOT}/scripts/deploy.sh" "${img}" --set-string fault.errorRate=0.5
  rc=$?
  set -e
  "${K[@]}" -n "${NS}" get analysisrun --sort-by=.metadata.creationTimestamp | tail -n 3
  if [[ ${rc} -ne 0 ]] && "${K[@]}" -n "${NS}" get rollout "${APP}" -o jsonpath='{.status.abort}' | grep -q true; then
    record PASS "Faulty release (50 % HTTP 500)" "Canary analysis (Argo Rollouts)" "ROLLED BACK" \
      "analysis failed, aborted, stable kept serving"
  else
    record FAIL "Faulty release (50 % HTTP 500)" "Canary analysis (Argo Rollouts)" "NOT rolled back" "deploy rc=${rc}"
  fi
  scoreboard "Demo: self-healing canary"
}

# --------------------------------------------------------------------------- branch
branch() {
  need git
  local W="${WORK}/branch"
  rm -rf "${W}"
  git -C "${ROOT}" worktree prune
  git -C "${ROOT}" worktree add -q -B "${BRANCH}" "${W}" origin/main
  echo "${VULN_DEP}" >>"${W}/app/requirements.txt"
  sed -i 's/^USER 65532:65532$/USER root/' "${W}/docker/Dockerfile"
  git -C "${W}" add -A
  git -C "${W}" commit -q -m "demo: vulnerable dependency and root container (expected to be blocked)"
  git -C "${W}" push -q -f origin "${BRANCH}"
  git -C "${ROOT}" worktree remove --force "${W}"
  echo "pushed ${BRANCH}: ${VULN_DEP} + 'USER root' (no secret, see header of scripts/demo.sh)"
  echo "Jenkins: SentinelOps -> Scan Multibranch Pipeline Now -> ${BRANCH}"
  echo "expected: red at stage 6 (Trivy gate: fixable CRITICAL in django), checkov flags CKV_DOCKER_8,"
  echo "          explain.md names the CVEs and the upgrade. Remove with 'make demo-fix'."
}

# --------------------------------------------------------------------------- fix
fix() {
  need git gitleaks trivy kubectl
  step "removing demo changes"
  rm -rf "${WORK}" "${OUT}"
  mkdir -p "${OUT}"
  git -C "${ROOT}" worktree prune
  if git -C "${ROOT}" ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null 2>&1; then
    git -C "${ROOT}" push -q origin --delete "${BRANCH}" && echo "  deleted remote branch ${BRANCH}"
  fi
  git -C "${ROOT}" branch -D "${BRANCH}" >/dev/null 2>&1 || true
  docker image rm -f localhost:5001/sentinelops-app:attacker >/dev/null 2>&1 || true

  local img
  img="$(signed_image)"
  if [[ -n "${img}" ]]; then
    local abort fault
    abort="$("${K[@]}" -n "${NS}" get rollout "${APP}" -o jsonpath='{.status.abort}')"
    fault="$("${K[@]}" -n "${NS}" get rollout "${APP}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FAULT_ERROR_RATE")].value}')"
    if [[ "${abort}" == true || "${fault:-0}" != 0 ]]; then
      step "restoring the healthy release (fault injection off)"
      DRS_DECISION=auto bash "${ROOT}/scripts/deploy.sh" "${img}" --set-string fault.errorRate=0 >/dev/null
    fi
  fi

  step "re-running the same gates against main"
  if gitleaks_scan "${ROOT}" "${OUT}/gitleaks.json"; then
    record PASS "Repository history" "gitleaks" "CLEAN" "no leaks"
  else
    record FAIL "Repository history" "gitleaks" "LEAKS" "see ${OUT}/gitleaks.json"
  fi
  trivy fs --quiet --scanners vuln --format json --output "${OUT}/trivy-fs.json" "${ROOT}/app"
  local crit
  mapfile -t crit < <(fixable_criticals "${OUT}/trivy-fs.json")
  if ((crit[0] == 0)); then
    record PASS "app/requirements.txt" "Trivy gate" "CLEAN" "0 fixable CRITICAL"
  else
    record FAIL "app/requirements.txt" "Trivy gate" "VULNERABLE" "${crit[1]}"
  fi
  mkdir -p "${OUT}/checkov"
  if [[ "$(checkov_root_user "${ROOT}/docker/Dockerfile" "${OUT}/checkov")" == PASSED ]]; then
    record PASS "docker/Dockerfile" "checkov CKV_DOCKER_8" "CLEAN" "USER 65532 (distroless nonroot)"
  else
    record FAIL "docker/Dockerfile" "checkov CKV_DOCKER_8" "ROOT" "-"
  fi
  if [[ -n "${img}" ]] && admission "${img}" 65532; then
    record PASS "Signed, non-root pod" "Kyverno" "ADMITTED" "${img##*@}"
  else
    record FAIL "Signed, non-root pod" "Kyverno" "DENIED" "${ADMISSION_MSG:-no rollout}"
  fi
  local health
  health="$("${K[@]}" -n "${NS}" get rollout "${APP}" -o jsonpath='{.status.phase}' 2>/dev/null || echo missing)"
  if [[ "${health}" == Healthy ]]; then
    record PASS "Production rollout" "Argo Rollouts" "HEALTHY" "$("${K[@]}" -n "${NS}" get rollout "${APP}" -o jsonpath='{.status.availableReplicas}') replicas available"
  else
    record FAIL "Production rollout" "Argo Rollouts" "${health}" "-"
  fi
  scoreboard "Demo fix: secure baseline restored"
}

case "${1:-}" in
  attack) attack ;;
  canary) canary ;;
  branch) branch ;;
  fix) fix ;;
  *) echo "usage: $0 attack|canary|branch|fix" >&2; exit 2 ;;
esac
