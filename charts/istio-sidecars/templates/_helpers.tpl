{{/*
Validation and normalisation for istio-sidecars.

istio-sidecars.model returns a JSON document:
  {"sharedHosts": [...], "featureHosts": [...],
   "entries": [{"name": "featureNN", "sidecar": bool, "extraHosts": [...]}]}

Strict mode (.Values.strict true): any bad input calls fail, naming the entry, list index or key.
Lenient mode (default): never fails; a bad entry is skipped, a bad dev block disables the dev
Sidecar, a bad featureNamespaces is an empty list. A bad NAME gives no dev host; a non-boolean
sidecar flag gives no feature Sidecar but keeps the host.
Every access is guarded with kindIs, so no chain is evaluated on an unchecked kind.
*/}}

{{/* Clean host list: returns JSON list of strings; fails in strict mode on a bad list. */}}
{{- define "istio-sidecars.hostList" -}}
{{- $key := .key -}}
{{- $in := .value -}}
{{- $out := list -}}
{{- if kindIs "slice" $in -}}
{{- range $i, $h := $in -}}
{{- if and (kindIs "string" $h) (ne $h "") -}}
{{- if not (has $h $out) -}}{{- $out = append $out $h -}}
{{- else if $.strict -}}
{{- fail (printf "istio-sidecars: %s index %d is a duplicate host %q" $key $i $h) -}}
{{- end -}}
{{- else if $.strict -}}
{{- fail (printf "istio-sidecars: %s index %d is not a non-empty string" $key $i) -}}
{{- end -}}
{{- end -}}
{{- if and $.strict (not $out) -}}
{{- fail (printf "istio-sidecars: %s is empty" $key) -}}
{{- end -}}
{{- else if $.strict -}}
{{- fail (printf "istio-sidecars: %s must be a list" $key) -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/* Dev switch, evaluated by the dev template only. Returns "true" or "false". Strict: fail on a bad dev block. */}}
{{- define "istio-sidecars.devEnabled" -}}
{{- $strict := eq (toString .Values.strict) "true" -}}
{{- $devEnabled := false -}}
{{- if kindIs "map" .Values.dev -}}
{{- if kindIs "bool" .Values.dev.enabled -}}
{{- $devEnabled = .Values.dev.enabled -}}
{{- else if $strict -}}
{{- fail "istio-sidecars: dev.enabled must be a boolean" -}}
{{- end -}}
{{- else if $strict -}}
{{- fail "istio-sidecars: dev must be a map with a boolean key enabled" -}}
{{- end -}}
{{- $devEnabled -}}
{{- end -}}

{{- define "istio-sidecars.model" -}}
{{- $strict := eq (toString .Values.strict) "true" -}}
{{- $reserved := list "dev" "preprod" "uat" "qa" "istio-system" "kube-system" "default" "monitoring" -}}
{{- $shared := include "istio-sidecars.hostList" (dict "key" "sharedHosts" "value" .Values.sharedHosts "strict" $strict) | fromJsonArray -}}
{{- $featureHosts := include "istio-sidecars.hostList" (dict "key" "featureHosts" "value" .Values.featureHosts "strict" $strict) | fromJsonArray -}}
{{- $list := list -}}
{{- if kindIs "slice" .Values.featureNamespaces -}}
{{- $list = .Values.featureNamespaces -}}
{{- else if $strict -}}
{{- fail "istio-sidecars: featureNamespaces must be a list" -}}
{{- end -}}
{{- $entries := list -}}
{{- $seen := list -}}
{{- range $i, $e := $list -}}
{{- if not (kindIs "map" $e) -}}
{{- if $strict -}}{{- fail (printf "istio-sidecars: featureNamespaces index %d is not a map (expected name: featureNN)" $i) -}}{{- end -}}
{{- else if not (and (hasKey $e "name") (kindIs "string" $e.name)) -}}
{{- if $strict -}}{{- fail (printf "istio-sidecars: featureNamespaces index %d: name is missing or not a string" $i) -}}{{- end -}}
{{- else -}}
{{- $name := $e.name -}}
{{- $valid := true -}}
{{- if has $name $reserved -}}
{{- $valid = false -}}
{{- if $strict -}}{{- fail (printf "istio-sidecars: featureNamespaces index %d: name %q is reserved" $i $name) -}}{{- end -}}
{{- else if not (regexMatch "^feature[0-9]{2}(-[a-z0-9]+)?$" $name) -}}
{{- $valid = false -}}
{{- if $strict -}}{{- fail (printf "istio-sidecars: featureNamespaces index %d: name %q does not match ^feature[0-9][0-9](-[a-z0-9]+)?$" $i $name) -}}{{- end -}}
{{- else if gt (len $name) 63 -}}
{{- $valid = false -}}
{{- if $strict -}}{{- fail (printf "istio-sidecars: featureNamespaces index %d: name %q is longer than 63 characters" $i $name) -}}{{- end -}}
{{- end -}}
{{- if $valid -}}
{{- if has $name $seen -}}
{{- if $strict -}}{{- fail (printf "istio-sidecars: featureNamespaces index %d: duplicate name %q" $i $name) -}}{{- end -}}
{{- else -}}
{{- $seen = append $seen $name -}}
{{- $sidecar := true -}}
{{- if hasKey $e "sidecar" -}}
{{- if kindIs "bool" $e.sidecar -}}
{{- $sidecar = $e.sidecar -}}
{{- else -}}
{{- $sidecar = false -}}
{{- if $strict -}}{{- fail (printf "istio-sidecars: featureNamespaces index %d: entry %q has a non-boolean sidecar flag" $i $name) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- $extra := list -}}
{{- if hasKey $e "extraHosts" -}}
{{- if kindIs "slice" $e.extraHosts -}}
{{- range $j, $h := $e.extraHosts -}}
{{- $ok := false -}}
{{- if kindIs "string" $h -}}
{{- $ok = and (regexMatch "^[a-z0-9.][-a-z0-9.]*/[^/]+$" $h) (ne $h "*/*") -}}
{{- end -}}
{{- if and $ok (not (has $h $featureHosts)) (not (has $h $extra)) -}}
{{- $extra = append $extra $h -}}
{{- else if $strict -}}
{{- fail (printf "istio-sidecars: featureNamespaces index %d: entry %q has an invalid, empty or duplicate extraHosts element at position %d" $i $name $j) -}}
{{- end -}}
{{- end -}}
{{- else if $strict -}}
{{- fail (printf "istio-sidecars: featureNamespaces index %d: entry %q has extraHosts that is not a list" $i $name) -}}
{{- end -}}
{{- end -}}
{{- $entries = append $entries (dict "name" $name "sidecar" $sidecar "extraHosts" $extra) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- dict "sharedHosts" $shared "featureHosts" $featureHosts "entries" $entries | toJson -}}
{{- end -}}
