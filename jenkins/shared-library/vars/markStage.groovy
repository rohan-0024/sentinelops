// Records the running stage so post-failure steps (AI explainer, notifications)
// know which stage broke.
def call() {
    env.CURRENT_STAGE = env.STAGE_NAME
}
