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
{{- $enableV1 := dig "testtrigger" "enableV1" false .application }}
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
            -d '{{ include "helm.testtrigger.v1request" . | indent 12 | trimPrefix "            " }}' "$TESTENGINEHOOK_URL" || {
              rc=$?
              echo "ERROR: TestEngine trigger failed (curl exit $rc)" >&2
              failed=$((failed+1))
            }
          {{- else }}
          {{- range dig "testtrigger" "testdefinitions" list .application }}
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
                  "ResultsApiKey": {{ $resultsApiKey | quote }}{{- end }}
                }
              }' "$TESTENGINEHOOK_URL" || {
              rc=$?
              echo "ERROR: TestEngine trigger failed for "{{ .name | squote }}" (curl exit $rc)" >&2
              failed=$((failed+1))
            }
          {{- end }}
          {{- end }}
            if [ "$failed" -gt 0 ]; then
              echo "ERROR: $failed TestEngine trigger call(s) failed — see above; exiting 0 to avoid ArgoCD sync retries" >&2
            fi
            exit 0
        {{ include "helm.containerSecurityContext" . | indent 8 | trim }}
{{- end }}
{{- end }}

{{/*
The TestEngine v1 request for an application, as indented JSON: {"Tests": [...]}, one entry per
testtrigger.testdefinitions item, with no SlipStep, so TestEngine bookends the environment's tests step
(prod_tests in prod) for the run. Two templates send it, so they cannot drift apart: the PostSync hook
(helm.specs.testenginehook, with testtrigger.enableV1) and, for a prod canary Rollout, the <fullName>-prod-tests
ConfigMap that the release's rollout-watch posts after promotion (DEVOPS-319, Tech Spec D7; triggertestengine.yaml).
Takes the application context. Every test definition's results API settings are checked here.
*/}}
{{- define "helm.testtrigger.v1request" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $baseName := include "helm.basename" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $httpPort := 8080 }}
{{- $gitBranch := .Values.global.gitbranch }}
{{- $stackname := .Values.global.appStack }}
{{- $correlationId := .Values.global.correlationId }}
{{- if not (dig "service" "ports" false .application) }}
{{- range $key, $value := .application.ports }}
  {{- if eq ($key | lower) "http" }}
    {{- $httpPort = $value }}
  {{- end }}
{{- end }}
{{- end }}
{{- $imageTag := .application.image.tag }}
{{- $tests := list }}
{{- range dig "testtrigger" "testdefinitions" list .application }}
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
{{- $testEnv := dict "EnvironmentName" $namespace "ReleaseId" $imageTag "SecretId" (.secretId | default "") "ServiceAddress" $serviceAddress "ReleaseDefinitionName" (.releaseDefinitionName | default $baseName) "BranchName" $gitBranch "AdditionalEnvVars" (.additionalEnvVars | default "") "CorrelationId" $correlationId "LegacyMode" $legacyMode }}
{{- if $resultsApiUrl }}{{- $_ := set $testEnv "ResultsApiUrl" $resultsApiUrl }}{{- end }}
{{- if $resultsApiKey }}{{- $_ := set $testEnv "ResultsApiKey" $resultsApiKey }}{{- end }}
{{- $test := dict "IsMonolith" false "TestName" .name "StackName" $stackname "ContainerImage" (.containerImage | default "") "ContainerTag" (.containerTag | default "") "HardenedSecurityContext" $hardenedSecurityContext "TestFilters" .filters "Tolerations" $tolerations "NodeAffinity" $nodeAffinity "UseDefaultNodeAffinity" $useDefaultNodeAffinity "SpreadAcrossNodes" $spreadAcrossNodes "PodResources" $podResources "TestEnvironmentVariables" $testEnv }}
{{- $tests = append $tests $test }}
{{- end }}
{{- dict "Tests" $tests | toPrettyJson }}
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
