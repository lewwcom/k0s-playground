{{/* Usage: include "k0s.labels" (dict "name" "myapp" "project" "myproject") */}}
{{- define "k0s.labels" -}}
argocd.k0s/name: {{ $.name }}
argocd.k0s/project: {{ $.project }}
{{- end -}}
