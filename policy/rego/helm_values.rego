# Guardrails for the committed Helm values of the app chart (k8s/charts/sentinelops-app).
# Mode files (values-local.yaml / values-aws.yaml) are partial: a rule only applies when its
# key is present in the file under test.
#   conftest test --policy policy/rego --namespace helm_values k8s/charts/sentinelops-app/values*.yaml
package helm_values

import rego.v1

deny contains msg if {
	ref := input.image.ref
	not contains(ref, "@sha256:")
	msg := sprintf("image.ref %q must be pinned by digest (tags are mutable)", [ref])
}

deny contains msg if {
	input.image.tag
	msg := "image.tag is not allowed: deploy by digest via image.ref"
}

deny contains msg if {
	some key in ["errorRate", "latencyMs"]
	value := input.fault[key]
	to_number(value) != 0
	msg := sprintf("fault.%s is %v: fault injection must be off in committed values (use --set for demos)", [key, value])
}

deny contains msg if {
	input.analysis.enabled == false
	msg := "analysis.enabled must stay true: the canary depends on its SLO analysis to roll back"
}

deny contains msg if {
	to_number(input.analysis.maxErrorRate) > 0.05
	msg := sprintf("analysis.maxErrorRate %v is looser than the 5 %% SLO", [input.analysis.maxErrorRate])
}

deny contains msg if {
	to_number(input.analysis.maxP95LatencySeconds) > 0.3
	msg := sprintf("analysis.maxP95LatencySeconds %v is looser than the 300 ms SLO", [input.analysis.maxP95LatencySeconds])
}

deny contains msg if {
	input.replicas < 2
	msg := sprintf("replicas %v: at least 2 are needed for a canary and to survive a pod kill", [input.replicas])
}

deny contains msg if {
	input.canary.steps[0] > 25
	msg := sprintf("first canary step %v %% exposes too much traffic (max 25 %%)", [input.canary.steps[0]])
}

deny contains msg if {
	input.networkPolicy.enabled == false
	msg := "networkPolicy.enabled must stay true (default-deny ingress)"
}
