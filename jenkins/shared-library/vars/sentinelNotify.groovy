// Sends a short build summary to Telegram and/or Slack. Each channel is skipped
// when its credential is 'unset'. Never fails the build.
//   sentinelNotify(status: 'SUCCESS', text: 'optional extra text')
def call(Map args = [:]) {
    String status = args.status ?: (currentBuild.currentResult ?: 'UNKNOWN')
    String icon = status == 'SUCCESS' ? '✅' : (status == 'UNSTABLE' ? '⚠️' : '❌')
    String extra = args.text ? "\n${args.text}" : ''
    String message = "${icon} SentinelOps ${status}: ${env.JOB_NAME} #${env.BUILD_NUMBER}" +
        "\nbranch=${env.BRANCH_NAME ?: '-'} commit=${env.GIT_SHA ?: '-'} stage=${env.CURRENT_STAGE ?: '-'}" +
        "\nDRS=${env.DRS_SCORE ?: 'n/a'} critical=${env.VULN_CRITICAL ?: 'n/a'} high=${env.VULN_HIGH ?: 'n/a'}" +
        "\n${env.BUILD_URL ?: ''}${extra}"
    writeFile(file: 'reports/notify-message.txt', text: message)

    withCredentials([
        string(credentialsId: 'telegram-bot-token', variable: 'TG_TOKEN'),
        string(credentialsId: 'telegram-chat-id', variable: 'TG_CHAT'),
        string(credentialsId: 'slack-webhook', variable: 'SLACK_URL'),
    ]) {
        sh(returnStatus: true, script: '''
            set +x
            if [ "$TG_TOKEN" != "unset" ] && [ "$TG_CHAT" != "unset" ]; then
              curl -fsS --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text@reports/notify-message.txt" >/dev/null \
                && echo "notified: telegram" || echo "telegram notification failed"
            fi
            if [ "$SLACK_URL" != "unset" ]; then
              jq -Rs '{text: .}' reports/notify-message.txt \
                | curl -fsS --max-time 10 -H 'Content-type: application/json' --data @- "$SLACK_URL" >/dev/null \
                && echo "notified: slack" || echo "slack notification failed"
            fi
        ''')
    }
}
