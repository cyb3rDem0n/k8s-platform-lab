{{/*
Funzioni riutilizzabili ("named template"). Si richiamano con include; il trattino in {{- e -}}
elimina gli spazi bianchi a sinistra/destra, fondamentale per produrre YAML indentato correttamente.
*/}}

{{/* Nome del chart, eventualmente sovrascritto. I nomi Kubernetes sono limitati a 63 caratteri. */}}
{{- define "hello.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Prefisso dei nomi delle risorse. Con release "hello" e chart "hello" il risultato è "hello"
(non "hello-hello"): le risorse si chiamano hello-backend e hello-frontend.
*/}}
{{- define "hello.fullname" -}}
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

{{- define "hello.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Nome di un componente: hello.componentName (dict "ctx" . "component" "backend") -> hello-backend */}}
{{- define "hello.componentName" -}}
{{- printf "%s-%s" (include "hello.fullname" .ctx) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Etichette di selezione: IMMUTABILI nei Deployment, quindi poche e stabili (niente versione!). */}}
{{- define "hello.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hello.componentName" . }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end }}

{{/* Etichette complete, per i metadata di tutte le risorse. */}}
{{- define "hello.labels" -}}
helm.sh/chart: {{ include "hello.chart" .ctx }}
{{ include "hello.selectorLabels" . }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: k8s-platform-lab
{{- end }}

{{/* Riferimento completo a un'immagine: registry/repository:tag, con appVersion come default. */}}
{{- define "hello.image" -}}
{{- printf "%s/%s:%s" .ctx.Values.imageRegistry .image.repository (default .ctx.Chart.AppVersion .image.tag) }}
{{- end }}
