{{- define "guardrails.name" -}}
{{- .Values.guardrails.name | default "nemo-guardrails" }}
{{- end }}

{{- define "guardrails.namespace" -}}
{{- .Values.guardrails.namespace | default "openshell2" }}
{{- end }}

{{- define "guardrails.labels" -}}
app.kubernetes.io/name: nemo-guardrails
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: open-claw-in-openshell
{{- end }}
