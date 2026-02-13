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
{{- if dig "testtrigger" false .application }}
ttlSecondsAfterFinished: {{ dig "testtrigger" "ttlSecondsAfterFinished" 3600 .application }}
activeDeadlineSeconds: {{ dig "testtrigger" "activeDeadlineSeconds" 300 .application }}
backoffLimit: {{ dig "testtrigger" "backoffLimit" 0 .application }}
template:
  metadata:
    labels:
      {{ include "helm.labels.dependencies" . | indent 6 | trim }}
      {{ include "helm.labels.standard" . | indent 6 | trim }}
  spec:
    {{ include "helm.podSecurityContext" . | indent 4 | trim }}
    serviceAccountName: default
    imagePullSecrets:
      - name: {{ dig "testtrigger" "imagePullSecret" $imagePullSecret .application | quote }}
    restartPolicy: {{ dig "testtrigger" "restartPolicy" $restartPolicy .application | quote  }}
    containers:
      - image: "alpine/curl:latest"
        imagePullPolicy: {{ dig "testtrigger" "imagePullPolicy" "IfNotPresent" .application | quote }}
        name: testtrigger
        env:
        - name: TESTENGINE_APIKEY
          value: {{ dig "testtrigger" "apikey" "" .application | quote }}
        - name: TESTENGINEHOOK_URL
          value: {{ dig "testtrigger" "webhook_url" "" .application | quote }}
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
          {{- range dig "testtrigger" "testdefinitions" list .application }}
          {{- $serviceAddress := .serviceAddress | default (printf "http://%s.%s.svc.cluster.local:%v" $fullName $namespace $httpPort) }}
            curl -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: $TESTENGINE_APIKEY" \
            -d '{ 
              "IsMonolith": false, 
              "TestName": "{{ .name }}", 
              "StackName": "{{ $stackname }}", 
              "ContainerImage": "{{ .containerImage }}",
              "ContainerTag": "{{ .containerTag }}",
              "TestFilters": {{ .filters | toJson }},
              "TestEnvironmentVariables": {
                  "EnvironmentName": "{{ $namespace }}",
                  "ReleaseId": "{{ $imageTag }}",
                  "SecretId": "{{ .secretId }}",
                  "ServiceAddress": {{ $serviceAddress | quote }},
                  "ReleaseDefinitionName": "{{ .releaseDefinitionName | default $baseName }}",
                  "BranchName": "{{ $gitBranch }}",
                  "AdditionalEnvVars": "{{ .additionalEnvVars}}",
                  "CorrelationId": "{{ $correlationId }}"
                }
              }' "$TESTENGINEHOOK_URL";
          {{- end }}
        {{ include "helm.containerSecurityContext" . | indent 8 | trim }}
{{- end }}
{{- end }}
