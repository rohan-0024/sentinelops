// End-of-build metrics (runs in post { always }). Lives in the trusted shared
// library so the sandboxed Jenkinsfile needs no script approvals for arithmetic.
def call() {
    long now = (System.currentTimeMillis() / 1000L) as long
    boolean ok = currentBuild.currentResult == 'SUCCESS'
    long started = (env.PIPELINE_START_TS ?: "${now}") as long
    long committed = (env.COMMIT_TS ?: "${now}") as long

    Map metrics = [
        sentinelops_build_success           : ok ? 1 : 0,
        sentinelops_build_duration_seconds  : now - started,
        sentinelops_build_timestamp_seconds : now,
        sentinelops_vulnerabilities_critical: env.VULN_CRITICAL ?: 0,
        sentinelops_vulnerabilities_high    : env.VULN_HIGH ?: 0,
        sentinelops_vulnerabilities_medium  : env.VULN_MEDIUM ?: 0,
        sentinelops_vulnerabilities_low     : env.VULN_LOW ?: 0,
    ]
    if (env.DRS_SCORE) {
        metrics.sentinelops_drs_score = env.DRS_SCORE
    }
    if (ok && env.DEPLOYED == '1') {
        metrics.sentinelops_deploy_timestamp_seconds = now
        metrics.sentinelops_lead_time_seconds = now - committed
    }
    if (!ok) {
        metrics.sentinelops_failure_timestamp_seconds = now
    }
    sentinelMetrics(metrics: metrics, labels: [branch: env.BRANCH_NAME ?: 'main', mode: env.MODE ?: 'local'])
}
