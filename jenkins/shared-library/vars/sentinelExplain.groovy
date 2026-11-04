// Feature 5: on failure, capture the build log tail (trusted library code may read the
// raw build log), then run the explainer (secrets are redacted inside the tool).
// Never fails the build.
def call(Map args = [:]) {
    int lines = (args.lines ?: 400) as int
    try {
        List<String> log = currentBuild.rawBuild.getLog(lines)
        writeFile(file: 'reports/build-log.txt', text: log.join('\n'))
    } catch (Exception e) {
        echo "sentinelExplain: could not read build log (${e.message})"
        writeFile(file: 'reports/build-log.txt', text: '')
    }
    withCredentials([string(credentialsId: 'anthropic-api-key', variable: 'ANTHROPIC_API_KEY')]) {
        sh(returnStatus: true, script: '''
            [ "$ANTHROPIC_API_KEY" = "unset" ] && unset ANTHROPIC_API_KEY
            python3 -m tools.explain --log reports/build-log.txt --stage "$CURRENT_STAGE" \
              --reports reports --out reports --build-url "$BUILD_URL"
        ''')
    }
    archiveArtifacts(artifacts: 'reports/explain.*,reports/build-log.txt', allowEmptyArchive: true)
    return fileExists('reports/explain-summary.txt') ? readFile('reports/explain-summary.txt').trim() : ''
}
