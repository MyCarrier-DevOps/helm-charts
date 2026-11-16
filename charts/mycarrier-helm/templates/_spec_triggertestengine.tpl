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
{{- $environment := $.Values.environment.name }}
{{- $gitBranch := $.Values.global.gitbranch}}
{{- $stackname := $.Values.global.appStack }}
{{- $correlationId := $.Values.global.correlationId }}
{{- $imageTag :=  .application.image.tag }}
{{- $enableV1 := dig "testtrigger" "enableV1" true .application }}
{{- $argoInst := $.Values.global.argoEventsInstance | default "argo-events" }}
{{- $urlKey := ternary "dev_url" "url" (eq $argoInst "argo-events-test") }}
{{- $apiPath := ternary "testengine/api/v1" "testengine/api" $enableV1 }}
{{- $defaultWebhookUrl := $.Values.global.testengineWebhookUrl | default (printf "vault:DevOps/data/%s#%s" $apiPath $urlKey) }}
{{- if dig "testtrigger" false .application }}
{{- $triggerVersion := include "helm.testtrigger.version" . }}
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
  {{- /* $legacy still carries the 12-space block-scalar indentation that YAML strips; count the text that reaches
         command[2]. */}}
  {{- if gt (len (regexReplaceAll "(?m)^ {12}" $legacy "")) 101888 }}
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
          {{- if eq $triggerVersion "v2" }}
          {{- include "helm.testtrigger.v2curls" . }}
          {{- else if $enableV1 }}
            curl -sS --fail-with-body -w '\nTestEngine HTTP status: %{http_code}\n' \
            --max-time 60 \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: $TESTENGINE_APIKEY" \
            -d '{{ include "helm.testtrigger.commandSafeJson" (dict "json" (include "helm.testtrigger.v1request" .) "application" .application "argoTemplate" false) | indent 12 | trimPrefix "            " }}' "$TESTENGINEHOOK_URL" || {
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
helm.testtrigger.httpServicePort: the port of the application's http Service, the one a test calls when its definition
sets no serviceAddress. Takes the application map. It is the Service port that helm.canary.previewPort finds for the
http port (ports.http, 8080 when unset): the service.ports entry named http, else the one whose targetPort is ports.http,
else ports.http itself; the container port does not have to equal it. When the Service exposes none, ports.http.
*/}}
{{- define "helm.testtrigger.httpServicePort" -}}
{{- $port := 8080 }}
{{- range $key, $value := .ports }}
  {{- if eq ($key | lower) "http" }}{{- $port = $value }}{{- end }}
{{- end }}
{{- include "helm.canary.previewPort" (dict "application" . "port" $port) | default $port }}
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
{{- $httpPort := include "helm.testtrigger.httpServicePort" $application }}
{{- $gitBranch := $root.Values.global.gitbranch }}
{{- $stackname := $root.Values.global.appStack }}
{{- $correlationId := $root.Values.global.correlationId }}
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
{{- $httpPort := include "helm.testtrigger.httpServicePort" .application }}
{{- $gitBranch := .Values.global.gitbranch }}
{{- $stackname := .Values.global.appStack }}
{{- $correlationId := .Values.global.correlationId }}
{{- if hasKey $run "correlationId" }}{{ $correlationId = $run.correlationId }}{{ end }}
{{- $imageTag := .application.image.tag }}
{{- $env := include "helm.testtrigger.envVars" (dict "application" .application "enforceRequestCap" true) | fromJson }}
{{- $tests := list }}
{{- range $index, $definition := dig "testtrigger" "testdefinitions" list .application }}
{{- if and (not $.v2Build) (include "helm.testtrigger.hasV2Fields" .) }}
  {{- fail (printf "test definition '%s' of '%s': testEnvironmentTag, testTags and multiRun go to TestEngine's v2 trigger, and this request is a v1 request, which would send no filter and run every test in the image. Use filters here" (toString .name) $fullName) }}
{{- end }}
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
Input: dict "json" <string> "application" <application map> "argoTemplate" <bool> "encodeVaultInline" <bool, optional>.
Output: the escaped string.
  1. ' becomes the six characters \u0027, the JSON escape of a single quote: without it any ' in any string (a filter, a
     service address, an env value) ends the shell quote of -d '...' and the rest runs as shell.
  2. $ becomes $$. Kubernetes expands $(NAME) in command and in env[].value, and turns $$ back into $ without expanding
     it; so a value such as $(TESTENGINE_APIKEY) arrives literally instead of as the key's vault: reference, which would
     get past the QA/ check.
  3. Only with argoTemplate (the canary request sits inside an AnalysisTemplate metric): {{ becomes {\u007b. Argo
     Rollouts (ResolveMetricArgs: it marshals the whole metric, Job spec included, and substitutes {{...}} over that text)
     fails the AnalysisRun on an unknown tag or an unclosed {{, and replaces {{args.<name>}}. In JSON a { outside a string
     is followed by " or }, so {{ occurs only inside strings, where the escape decodes to the same text.
  4. Only with encodeVaultInline (the canary: TESTS_REQUEST is an env value of a pod that vault-env wraps, and vault-env
     resolves an inline ${vault:...} in any env value): ${ becomes $\u007b, which JSON decodes back to ${ and the
     Bank-Vaults inline pattern no longer matches. It runs before step 2, so the $ of the escape becomes $$ and kubelet
     turns it back into $. The hook paths run no vault-env on the body and leave it out.
Steps 1 to 3 do not depend on the order: no output of one step contains the input of another.
Size: when at least one test definition has a non-empty EnvVars (so a service without env can never newly fail), an
escaped body over 102400 bytes (100 KiB) fails with request_too_large, naming the last definition that has EnvVars. The
limit is the Linux limit of 128 KiB for one command-line string, with room for the rest of the script (in the canary it
bounds the env value the same way).
*/}}
{{- define "helm.testtrigger.commandSafeJson" -}}
{{- $out := .json | replace "'" "\\u0027" }}
{{- if .encodeVaultInline }}
  {{- $out = $out | replace "${" "$\\u007b" }}
{{- end }}
{{- $out = $out | replace "$" "$$" }}
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

{{/*
helm.testtrigger.hasV2Fields: "true" when a test definition sets a v2 field with a value (testEnvironmentTag not empty,
testTags not empty, or multiRun true), else "". Takes the test definition. Presence is by value, as on TestEngine's
/v2/trigger: testEnvironmentTag "", testTags [] and multiRun false read as absent.
*/}}
{{- define "helm.testtrigger.hasV2Fields" -}}
{{- if or (not (empty .testEnvironmentTag)) (not (empty .testTags)) (eq (toString .multiRun) "true") }}true{{ end }}
{{- end }}

{{/*
helm.testtrigger.version (AQA-38): the TestEngine trigger an application's test definitions go to, "v1" or "v2", after
checking their v2 fields. Takes the application context. A definition with filters, or with neither filters nor a tag
(it runs every test), goes to v1; a definition with testEnvironmentTag goes to v2 (TestEngine's /v2/trigger,
MC.TestEngine docs/V2_TRIGGER.md). All definitions of an application go to the same version: each version is its own
batch, and two batches with one correlation id write the slip's tests step twice, read as a retry of each other and
get one check-run each. The tag rules are TestEngine's (trigger_v2.go validateV2Entry, shared with the Worker through
testdata/v2_message_cases.json): letters, digits, '_', '.' and '-', at most 100 characters and at least one letter or
digit; at most 10 testTags, each with the same characters and length. A tag needs testtrigger.enableV1: the legacy
per-definition call would send no filter and run every test. Every failure names the definition and the field.
*/}}
{{- define "helm.testtrigger.version" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $enableV1 := dig "testtrigger" "enableV1" true .application }}
{{- $v1 := list }}
{{- $v2 := list }}
{{- $tagChars := "must use only letters, digits, '_', '.' and '-' (TestEngine's /v2/trigger refuses any other character)" }}
{{- range dig "testtrigger" "testdefinitions" list .application }}
  {{- $where := printf "test definition '%s' of '%s'" (toString .name) $fullName }}
  {{- if not (or (kindIs "invalid" .testEnvironmentTag) (kindIs "string" .testEnvironmentTag)) }}
    {{- fail (printf "%s: testEnvironmentTag must be a string" $where) }}
  {{- end }}
  {{- if not (or (kindIs "invalid" .testTags) (kindIs "slice" .testTags)) }}
    {{- fail (printf "%s: testTags must be a list of strings" $where) }}
  {{- end }}
  {{- if not (or (kindIs "invalid" .multiRun) (kindIs "bool" .multiRun)) }}
    {{- fail (printf "%s: multiRun must be true or false" $where) }}
  {{- end }}
  {{- $tag := .testEnvironmentTag | default "" }}
  {{- $testTags := .testTags | default list }}
  {{- if not $tag }}
    {{- if $testTags }}
      {{- fail (printf "%s: testTags needs testEnvironmentTag. testTags narrows the tests of a tag on TestEngine's v2 trigger; set testEnvironmentTag, or remove testTags and keep filters" $where) }}
    {{- end }}
    {{- if .multiRun }}
      {{- fail (printf "%s: multiRun needs testEnvironmentTag. multiRun packs the tests of a tag on TestEngine's v2 trigger; set testEnvironmentTag, or remove multiRun and keep filters" $where) }}
    {{- end }}
    {{- $v1 = append $v1 (toString .name) }}
  {{- else }}
    {{- if not (empty .filters) }}
      {{- fail (printf "%s: set either filters (TestEngine's v1 trigger) or testEnvironmentTag (its v2 trigger), not both. To move the definition to v2, replace filters with testEnvironmentTag" $where) }}
    {{- end }}
    {{- if gt (len $tag) 100 }}
      {{- fail (printf "%s: testEnvironmentTag must be at most 100 characters" $where) }}
    {{- end }}
    {{- if not (regexMatch "^[A-Za-z0-9_.-]+$" $tag) }}
      {{- fail (printf "%s: testEnvironmentTag '%s' %s" $where $tag $tagChars) }}
    {{- end }}
    {{- if not (regexMatch "[A-Za-z0-9]" $tag) }}
      {{- fail (printf "%s: testEnvironmentTag '%s' must contain a letter or digit" $where $tag) }}
    {{- end }}
    {{- if gt (len $testTags) 10 }}
      {{- fail (printf "%s: testTags allows at most 10 entries" $where) }}
    {{- end }}
    {{- range $i, $testTag := $testTags }}
      {{- if not (kindIs "string" $testTag) }}
        {{- fail (printf "%s: testTags[%d] must be a string" $where $i) }}
      {{- end }}
      {{- if gt (len $testTag) 100 }}
        {{- fail (printf "%s: testTags[%d] must be at most 100 characters" $where $i) }}
      {{- end }}
      {{- if not (regexMatch "^[A-Za-z0-9_.-]+$" $testTag) }}
        {{- fail (printf "%s: testTags[%d] '%s' %s" $where $i $testTag $tagChars) }}
      {{- end }}
    {{- end }}
    {{- if not $enableV1 }}
      {{- fail (printf "%s: testEnvironmentTag needs testtrigger.enableV1: true. With enableV1 false the chart sends one legacy call per definition, which has no tag and would run every test in the image" $where) }}
    {{- end }}
    {{- $v2 = append $v2 (toString .name) }}
  {{- end }}
{{- end }}
{{- if and $v1 $v2 }}
  {{- fail (printf "application '%s': test definition '%s' goes to TestEngine's v1 trigger (filters) and '%s' to its v2 trigger (testEnvironmentTag). All test definitions of an application use the same trigger: each trigger is its own batch, and two batches of one deployment write its tests step twice. Move every definition to testEnvironmentTag in one change, or keep filters on all of them" $fullName (first $v1) (first $v2)) }}
{{- end }}
{{- ternary "v2" "v1" (not (empty $v2)) }}
{{- end }}

{{/*
helm.testtrigger.v2request (AQA-38): the TestEngine v2 request for an application whose test definitions set
testEnvironmentTag, as indented JSON: helm.testtrigger.v1request without TestFilters, plus TestEnvironmentTag, TestTags
(left out when empty) and MultiRun (left out when false) on each entry. Built from the v1 request, so every other field
(resources, tolerations, results API, EnvVars and its 64 KiB cap) is the same in both. Takes the application context;
call it only after helm.testtrigger.version answered v2.
*/}}
{{- define "helm.testtrigger.v2request" -}}
{{- $v1 := include "helm.testtrigger.v1request" (merge (dict "v2Build" true) .) | fromJson }}
{{- if not (kindIs "slice" $v1.Tests) }}
  {{- fail (printf "'%s': the v1 request did not decode for the v2 request: %v" (include "helm.fullname" .) (index $v1 "Error" | default "no Tests")) }}
{{- end }}
{{- $definitions := dig "testtrigger" "testdefinitions" list .application }}
{{- $tests := list }}
{{- range $index, $test := $v1.Tests }}
  {{- $definition := index $definitions $index }}
  {{- $test = omit $test "TestFilters" }}
  {{- $_ := set $test "TestEnvironmentTag" $definition.testEnvironmentTag }}
  {{- with $definition.testTags }}{{ $_ := set $test "TestTags" . }}{{ end }}
  {{- if $definition.multiRun }}{{ $_ := set $test "MultiRun" true }}{{ end }}
  {{- $tests = append $tests $test }}
{{- end }}
{{- dict "Tests" $tests | toPrettyJson }}
{{- end }}

{{/*
helm.testtrigger.v2curls (AQA-38): the PostSync hook's script for an application on TestEngine's v2 trigger, as the text
that goes into the script (12-space block indentation, like helm.testtrigger.legacyCurls). Takes the application context.
TESTENGINEHOOK_URL is the v1 trigger URL; the API root is that URL without a trailing /v1/trigger or /trigger (as the
canary tests script's api_base). Before the post it reads GET /v1/capabilities: a 404 (a TestEngine older than
capabilities) or a trigger_versions without "v2" means v2 is switched off in that TestEngine, and nothing is posted.
With v2 listed, a 404 on POST /v2/trigger means the route to it is missing. Every failure logs an ERROR: line and counts
in failed; the script still exits 0, as the v1 hook does, so Argo CD does not retry the sync. There is no fallback to v1.
No temp files: the container's root filesystem is read-only, so curl's output is read from a command substitution with
the HTTP status on its last line. The body is escaped by helm.testtrigger.commandSafeJson, as the v1 body, and assigned
to payload outside any $(...): kubelet reads $(...) up to its first ) as one variable name and leaves that span as it
is, so a $$ inside it would reach TestEngine doubled.
*/}}
{{- define "helm.testtrigger.v2curls" -}}
{{- $multiRun := false }}
{{- range dig "testtrigger" "testdefinitions" list .application }}
  {{- if .multiRun }}{{ $multiRun = true }}{{ end }}
{{- end }}
            base=${TESTENGINEHOOK_URL%/}
            case "$base" in
              */v1/trigger) base=${base%/v1/trigger} ;;
              */trigger) base=${base%/trigger} ;;
            esac
            v2=0
            out=$(curl -sS --max-time 15 -H "Authorization: $TESTENGINE_APIKEY" -w '\n%{http_code}' "$base/v1/capabilities")
            rc=$?
            code=$(printf '%s\n' "$out" | tail -n 1)
            body=$(printf '%s\n' "$out" | sed '$d')
            if [ "$rc" -ne 0 ]; then
              echo "ERROR: TestEngine v2 trigger not sent: GET /v1/capabilities failed (curl exit $rc)" >&2
              failed=$((failed+1))
            elif [ "$code" = "404" ]; then
              echo "ERROR: TestEngine v2 trigger not sent: v2 is switched off in this TestEngine (GET /v1/capabilities answered 404: the API is older than v2). Switch on TRIGGER_V2_ENABLED there, or put filters back in the test definitions" >&2
              failed=$((failed+1))
            elif [ "$code" != "200" ]; then
              printf '%s\n' "$body"
              echo "ERROR: TestEngine v2 trigger not sent: GET /v1/capabilities answered HTTP $code" >&2
              failed=$((failed+1))
            elif ! printf '%s' "$body" | tr -d ' \t\r\n' | grep -q '"trigger_versions":\[[^]]*"v2"'; then
              echo "ERROR: TestEngine v2 trigger not sent: v2 is switched off in this TestEngine (GET /v1/capabilities does not list v2 in trigger_versions). Switch on TRIGGER_V2_ENABLED there, or put filters back in the test definitions" >&2
              failed=$((failed+1))
            else
              v2=1
            fi
{{- if $multiRun }}
            if [ "$v2" -eq 1 ] && ! printf '%s' "$body" | tr -d ' \t\r\n' | grep -q '"multi_run_enabled":true'; then
              echo "WARN: multiRun is set, and this TestEngine does not pack Jobs yet (multi_run_enabled is not true): each test definition runs as one Job" >&2
            fi
{{- end }}
            if [ "$v2" -eq 1 ]; then
              payload='{{ include "helm.testtrigger.commandSafeJson" (dict "json" (include "helm.testtrigger.v2request" .) "application" .application "argoTemplate" false) | indent 14 | trimPrefix "              " }}'
              out=$(curl -sS --max-time 60 -w '\n%{http_code}' \
              -X POST \
              -H "Content-Type: application/json" \
              -H "Authorization: $TESTENGINE_APIKEY" \
              -d "$payload" "$base/v2/trigger")
              rc=$?
              code=$(printf '%s\n' "$out" | tail -n 1)
              printf '%s\n' "$out" | sed '$d'
              echo "TestEngine HTTP status: $code"
              if [ "$rc" -ne 0 ]; then
                echo "ERROR: TestEngine v2 trigger failed (curl exit $rc)" >&2
                failed=$((failed+1))
              elif [ "$code" = "404" ]; then
                echo "ERROR: TestEngine v2 trigger failed: TestEngine lists v2 in /v1/capabilities, and POST /v2/trigger answered 404: the /v2/trigger route is missing (the mesh does not route it to the API)" >&2
                failed=$((failed+1))
              else
                case "$code" in
                  2??) ;;
                  *)
                    echo "ERROR: TestEngine v2 trigger failed (HTTP $code)" >&2
                    failed=$((failed+1))
                    ;;
                esac
              fi
            fi
{{- end }}
