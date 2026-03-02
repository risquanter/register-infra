{{/*
Expand the name of the chart.
*/}}
{{- define "register.name" -}}
{{- .Chart.Name }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "register.fullname" -}}
{{- printf "%s" .Chart.Name }}
{{- end }}

{{/*
Common labels applied to all resources in this chart.
*/}}
{{- define "register.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "register.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels used by Deployment and Service to match pods.
*/}}
{{- define "register.selectorLabels" -}}
app.kubernetes.io/name: {{ include "register.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
