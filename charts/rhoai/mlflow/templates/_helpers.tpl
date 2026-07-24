{{- define "mlflow.labels" -}}
app.kubernetes.io/name: mlflow
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
