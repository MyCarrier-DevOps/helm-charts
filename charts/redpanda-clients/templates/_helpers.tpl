{{/*
Fails the render on client ids or topic names that would break prefix isolation
or produce invalid resource names.
*/}}
{{- define "redpanda-clients.validate" -}}
{{- $seen := dict -}}
{{- range $c := .Values.clients -}}
  {{- $id := toString (default "" $c.id) -}}
  {{- if not (and (kindIs "string" $c.id) (regexMatch "^[a-z][a-z0-9]*$" $id)) -}}
    {{- fail (printf "invalid client id %q: start with a lowercase letter, then lowercase letters and digits only" $id) -}}
  {{- end -}}
  {{- if hasKey $seen $id -}}
    {{- fail (printf "duplicate client id %q" $id) -}}
  {{- end -}}
  {{- if has $id $.Values.cluster.reservedUsers -}}
    {{- fail (printf "client id %q is reserved: its User would take over that existing user and set its password from the client's secret" $id) -}}
  {{- end -}}
  {{- $_ := set $seen $id true -}}
  {{- range $k, $v := ($c.quota | default dict) -}}
    {{- if not (has $k (list "producerByteRate" "consumerByteRate")) -}}
      {{- fail (printf "unknown quota key %q for client %q: use producerByteRate or consumerByteRate" $k $id) -}}
    {{- end -}}
    {{- if or (not (or (kindIs "float64" $v) (kindIs "int64" $v) (kindIs "int" $v))) (le (float64 $v) 0.0) -}}
      {{- fail (printf "invalid %s %v for client %q: use a positive number of bytes per second, or leave it out for unlimited" $k $v $id) -}}
    {{- end -}}
  {{- end -}}
  {{- $seenTopics := dict -}}
  {{- range $t := $c.topics -}}
    {{- $name := toString (default "" $t.name) -}}
    {{- if not (regexMatch "^[a-z0-9]+(-[a-z0-9]+)*$" $name) -}}
      {{- fail (printf "invalid topic name %q for client %q: use lowercase letters, digits and dashes" $name $id) -}}
    {{- end -}}
    {{- if hasKey $seenTopics $name -}}
      {{- fail (printf "duplicate topic name %q for client %q" $name $id) -}}
    {{- end -}}
    {{- $_ := set $seenTopics $name true -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Standard labels for every resource the chart renders.
*/}}
{{- define "redpanda-clients.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}
