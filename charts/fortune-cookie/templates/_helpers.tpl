{{/*
Shared bits used by more than one template.
*/}}

{{/* The release name, trimmed to what Kubernetes accepts for a name. */}}
{{- define "fortune-cookie.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels every object in the chart carries. */}}
{{- define "fortune-cookie.labels" -}}
app.kubernetes.io/part-of: cookie-fortune
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Builds an image reference for one service.
Called as: include "fortune-cookie.image" (dict "root" $ "service" "backend")
*/}}
{{- define "fortune-cookie.image" -}}
{{- $img := .root.Values.image -}}
{{- printf "%s/%s/%s-%s:%s" $img.registry $img.namespace $img.base .service $img.tag -}}
{{- end -}}
