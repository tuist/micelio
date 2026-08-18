{{- define "micelio.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "micelio.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "micelio.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "micelio.labels" -}}
helm.sh/chart: {{ include "micelio.chart" . }}
{{ include "micelio.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "micelio.selectorLabels" -}}
app.kubernetes.io/name: {{ include "micelio.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "micelio.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "micelio.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "micelio.headlessServiceName" -}}
{{- printf "%s-headless" (include "micelio.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Secrets are generated once and then preserved across upgrades by reading the
existing Secret back. Regenerating the release cookie on every `helm upgrade`
would partition the cluster; regenerating the admin token would lock out
whatever is holding the old one.
*/}}
{{- define "micelio.releaseCookie" -}}
{{- if .Values.releaseCookie }}
{{- .Values.releaseCookie }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-secrets" (include "micelio.fullname" .)) }}
{{- if and $existing $existing.data (index $existing.data "RELEASE_COOKIE") }}
{{- index $existing.data "RELEASE_COOKIE" | b64dec }}
{{- else }}
{{- randAlphaNum 48 }}
{{- end }}
{{- end }}
{{- end }}

{{- define "micelio.adminToken" -}}
{{- if .Values.adminToken }}
{{- .Values.adminToken }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-secrets" (include "micelio.fullname" .)) }}
{{- if and $existing $existing.data (index $existing.data "MICELIO_ADMIN_TOKEN") }}
{{- index $existing.data "MICELIO_ADMIN_TOKEN" | b64dec }}
{{- else }}
{{- randAlphaNum 48 }}
{{- end }}
{{- end }}
{{- end }}
