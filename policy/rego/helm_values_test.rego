package helm_values_test

import rego.v1

import data.helm_values

good := {
	"image": {"ref": "kind-registry:5000/sentinelops-app@sha256:0000000000000000000000000000000000000000000000000000000000000000"},
	"replicas": 10,
	"fault": {"errorRate": "0", "latencyMs": "0"},
	"canary": {"steps": [10, 50]},
	"analysis": {"enabled": true, "maxErrorRate": "0.05", "maxP95LatencySeconds": "0.3"},
	"networkPolicy": {"enabled": true},
}

test_committed_defaults_pass if {
	denies := helm_values.deny with input as good
	count(denies) == 0
}

test_partial_mode_file_passes if {
	denies := helm_values.deny with input as {"env": "aws", "replicas": 5, "service": {"type": "ClusterIP"}}
	count(denies) == 0
}

test_tag_reference_denied if {
	denies := helm_values.deny with input as object.union(good, {"image": {"ref": "registry/app:latest"}})
	some msg in denies
	contains(msg, "pinned by digest")
}

test_fault_injection_left_on_denied if {
	denies := helm_values.deny with input as object.union(good, {"fault": {"errorRate": "0.5", "latencyMs": "0"}})
	some msg in denies
	contains(msg, "fault.errorRate")
}

test_disabled_analysis_denied if {
	bad := object.union(good, {"analysis": {"enabled": false, "maxErrorRate": "0.05", "maxP95LatencySeconds": "0.3"}})
	denies := helm_values.deny with input as bad
	some msg in denies
	contains(msg, "analysis.enabled")
}

test_loose_slo_denied if {
	bad := object.union(good, {"analysis": {"enabled": true, "maxErrorRate": "0.2", "maxP95LatencySeconds": "1"}})
	denies := helm_values.deny with input as bad
	count(denies) == 2
}

test_single_replica_denied if {
	denies := helm_values.deny with input as object.union(good, {"replicas": 1})
	some msg in denies
	contains(msg, "at least 2")
}

test_big_first_canary_step_denied if {
	denies := helm_values.deny with input as object.union(good, {"canary": {"steps": [50, 100]}})
	some msg in denies
	contains(msg, "first canary step")
}
