# Sanity rules for the Deployment Risk Score report (Feature 1, reports/drs.json).
# They guard the scorer itself: a bug in tools/drs must never turn a risky build into "auto".
#   conftest test --policy policy/rego --namespace drs reports/drs.json
package drs

import rego.v1

deny contains msg if {
	not is_number(input.score)
	msg := "score is missing or not a number"
}

deny contains msg if {
	is_number(input.score)
	not within(input.score, 0, 100)
	msg := sprintf("score %v is outside 0-100", [input.score])
}

deny contains msg if {
	not input.thresholds.auto
	msg := "thresholds.auto is missing"
}

deny contains msg if {
	is_number(input.score)
	want := expected_decision(input.score, input.thresholds)
	input.decision != want
	msg := sprintf("decision %q does not match score %v (expected %q)", [input.decision, input.score, want])
}

deny contains msg if {
	some c in input.components
	c.points > c.cap
	msg := sprintf("factor %s scored %v points, above its cap %v", [c.name, c.points, c.cap])
}

deny contains msg if {
	some c in input.components
	c.name == "secrets"
	c.raw > 0
	input.decision != "block"
	msg := "a leaked secret must always block the deployment"
}

within(x, lo, hi) if {
	x >= lo
	x <= hi
}

expected_decision(score, th) := "auto" if score < th.auto

expected_decision(score, th) := "canary" if {
	score >= th.auto
	score <= th.block
}

expected_decision(score, th) := "block" if score > th.block
