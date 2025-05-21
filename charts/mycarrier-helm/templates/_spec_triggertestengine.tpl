{{- define "helm.specs.testenginehook" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $httpPort := 8080 }}
{{- $environment := $.Values.environment.name }}
{{- $gitBranch := $.Values.global.gitbranch}}
{{- if and .Values.service .Values.service.ports }}
  {{- range .Values.service.ports }}
    {{- if eq .name "http" }}
      {{- $httpPort = .targetPort }}
    {{- end }}
  {{- end }}
{{- end }}
{{- $imageTag :=  .application.image.tag }}
{{- if dig "testtrigger" false .application }}
ttlSecondsAfterFinished: {{ dig "testtrigger" "ttlSecondsAfterFinished" 300 .application }}
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
      - name: {{ dig "testtrigger" "imagePullSecret" "imagepull" .application | quote }}
    restartPolicy: {{ dig "testtrigger" "restartPolicy" "Never" .application | quote  }}
    containers:
      - image: "alpine/curl:latest"
        imagePullPolicy: {{ dig "testtrigger" "imagePullPolicy" "IfNotPresent" .application | quote }}
        name: testtrigger
        env:
        - name: TESTENGINE_APIKEY
          value: {{ dig "testtrigger" "apikey" "" .application | quote }}
        - name: TESTENGINEHOOK_URL
          value: {{ dig "testtrigger" "webhook_url" "" .application | quote }}
        command:
          - /bin/sh
          - -c
          - |
          {{- range dig "testtrigger" "testdefinitions" list .application }}
            curl -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: $TESTENGINE_APIKEY" \
            -d '{ 
              "IsMonolith": false, 
              "TestName": "{{ .name }}", 
              "StackName": "", 
              "ContainerImage": "{{ .containerImage }}",
              "ContainerTag": "{{ .containerTag }}",
              "TestFilters": {{ .filters | toJson }},
              "TestEnvironmentVariables": {
                  "EnvironmentName": "{{ $environment }}",
                  "ReleaseId": "{{ $imageTag }}",
                  "SecretId": "{{ .secretId }}",
                  "ServiceAddress": "http://{{ $fullName }}.{{ $namespace }}.svc.cluster.local:{{ $httpPort }}",
                  "ReleaseDefinitionName": "{{ $fullName }}",
                  "BranchName": "{{ $gitBranch }}"
                }
              }' "$TESTENGINEHOOK_URL";
          {{- end }}
        {{ include "helm.containerSecurityContext" . | indent 8 | trim }}
{{- end }}
{{- end }}