{{/*
Irmin chart — helper templates.
Follows the same pattern as OPA and register charts.
*/}}

{{- define "irmin.name" -}}
irmin
{{- end }}

{{- define "irmin.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "irmin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "irmin.selectorLabels" -}}
app.kubernetes.io/name: {{ include "irmin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
