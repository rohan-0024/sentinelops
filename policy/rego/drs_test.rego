package drs_test

import rego.v1

import data.drs

base := {
	"score": 54.0,
	"decision": "canary",
	"thresholds": {"auto": 30, "block": 60},
	"components": [
		{"name": "secrets", "raw": 0, "cap": 100, "points": 0},
		{"name": "vuln_high_fixable", "raw": 48, "cap": 24, "points": 24},
	],
}

test_valid_report_passes if {
	denies := drs.deny with input as base
	count(denies) == 0
}

test_decision_must_match_score if {
	denies := drs.deny with input as object.union(base, {"decision": "auto"})
	some msg in denies
	contains(msg, "does not match")
}

test_score_above_block_threshold_must_block if {
	denies := drs.deny with input as object.union(base, {"score": 61.0})
	some msg in denies
	contains(msg, "expected \"block\"")
}

test_score_out_of_range if {
	denies := drs.deny with input as object.union(base, {"score": 150, "decision": "block"})
	some msg in denies
	contains(msg, "outside 0-100")
}

test_missing_score if {
	denies := drs.deny with input as object.remove(base, ["score"])
	some msg in denies
	contains(msg, "missing")
}

test_points_above_cap if {
	bad := object.union(base, {"components": [{"name": "vuln_medium", "raw": 500, "cap": 4, "points": 100}]})
	denies := drs.deny with input as bad
	some msg in denies
	contains(msg, "above its cap")
}

test_leaked_secret_must_block if {
	leak := object.union(base, {"components": [{"name": "secrets", "raw": 1, "cap": 100, "points": 100}]})
	denies := drs.deny with input as leak
	some msg in denies
	contains(msg, "must always block")
}
