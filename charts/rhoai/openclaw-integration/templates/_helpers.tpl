{{- define "openclaw-mlflow-integration.labels" -}}
app.kubernetes.io/name: openclaw-mlflow-integration
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openclaw-in-openshell
{{- end }}
