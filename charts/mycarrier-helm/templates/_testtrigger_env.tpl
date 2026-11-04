{{/*
Environment variables of a test definition (testtrigger.env and testtrigger.testdefinitions[].env, AQA-81).
They reach TestEngine as TestEnvironmentVariables.EnvVars on every request the chart renders (helm.testtrigger.v1request).

Rules (index of the AQA-77 plans is the shared contract; the checks run in this order, the first failure wins):
  1. env is a map (null or absent means no env).
  2. at most 50 entries after the merge (shared overlaid by per-definition, key by key, per-definition wins).
  3. per variable, names sorted: invalid_name, protected_name, duplicate_name, invalid_value, control_character,
     value_too_large, vault_prefix_not_allowed.
  4. at most 16384 bytes per definition (sum of name and value), definition_too_large.
  5. at most 65536 bytes per HTTP request (all definitions of one v1 request), request_too_large.
The message names the variable, never the value: EnvVars: test definition "<name>": variable "<VAR>": <code>.
For too_many, definition_too_large, request_too_large and a non-map env the variable part is left out.

Keep in step with TestEngine.Worker/pkg/worker/protected_env.go (AQA-77 shared contract). The protected names and
prefixes below are a copy of TestEngine.Worker/pkg/worker/testdata/protected_env_names.json; .github/scripts/testdata/
protected_env_names.json holds the same bytes and .github/scripts/test_trigger_env.py checks every entry.
*/}}

{{/*
helm.testtrigger.envVarsForDefinition: the merged and validated EnvVars of one test definition, as a JSON object
(name to string value). Input: dict "shared" <testtrigger.env or nil> "definition" <testdefinitions item>.
The merge is two range/set loops and not Sprig merge: mergo would refill a null per-definition value from the shared map.
Values are YAML strings only (as Helm reads the YAML); nothing is converted.
*/}}
{{- define "helm.testtrigger.envVarsForDefinition" -}}
{{- $protectedEnvNames := list "ATTEMPT" "ATTEMPT_ID" "AUTOTEST_RESULTS_API_KEY" "AUTOTEST_RESULTS_API_URL" "BATCH_ID" "CORRELATION_ID" "JOB_NUMBER" "OTEL_RESOURCE_ATTRIBUTES" "PARTITION_ID" "PATH" "REQUEST_HEADERS" "RUN_KIND" "TEST_CATEGORY" "TOTAL_TEST_JOB_COUNT" "TRACEPARENT" }}
{{- $protectedEnvPrefixes := list "LD_" "VAULT_" }}
{{- $vaultPrefix := "QA/" }}
{{- $maxEntries := 50 }}
{{- $maxValueBytes := 4096 }}
{{- $maxDefinitionBytes := 16384 }}
{{- $definition := .definition }}
{{- $head := printf "EnvVars: test definition \"%s\"" $definition.name }}
{{- $merged := dict }}
{{- range $level := list .shared $definition.env }}
  {{- if not (kindIs "invalid" $level) }}
    {{- if not (kindIs "map" $level) }}
      {{- fail (printf "%s: invalid_value" $head) }}
    {{- end }}
    {{- range $name, $value := $level }}
      {{- $_ := set $merged $name $value }}
    {{- end }}
  {{- end }}
{{- end }}
{{- if gt (len $merged) $maxEntries }}
  {{- fail (printf "%s: too_many" $head) }}
{{- end }}
{{- $upperCount := dict }}
{{- range $name, $value := $merged }}
  {{- $upper := upper $name }}
  {{- $_ := set $upperCount $upper (add1 (int (get $upperCount $upper))) }}
{{- end }}
{{- $bytes := 0 }}
{{- range $name := keys $merged | sortAlpha }}
  {{- $value := get $merged $name }}
  {{- if or (not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $name)) (eq $name "true") (eq $name "false") }}
    {{- fail (printf "%s: variable \"%s\": invalid_name" $head $name) }}
  {{- end }}
  {{- $upperName := upper $name }}
  {{- $protected := has $upperName $protectedEnvNames }}
  {{- range $prefix := $protectedEnvPrefixes }}
    {{- if hasPrefix $prefix $upperName }}{{ $protected = true }}{{ end }}
  {{- end }}
  {{- if $protected }}
    {{- fail (printf "%s: variable \"%s\": protected_name" $head $name) }}
  {{- end }}
  {{- if gt (int (get $upperCount $upperName)) 1 }}
    {{- fail (printf "%s: variable \"%s\": duplicate_name" $head $name) }}
  {{- end }}
  {{- if not (kindIs "string" $value) }}
    {{- fail (printf "%s: variable \"%s\": invalid_value (quote the value as a YAML string)" $head $name) }}
  {{- end }}
  {{- if regexMatch "[[:cntrl:]]" $value }}
    {{- fail (printf "%s: variable \"%s\": control_character" $head $name) }}
  {{- end }}
  {{- if gt (len $value) $maxValueBytes }}
    {{- fail (printf "%s: variable \"%s\": value_too_large" $head $name) }}
  {{- end }}
  {{- range $part := slice (regexSplit "vault:" $value -1) 1 }}
    {{- $path := index (splitList "#" $part) 0 }}
    {{- if or (not (hasPrefix $vaultPrefix $part)) (has ".." (splitList "/" $path)) }}
      {{- fail (printf "%s: variable \"%s\": vault_prefix_not_allowed" $head $name) }}
    {{- end }}
  {{- end }}
  {{- $bytes = add $bytes (len $name) (len $value) }}
{{- end }}
{{- if gt $bytes $maxDefinitionBytes }}
  {{- fail (printf "%s: definition_too_large" $head) }}
{{- end }}
{{- $merged | toJson }}
{{- end }}

{{/*
helm.testtrigger.envVars: the EnvVars of every test definition of one application, as {"byDefinition": [{...}, ...]},
in testtrigger.testdefinitions order (an empty object where a definition has none).
Input: dict "application" <application map> "enforceRequestCap" <bool>. With enforceRequestCap (the v1 path: all
definitions are one HTTP request) the raw bytes of all definitions are added up, and the first definition that takes
the total past 65536 fails with request_too_large. The legacy path sends one request per definition, so the
per-definition cap already bounds it and it passes false.
*/}}
{{- define "helm.testtrigger.envVars" -}}
{{- $maxRequestBytes := 65536 }}
{{- $shared := dig "testtrigger" "env" nil .application }}
{{- $total := 0 }}
{{- $byDefinition := list }}
{{- range $definition := dig "testtrigger" "testdefinitions" list .application }}
  {{- $env := include "helm.testtrigger.envVarsForDefinition" (dict "shared" $shared "definition" $definition) | fromJson }}
  {{- range $name, $value := $env }}
    {{- $total = add $total (len $name) (len $value) }}
  {{- end }}
  {{- if and $.enforceRequestCap (gt $total $maxRequestBytes) }}
    {{- fail (printf "EnvVars: test definition \"%s\": request_too_large" $definition.name) }}
  {{- end }}
  {{- $byDefinition = append $byDefinition $env }}
{{- end }}
{{- dict "byDefinition" $byDefinition | toJson }}
{{- end }}
