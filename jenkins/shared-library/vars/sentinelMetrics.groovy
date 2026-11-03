// Pushes pipeline metrics to the Prometheus Pushgateway (feeds DORA, DRS and
// vulnerability panels in Grafana). Never fails the build: metrics are best-effort.
//   sentinelMetrics(metrics: [sentinelops_build_success: 1, ...], labels: [branch: 'main'])
def call(Map args = [:]) {
    String url = env.PUSHGATEWAY_URL ?: ''
    if (!url) {
        echo 'sentinelMetrics: PUSHGATEWAY_URL not set, skipping'
        return
    }
    Map metrics = args.metrics ?: [:]
    Map labels = args.labels ?: [:]
    String job = args.job ?: 'sentinelops_pipeline'
    String instance = (env.BRANCH_NAME ?: 'main').replaceAll('[^A-Za-z0-9_.-]', '_')

    StringBuilder body = new StringBuilder()
    metrics.each { name, value ->
        String labelText = labels.collect { k, v -> "${k}=\"${v.toString().replace('"', '')}\"" }.join(',')
        body.append(labelText ? "${name}{${labelText}} ${value}\n" : "${name} ${value}\n")
    }
    writeFile(file: 'reports/metrics.prom', text: body.toString())
    int rc = sh(
        returnStatus: true,
        script: "curl -fsS --max-time 10 --data-binary @reports/metrics.prom '${url}/metrics/job/${job}/instance/${instance}'"
    )
    if (rc != 0) {
        echo "sentinelMetrics: push to ${url} failed (rc=${rc}); continuing"
    }
}
