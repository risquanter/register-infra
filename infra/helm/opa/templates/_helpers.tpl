{{/*
OPA chart — helper templates
*/}}

{{- define "opa.name" -}}
opa
{{- end }}

{{- define "opa.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "opa.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "opa.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opa.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
