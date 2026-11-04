{{- define "app.name" -}}sentinelops-app{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sentinelops
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Fails rendering unless the image is pinned by digest (never deploy a mutable tag). */}}
{{- define "app.image" -}}
{{- $ref := required "image.ref is required (registry/repo@sha256:<digest>)" .Values.image.ref -}}
{{- if not (regexMatch "@sha256:[a-f0-9]{64}$" $ref) -}}
{{- fail (printf "image.ref must be pinned by digest, got %q" $ref) -}}
{{- end -}}
{{- $ref -}}
{{- end -}}

{{/* Namespace is explicit (not "default") so rendered manifests and scanners agree. */}}
{{- define "app.namespace" -}}{{ .Values.namespaceOverride | default .Release.Namespace }}{{- end -}}
