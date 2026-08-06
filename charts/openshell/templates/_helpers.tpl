{{- define "openclaw-openshell.fullname" -}}
{{ .Release.Name }}
{{- end }}

{{- define "openclaw-openshell.sandboxSA" -}}
{{ .Values.openshift.scc.serviceAccount | default (printf "%s-sandbox" .Release.Name) }}
{{- end }}

{{- define "openclaw-openshell.labels" -}}
app.kubernetes.io/name: openshell
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openclaw-in-openshell
app.kubernetes.io/component: openshell
{{- end }}
