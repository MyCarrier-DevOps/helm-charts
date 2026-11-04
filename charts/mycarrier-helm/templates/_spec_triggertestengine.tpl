{{- define "helm.specs.testenginehook" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $baseName := include "helm.basename" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $chartDefaults := $ctx.chartDefaults -}}
{{- $resourceDefaults := $chartDefaults.resources.testTrigger -}}
{{- $imagePullSecret := $chartDefaults.imagePullSecret -}}
{{- $restartPolicy := $chartDefaults.restartPolicy -}}
{{- $httpPort := 8080 }}
{{- $environment := $.Values.environment.name }}
{{- $gitBranch := $.Values.global.gitbranch}}
{{- $stackname := $.Values.global.appStack }}
{{- $correlationId := $.Values.global.correlationId }}
{{- if not (dig "service" "ports" false .application) }}
{{- range $key, $value := .application.ports }}
  {{- if eq ($key | lower) "http" }}
    {{- $httpPort = $value }}
  {{- end }}
{{- end }}
{{- end }}
{{- $imageTag :=  .application.image.tag }}
{{- $enableV1 := dig "testtrigger" "enableV1" true .application }}
{{- $argoInst := $.Values.global.argoEventsInstance | default "argo-events" }}
{{- $urlKey := ternary "dev_url" "url" (eq $argoInst "argo-events-test") }}
{{- $apiPath := ternary "testengine/api/v1" "testengine/api" $enableV1 }}
{{- $defaultWebhookUrl := $.Values.global.testengineWebhookUrl | default (printf "vault:DevOps/data/%s#%s" $apiPath $urlKey) }}
{{- if dig "testtrigger" false .application }}
ttlSecondsAfterFinished: {{ dig "testtrigger" "ttlSecondsAfterFinished" 3600 .application }}
activeDeadlineSeconds: {{ dig "testtrigger" "activeDeadlineSeconds" 300 .application }}
backoffLimit: {{ dig "testtrigger" "backoffLimit" 0 .application }}
{{- /* The pod keeps the application's standard labels except its identity: app.kubernetes.io/name and app become
       <fullName>-trigger. With the application's own values they matched its Service selector, so the trigger pod
       (no port, no readiness probe) could take the Service's traffic while it ran, and its PDB and HPA counted it. */}}
{{- $podLabels := include "helm.labels.standard" . | fromYaml }}
{{- $triggerName := printf "%s-trigger" (include "helm.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- $_ := set $podLabels "app.kubernetes.io/name" $triggerName }}
{{- $_ := set $podLabels "app" $triggerName }}
{{- /* Legacy path (enableV1 false): one request per definition, all in the one command[2] string. A script over 100 KiB
       fails when some definition has EnvVars (a service without env can never newly fail). The 512 bytes are the fixed
       text around the curl blocks (set -u, failed=0, the closing if and exit 0), which holds no values; the real
       length is checked, so filters, tolerations, nodeAffinity and podResources count too. Nothing prints before this. */}}
{{- $legacy := "" }}
{{- if not $enableV1 }}
  {{- $env := include "helm.testtrigger.envVars" (dict "application" .application "enforceRequestCap" false) | fromJson }}
  {{- $legacy = include "helm.testtrigger.legacyCurls" (dict "ctx" . "env" $env) }}
  {{- if gt (len $legacy) 101888 }}
    {{- $last := include "helm.testtrigger.lastEnvDefinition" (dict "application" .application "env" $env) }}
    {{- if $last }}
      {{- fail (printf "EnvVars: test definition \"%s\": request_too_large" $last) }}
    {{- end }}
  {{- end }}
{{- end }}
template:
  metadata:
    labels:
      {{ include "helm.labels.dependencies" . | indent 6 | trim }}
      {{- toYaml $podLabels | nindent 6 }}
  spec:
    {{ include "helm.podSecurityContext" . | indent 4 | trim }}
    serviceAccountName: default
    imagePullSecrets:
      - name: {{ dig "testtrigger" "imagePullSecret" $imagePullSecret .application | quote }}
    restartPolicy: {{ dig "testtrigger" "restartPolicy" $restartPolicy .application | quote  }}
    containers:
      - image: "alpine/curl:8.17.0"
        imagePullPolicy: {{ dig "testtrigger" "imagePullPolicy" "IfNotPresent" .application | quote }}
        name: testtrigger
        env:
        - name: TESTENGINE_APIKEY
          value: {{ dig "testtrigger" "apikey" "" .application | quote }}
        - name: TESTENGINEHOOK_URL
          value: {{ $defaultWebhookUrl | quote }}
        resources:
          {{- if .application.testtrigger.resources }}
          {{ toYaml .application.testtrigger.resources | indent 10 | trim }}
          {{- else }}
          requests:
            memory: {{ quote $resourceDefaults.requests.memory }}
            cpu: {{ quote $resourceDefaults.requests.cpu }}
          limits:
            memory: {{ quote $resourceDefaults.limits.memory }}
            cpu: {{ quote $resourceDefaults.limits.cpu }}
          {{- end }}
        command:
          - /bin/sh
          - -c
          - |
            set -u
            failed=0
          {{- if $enableV1 }}
            curl -sS --fail-with-body -w '\nTestEngine HTTP status: %{http_code}\n' \
            --max-time 60 \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: $TESTENGINE_APIKEY" \
            -d '{{ include "helm.testtrigger.commandSafeJson" (dict "json" (include "helm.testtrigger.v1request" . | indent 12 | trimPrefix "            ") "application" .application "argoTemplate" false) }}' "$TESTENGINEHOOK_URL" || {
              rc=$?
              echo "ERROR: TestEngine trigger failed (curl exit $rc)" >&2
              failed=$((failed+1))
            }
          {{- else }}
          {{- $legacy }}
          {{- end }}
            if [ "$failed" -gt 0 ]; then
              echo "ERROR: $failed TestEngine trigger call(s) failed — see above; exiting 0 to avoid ArgoCD sync retries" >&2
            fi
            exit 0
        {{ include "helm.containerSecurityContext" . | indent 8 | trim }}
{{- end }}
{{- end }}

{{/*
helm.testtrigger.legacyCurls: the curl commands of the legacy PostSync hook (testtrigger.enableV1 false), one per test
definition, as the text that goes into the hook's script. Takes dict "ctx" <the hook's context, with .application> and
"env" <the result of helm.testtrigger.envVars, decoded>. Each definition is its own HTTP request, so there is no cap
across definitions; the caller checks the length of the whole script. EnvVars is the last key of
TestEnvironmentVariables and is left out when the definition has none. Quotes and dollars in it are escaped like the v1
hook body (helm.testtrigger.commandSafeJson); the other fields are printed as they always were.
*/}}
{{- define "helm.testtrigger.legacyCurls" -}}
{{- $root := .ctx }}
{{- $env := .env }}
{{- $application := $root.application }}
{{- $fullName := include "helm.fullname" $root }}
{{- $baseName := include "helm.basename" $root }}
{{- $namespace := include "helm.namespace" $root }}
{{- $httpPort := 8080 }}
{{- $gitBranch := $root.Values.global.gitbranch }}
{{- $stackname := $root.Values.global.appStack }}
{{- $correlationId := $root.Values.global.correlationId }}
{{- if not (dig "service" "ports" false $application) }}
{{- range $key, $value := $application.ports }}
  {{- if eq ($key | lower) "http" }}
    {{- $httpPort = $value }}
  {{- end }}
{{- end }}
{{- end }}
{{- $imageTag := $application.image.tag }}
{{- range $index, $definition := dig "testtrigger" "testdefinitions" list $application }}
          {{- $serviceAddress := .serviceAddress | default (printf "http://%s.%s.svc.cluster.local:%v" $fullName $namespace $httpPort) }}
          {{- $defaultTolerations := list (dict "key" "kubernetes.azure.com/scalesetpriority" "operator" "Equal" "value" "spot" "effect" "NoSchedule") }}
          {{- $tolerations := $defaultTolerations }}
          {{- if hasKey . "tolerations" }}
            {{- $tolerations = .tolerations }}
          {{- end }}
          {{- $nodeAffinity := .nodeAffinity | default list }}
          {{- $useDefaultNodeAffinity := "false" }}
          {{- if hasKey . "useDefaultNodeAffinity" }}
            {{- $useDefaultNodeAffinity = printf "%v" .useDefaultNodeAffinity }}
          {{- end }}
          {{- $legacyMode := "false" }}
          {{- if hasKey . "legacyMode" }}
            {{- $legacyMode = printf "%v" .legacyMode }}
          {{- end }}
          {{- $spreadAcrossNodes := "true" }}
          {{- if hasKey . "spreadAcrossNodes" }}
            {{- $spreadAcrossNodes = printf "%v" .spreadAcrossNodes }}
          {{- end }}
          {{- $hardenedSecurityContext := true }}
          {{- if and (hasKey . "hardenedSecurityContext") (eq (lower (printf "%v" .hardenedSecurityContext)) "false") }}
            {{- $hardenedSecurityContext = false }}
          {{- end }}
          {{- $defaultPodResources := dict "limits" (dict "cpu" "2000m" "memory" "4Gi") "requests" (dict "cpu" "250m" "memory" "1Gi") }}
          {{- $podResources := .podResources | default $defaultPodResources }}
          {{- include "helm.testtrigger.validateResultsApi" (dict "def" . "fullName" $fullName) }}
          {{- $resultsApiKey := .resultsApiKey | default "" }}
          {{- $resultsApiUrl := .resultsApiUrl | default "" }}
            curl -sS --fail-with-body -w '\nTestEngine HTTP status: %{http_code}\n' \
            --max-time 60 \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: $TESTENGINE_APIKEY" \
            -d '{
              "IsMonolith": false,
              "TestName": "{{ .name }}",
              "StackName": "{{ $stackname }}",
              "ContainerImage": "{{ .containerImage }}",
              "ContainerTag": "{{ .containerTag }}",
              "HardenedSecurityContext": {{ $hardenedSecurityContext }},
              "TestFilters": {{ .filters | toJson }},
              "Tolerations": {{ $tolerations | toJson }},
              "NodeAffinity": {{ $nodeAffinity | toJson }},
              "UseDefaultNodeAffinity": "{{ $useDefaultNodeAffinity }}",
              "SpreadAcrossNodes": "{{ $spreadAcrossNodes }}",
              "PodResources": {{ $podResources | toJson }},
              "TestEnvironmentVariables": {
                  "EnvironmentName": "{{ $namespace }}",
                  "ReleaseId": "{{ $imageTag }}",
                  "SecretId": "{{ .secretId }}",
                  "ServiceAddress": {{ $serviceAddress | quote }},
                  "ReleaseDefinitionName": "{{ .releaseDefinitionName | default $baseName }}",
                  "BranchName": "{{ $gitBranch }}",
                  "AdditionalEnvVars": "{{ .additionalEnvVars}}",
                  "CorrelationId": "{{ $correlationId }}",
                  "LegacyMode": "{{ $legacyMode }}"{{- if $resultsApiUrl }},
                  "ResultsApiUrl": {{ $resultsApiUrl | quote }}{{- end }}{{- if $resultsApiKey }},
                  "ResultsApiKey": {{ $resultsApiKey | quote }}{{- end }}{{- with index $env.byDefinition $index }},
                  "EnvVars": {{ include "helm.testtrigger.commandSafeJson" (dict "json" (toJson .) "application" $application "argoTemplate" false) }}{{- end }}
                }
              }' "$TESTENGINEHOOK_URL" || {
              rc=$?
              echo "ERROR: TestEngine trigger failed for "{{ .name | squote }}" (curl exit $rc)" >&2
              failed=$((failed+1))
            }
{{- end }}
{{- end }}

{{/*
The TestEngine v1 request for an application, as indented JSON: {"Tests": [...]}, one entry per
testtrigger.testdefinitions item, with no SlipStep, so TestEngine bookends the environment's tests step
(prod_tests in prod) for the run. Two templates send it, so they cannot drift apart: the PostSync hook
(helm.specs.testenginehook, with testtrigger.enableV1) and, for a prod canary Rollout, the <fullName>-prod-tests
ConfigMap that the release's rollout-watch posts after promotion (DEVOPS-319, Tech Spec D7; triggertestengine.yaml).
Takes the application context. Every test definition's results API settings are checked here, and so is its env: every
test definition's EnvVars are merged and checked here (helm.testtrigger.envVars); the v1 request is one HTTP request,
so the 64 KiB cap covers all definitions.
A third caller, the canary tests template (helm.canary.tests.request, DEVOPS-515), adds .testRun to the context, a
dict whose keys override the request and are absent for the other two callers: serviceAddresses (ServiceAddress, one
entry per test definition, in order), tolerations (Tolerations of every definition, also when empty), and runKind,
slipStep and requestHeaders (RunKind, SlipStep and RequestHeaders inside TestEnvironmentVariables, set only when not
empty), and correlationId (CorrelationId, a string).
*/}}
{{- define "helm.testtrigger.v1request" -}}
{{- $run := .testRun | default dict }}
{{- $fullName := include "helm.fullname" . }}
{{- $baseName := include "helm.basename" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $httpPort := 8080 }}
{{- $gitBranch := .Values.global.gitbranch }}
{{- $stackname := .Values.global.appStack }}
{{- $correlationId := .Values.global.correlationId }}
{{- if hasKey $run "correlationId" }}{{ $correlationId = $run.correlationId }}{{ end }}
{{- if not (dig "service" "ports" false .application) }}
{{- range $key, $value := .application.ports }}
  {{- if eq ($key | lower) "http" }}
    {{- $httpPort = $value }}
  {{- end }}
{{- end }}
{{- end }}
{{- $imageTag := .application.image.tag }}
{{- $env := include "helm.testtrigger.envVars" (dict "application" .application "enforceRequestCap" true) | fromJson }}
{{- $tests := list }}
{{- range $index, $definition := dig "testtrigger" "testdefinitions" list .application }}
{{- $serviceAddress := .serviceAddress | default (printf "http://%s.%s.svc.cluster.local:%v" $fullName $namespace $httpPort) }}
{{- with $run.serviceAddresses }}{{ $serviceAddress = index . $index }}{{ end }}
{{- $defaultTolerations := list (dict "key" "kubernetes.azure.com/scalesetpriority" "operator" "Equal" "value" "spot" "effect" "NoSchedule") }}
{{- $tolerations := $defaultTolerations }}
{{- if hasKey . "tolerations" }}
  {{- $tolerations = .tolerations }}
{{- end }}
{{- if hasKey $run "tolerations" }}
  {{- $tolerations = $run.tolerations }}
{{- end }}
{{- $nodeAffinity := .nodeAffinity | default list }}
{{- $useDefaultNodeAffinity := "false" }}
{{- if hasKey . "useDefaultNodeAffinity" }}
  {{- $useDefaultNodeAffinity = printf "%v" .useDefaultNodeAffinity }}
{{- end }}
{{- $legacyMode := "false" }}
{{- if hasKey . "legacyMode" }}
  {{- $legacyMode = printf "%v" .legacyMode }}
{{- end }}
{{- $spreadAcrossNodes := "true" }}
{{- if hasKey . "spreadAcrossNodes" }}
  {{- $spreadAcrossNodes = printf "%v" .spreadAcrossNodes }}
{{- end }}
{{- $hardenedSecurityContext := true }}
{{- if and (hasKey . "hardenedSecurityContext") (eq (lower (printf "%v" .hardenedSecurityContext)) "false") }}
  {{- $hardenedSecurityContext = false }}
{{- end }}
{{- $defaultPodResources := dict "limits" (dict "cpu" "2000m" "memory" "4Gi") "requests" (dict "cpu" "250m" "memory" "1Gi") }}
{{- $podResources := .podResources | default $defaultPodResources }}
{{- include "helm.testtrigger.validateResultsApi" (dict "def" . "fullName" $fullName) }}
{{- $resultsApiKey := .resultsApiKey | default "" }}
{{- $resultsApiUrl := .resultsApiUrl | default "" }}
{{- $testEnv := dict "EnvironmentName" $namespace "ReleaseId" $imageTag "SecretId" (.secretId | default "") "ServiceAddress" $serviceAddress "ReleaseDefinitionName" (.releaseDefinitionName | default $baseName) "BranchName" $gitBranch "AdditionalEnvVars" (.additionalEnvVars | default "") "CorrelationId" $correlationId "LegacyMode" $legacyMode }}
{{- if $resultsApiUrl }}{{- $_ := set $testEnv "ResultsApiUrl" $resultsApiUrl }}{{- end }}
{{- if $resultsApiKey }}{{- $_ := set $testEnv "ResultsApiKey" $resultsApiKey }}{{- end }}
{{- with $run.runKind }}{{- $_ := set $testEnv "RunKind" . }}{{- end }}
{{- with $run.slipStep }}{{- $_ := set $testEnv "SlipStep" . }}{{- end }}
{{- with $run.requestHeaders }}{{- $_ := set $testEnv "RequestHeaders" . }}{{- end }}
{{- with index $env.byDefinition $index }}{{- $_ := set $testEnv "EnvVars" . }}{{- end }}
{{- $test := dict "IsMonolith" false "TestName" .name "StackName" $stackname "ContainerImage" (.containerImage | default "") "ContainerTag" (.containerTag | default "") "HardenedSecurityContext" $hardenedSecurityContext "TestFilters" .filters "Tolerations" $tolerations "NodeAffinity" $nodeAffinity "UseDefaultNodeAffinity" $useDefaultNodeAffinity "SpreadAcrossNodes" $spreadAcrossNodes "PodResources" $podResources "TestEnvironmentVariables" $testEnv }}
{{- $tests = append $tests $test }}
{{- end }}
{{- dict "Tests" $tests | toPrettyJson }}
{{- end }}

{{/*
helm.testtrigger.lastEnvDefinition: the name of the last test definition that has EnvVars, or "" when none has. Takes dict
"application" <application map> "env" <the result of helm.testtrigger.envVars, decoded>. Names the definition in the
request_too_large errors of the script and body size checks.
*/}}
{{- define "helm.testtrigger.lastEnvDefinition" -}}
{{- $last := "" }}
{{- range $index, $definition := dig "testtrigger" "testdefinitions" list .application }}
  {{- if index $.env.byDefinition $index }}{{- $last = $definition.name }}{{- end }}
{{- end }}
{{- $last }}
{{- end }}

{{/*
helm.testtrigger.commandSafeJson: a JSON request body made safe to paste where something other than the receiver reads it
first: the PostSync hook's -d '...' (shell, then kubelet) and the canary Job's TESTS_REQUEST env value (kubelet, and Argo
Rollouts for the AnalysisTemplate). The body stays valid JSON that decodes to the same request. The ConfigMap body
(request.json) is read by nobody on the way, so it is not passed through here.
Input: dict "json" <string> "application" <application map> "argoTemplate" <bool>. Output: the escaped string.
  1. ' becomes the six characters \u0027, the JSON escape of a single quote: without it any ' in any string (a filter, a
     service address, an env value) ends the shell quote of -d '...' and the rest runs as shell.
  2. $ becomes $$. Kubernetes expands $(NAME) in command and in env[].value, and turns $$ back into $ without expanding
     it; so a value such as $(TESTENGINE_APIKEY) arrives literally instead of as the key's vault: reference, which would
     get past the QA/ check.
  3. Only with argoTemplate (the canary request sits inside an AnalysisTemplate metric): {{ becomes {\u007b. Argo
     Rollouts (ResolveMetricArgs: it marshals the whole metric, Job spec included, and substitutes {{...}} over that text)
     fails the AnalysisRun on an unknown tag or an unclosed {{, and replaces {{args.<name>}}. In JSON a { outside a string
     is followed by " or }, so {{ occurs only inside strings, where the escape decodes to the same text.
The order does not matter: no output of one step contains the input of another.
Size: when at least one test definition has a non-empty EnvVars (so a service without env can never newly fail), an
escaped body over 102400 bytes (100 KiB) fails with request_too_large, naming the last definition that has EnvVars. The
limit is the Linux limit of 128 KiB for one command-line string, with room for the rest of the script (in the canary it
bounds the env value the same way).
*/}}
{{- define "helm.testtrigger.commandSafeJson" -}}
{{- $out := .json | replace "'" "\\u0027" | replace "$" "$$" }}
{{- if .argoTemplate }}
  {{- $out = $out | replace "{{" "{\\u007b" }}
{{- end }}
{{- if gt (len $out) 102400 }}
  {{- $env := include "helm.testtrigger.envVars" (dict "application" .application "enforceRequestCap" true) | fromJson }}
  {{- $last := include "helm.testtrigger.lastEnvDefinition" (dict "application" .application "env" $env) }}
  {{- if $last }}
    {{- fail (printf "EnvVars: test definition \"%s\": request_too_large" $last) }}
  {{- end }}
{{- end }}
{{- $out }}
{{- end }}

{{/*
Checks a test definition's results API settings, for both the v1 and the legacy path: the key and the URL
go together, and the key is a whole-value vault reference. The error names the field, never the value, so
a literal key does not reach the render log; that is why the key is not checked in values.schema.json.
The vault reference pattern is also the vault branch of the resultsApiUrl pattern in values.schema.json:
change both together.
*/}}
{{- define "helm.testtrigger.validateResultsApi" -}}
{{- $def := .def }}
{{- if and $def.resultsApiKey (not (regexMatch "^vault:[A-Za-z0-9_./-]+#[A-Za-z0-9_.-]+(#[0-9]+)?$" $def.resultsApiKey)) }}
  {{- fail (printf "test definition '%s' of '%s': resultsApiKey must be a vault reference, never the key itself" $def.name .fullName) }}
{{- end }}
{{- if ne (empty $def.resultsApiUrl) (empty $def.resultsApiKey) }}
  {{- fail (printf "test definition '%s' of '%s': resultsApiKey and resultsApiUrl go together; set both or neither, since the test container uploads results only when both are set" $def.name .fullName) }}
{{- end }}
{{- end }}
