// Security gate over one or more Trivy JSON reports.
// Fails the build on any CRITICAL vulnerability that has a fixed version
// (unfixable CVEs are reported, not gated - there is nothing to upgrade to).
// Returns the severity counts so later stages (DRS, metrics) can use them.
def call(Map args = [:]) {
    List<String> reports = args.reports ?: ['reports/trivy-image.json']
    boolean failOnCritical = args.containsKey('failOnCritical') ? args.failOnCritical : true

    Map<String, Integer> counts = [CRITICAL: 0, HIGH: 0, MEDIUM: 0, LOW: 0, UNKNOWN: 0]
    int criticalFixable = 0
    for (String path : reports) {
        if (!fileExists(path)) {
            echo "sentinelTrivyGate: ${path} not found, skipping"
            continue
        }
        def report = readJSON(file: path)
        for (def result : (report.Results ?: [])) {
            for (def vuln : (result.Vulnerabilities ?: [])) {
                String sev = (vuln.Severity ?: 'UNKNOWN').toString()
                counts[sev] = (counts[sev] ?: 0) + 1
                if (sev == 'CRITICAL' && vuln.FixedVersion) {
                    criticalFixable++
                }
            }
        }
    }

    env.VULN_CRITICAL = counts.CRITICAL.toString()
    env.VULN_HIGH = counts.HIGH.toString()
    env.VULN_MEDIUM = counts.MEDIUM.toString()
    env.VULN_LOW = counts.LOW.toString()
    env.VULN_CRITICAL_FIXABLE = criticalFixable.toString()
    echo "Trivy: CRITICAL=${counts.CRITICAL} (fixable ${criticalFixable}) HIGH=${counts.HIGH} MEDIUM=${counts.MEDIUM} LOW=${counts.LOW}"

    if (counts.HIGH > 0) {
        echo "WARNING: ${counts.HIGH} HIGH vulnerabilities reported (not gated; weighted in the Deployment Risk Score)"
    }
    if (failOnCritical && criticalFixable > 0) {
        error("Trivy gate failed: ${criticalFixable} fixable CRITICAL vulnerabilities")
    }
    return counts + [CRITICAL_FIXABLE: criticalFixable]
}
