{{- /* The chart's tests AnalysisTemplate (DEVOPS-515): a Job metric that runs the application's TestEngine suite
       (testtrigger.testdefinitions) against its canary through TestEngine's v1 caller contract
       (MC.TestEngine TestEngine.Api/docs/V1_TRIGGER.md: Caller contract) and passes only when the run passes.
       analysistemplate.yaml renders it as <environment>-<fullName>-tests and, for the dark stage's leader (DEVOPS-326),
       as <environment>-<fullName>-tests-dark: the same Job and script, sent to the stable Service with the
       X-MyCarrier-Canary header. */ -}}

{{- /* "true" when the chart renders the tests template for an application: a canary Rollout (helm.canary.enabled: a
       routed Rollout whose global.deploymentStrategy is canary) that lists tests in global.strategy.canary.analysis.templates, or whose explicit steps reference
       <environment>-<fullName>-tests, and that has no applications.<app>.analysisTemplates entry named tests (which
       replaces it). It renders in every environment where it is listed, also where the Rollout renders steps: []
       (helm.canary.stepsRendered), like the chart's health template, so stepsOutsideProd changes only the Rollout and
       the checks below run everywhere. An application that runs it needs testtrigger.testdefinitions, or the render
       fails: every template the analysis steps reference must render for each canary Rollout application. A Rollout
       that is not a canary Rollout (property rolling or unset) gets none and runs none of these checks, as for the
       chart's health and alerts templates, so listing tests there has no effect. The checks
       that read the steps (the dark stage, lockstep, global.correlationId, the barrier window) are in
       helm.canary.configuredSteps. */ -}}
{{- define "helm.canary.tests.wanted" -}}
{{- if eq (include "helm.canary.tests.listed" .) "true" -}}
  {{- $self := printf "%s-%s-tests" (toString .Values.environment.name) (include "helm.fullname" .) -}}
  {{- include "helm.canary.tests.ownTemplate" (dict "context" . "name" "tests" "message" (printf "application '%s': its canary analysis runs the chart's tests AnalysisTemplate (global.strategy.canary.analysis.templates lists tests, or the explicit steps reference %s), which runs the application's testtrigger.testdefinitions through TestEngine, and it has none. Every template the analysis steps run must render for each canary Rollout application. Add applications.%s.testtrigger.testdefinitions, define a tests entry under applications.%s.analysisTemplates, or remove tests from global.strategy.canary.analysis.templates." .appName $self .appName .appName)) -}}
{{- end -}}
{{- end -}}

{{- /* "true" when the chart renders the tests-dark template for an application (DEVOPS-326, spec A2): the leader
       (helm.canary.leader) of a canary Rollout release whose preset steps run the dark stage (coordinator.enabled and
       dark; an explicit steps list renders no dark stage), under the same conditions that make
       helm.canary.configuredSteps give the leader its tests-dark analysis step, in every environment, like tests. An
       applications.<app>.analysisTemplates entry named tests-dark replaces it. A leader without
       testtrigger.testdefinitions fails the render: the dark stage's analysis step references tests-dark, and Argo
       Rollouts leaves the Rollout InvalidSpec when it is missing. Followers get none. */ -}}
{{- define "helm.canary.testsDark.wanted" -}}
{{- if eq (include "helm.canary.enabled" .) "true" -}}
  {{- $cfg := include "helm.canary.config" . | fromJson -}}
  {{- if and (not $cfg.steps) $cfg.coordinator.enabled $cfg.dark (eq (include "helm.canary.leader" .) (toString .appName)) -}}
    {{- $self := printf "%s-%s-tests-dark" (toString .Values.environment.name) (include "helm.fullname" .) -}}
    {{- include "helm.canary.tests.ownTemplate" (dict "context" . "name" "tests-dark" "message" (printf "application '%s': the dark stage runs the chart's tests-dark AnalysisTemplate (%s) on the leader, which runs the application's testtrigger.testdefinitions through TestEngine against the canary, and it has none. Add applications.%s.testtrigger.testdefinitions, define a tests-dark entry under applications.%s.analysisTemplates, or set global.strategy.canary.dark: false." .appName $self .appName .appName)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- /* "true" when the chart's own template of the given name (tests or tests-dark) renders for an application that runs
       it: no applications.<app>.analysisTemplates entry of that name replaces it. Without testtrigger.testdefinitions
       the render fails with the given message. Takes context (the application context), name and message. */ -}}
{{- define "helm.canary.tests.ownTemplate" -}}
{{- $replaced := false -}}
{{- range (.context.application.analysisTemplates | default list) }}{{ if eq (toString .name) $.name }}{{ $replaced = true }}{{ end }}{{ end -}}
{{- if not $replaced -}}
  {{- $trigger := .context.application.testtrigger | default dict -}}
  {{- if not (and (kindIs "map" $trigger) (get $trigger "testdefinitions")) -}}
    {{- fail .message -}}
  {{- end -}}
true
{{- end -}}
{{- end -}}

{{- /* "true" for a canary Rollout (helm.canary.enabled) whose analysis runs tests: global.strategy.canary.analysis.templates
       lists tests, or its explicit steps reference <environment>-<fullName>-tests. Also true when the app replaces the
       chart's tests with an applications.<app>.analysisTemplates entry, so the barrier window of
       helm.canary.configuredSteps runs whenever tests is listed. */ -}}
{{- define "helm.canary.tests.listed" -}}
{{- if eq (include "helm.canary.enabled" .) "true" -}}
  {{- $cfg := include "helm.canary.config" . | fromJson -}}
  {{- $self := printf "%s-%s-tests" (toString .Values.environment.name) (include "helm.fullname" .) -}}
  {{- $listed := has "tests" ($cfg.analysis.templates | default list) -}}
  {{- range ($cfg.steps | default list) }}{{ range (dig "analysis" "templates" list .) }}{{ if eq (toString .templateName) $self }}{{ $listed = true }}{{ end }}{{ end }}{{ end -}}
  {{- if $listed }}true{{ end -}}
{{- end -}}
{{- end -}}

{{- /* The poll budget of the tests Job in seconds: global.strategy.canary.analysis.tests.timeout (default 7m). It covers
       the whole script, the one resubmit included. Zero, or a value that is not a duration, fails the render. */ -}}
{{- define "helm.canary.tests.budgetSeconds" -}}
{{- $timeout := (include "helm.canary.config" . | fromJson).analysis.tests.timeout -}}
{{- $seconds := include "helm.canary.durationSeconds" $timeout | int -}}
{{- if not $seconds -}}
  {{- fail (printf "global.strategy.canary.analysis.tests.timeout is '%v'; the tests template needs a duration above zero such as 90s, 7m or 1h (default 7m). It is the poll budget of the tests Job: the whole run, the one resubmit included." $timeout) -}}
{{- end -}}
{{- $seconds -}}
{{- end -}}

{{- /* The tests Job's activeDeadlineSeconds: the poll budget + global.strategy.canary.analysis.tests.startupSeconds
       (default 120, 30 to 600; 540 s with the defaults). Kubernetes counts activeDeadlineSeconds from the Job's creation,
       Pending included: scheduling (with tolerations [], maybe an on-demand node scale-up), the image pull and the Vault
       injection. The script's own budget starts only when its process starts, and the pod cannot read its start time
       (it is not in the downward API), so startupSeconds is the slack for all of that. A pod still Pending after it ends
       DeadlineExceeded: the Job condition says so, the script prints no FAIL line, and a TestEngine run already started
       is left running. It is what the tests template counts in the canary budget (helm.canary.budgetSeconds) and in the
       barrier window (helm.canary.analysis.templateSeconds). */ -}}
{{- define "helm.canary.tests.activeDeadlineSeconds" -}}
{{- $startup := (include "helm.canary.config" . | fromJson).analysis.tests.startupSeconds -}}
{{- if or (not (kindIs "float64" $startup)) (ne $startup (float64 (int $startup))) (lt $startup 30.0) (gt $startup 600.0) -}}
  {{- fail (printf "global.strategy.canary.analysis.tests.startupSeconds is %v; it must be a whole number of seconds from 30 to 600 (default 120): the time the tests Job's pod may take to start (scheduling, image pull, Vault injection) before its poll budget begins." $startup) -}}
{{- end -}}
{{- add (include "helm.canary.tests.budgetSeconds" . | int) (int $startup) -}}
{{- end -}}

{{- /* How long after a Job ends Argo Rollouts can take to see it, for a Job metric whose Job may run the given
       activeDeadlineSeconds (the argument, a number): ceil(sqrt(2 x activeDeadlineSeconds)) seconds. Argo Rollouts
       v1.10.0 (metricproviders/job, Resume) checks a running Job again after a delay that grows with the time the Job
       has run, so the last check before the end can come up to that long before Argo sees it. Sprig has no square root:
       an integer Newton iteration gives floor(sqrt), then 1 is added unless it is exact. */ -}}
{{- define "helm.canary.tests.completionLagSeconds" -}}
{{- $x := mul 2 (int .) -}}
{{- $root := $x -}}
{{- range until 64 -}}
  {{- if gt $root 0 -}}
    {{- $next := div (add $root (div $x $root)) 2 -}}
    {{- if lt $next $root }}{{ $root = $next }}{{ end -}}
  {{- end -}}
{{- end -}}
{{- if lt (mul $root $root) $x }}{{ $root = add1 $root }}{{ end -}}
{{- $root -}}
{{- end -}}

{{- /* The tests Job's TestEngine request: helm.testtrigger.v1request for test definitions with filters, or
       helm.testtrigger.v2request for test definitions with testEnvironmentTag (AQA-109; helm.testtrigger.version picks
       it, and all definitions of an application use one), the request the PostSync hook and the prod-tests
       ConfigMap send for the same application, with four differences (V1_TRIGGER: Slip step routing and run kinds,
       Caller contract rule 10): ServiceAddress is the app's -preview Service (the canary pods), or its stable Service
       for tests-dark (its -preview Service with canaryDarkPreview); TestEnvironmentVariables gets RunKind canary and SlipStep none (no slip writes, no check-run, no
       webhook); Tolerations is [] so the test pods land on on-demand nodes. Takes context (the application context),
       name (tests or tests-dark: the wording of the failures), target (preview, the default, or stable) and requestHeaders (optional; RequestHeaders inside
       TestEnvironmentVariables). tests and tests-dark both build their request here, so their bodies differ only in
       ServiceAddress and RequestHeaders.
       ServiceAddress: http://<fullName>-preview.<namespace>.svc.cluster.local:<port> (target preview: tests, and
       tests-dark when canaryDarkPreview is on) or http://<fullName>.<namespace>.svc.cluster.local:<port> (target
       stable: tests-dark otherwise, whose X-MyCarrier-Canary header
       the dark stage's header route sends to the canary), on the app's http Service port (helm.canary.previewPort: the
       service.ports entry named http, else the entry whose targetPort is ports.http, else ports.http; both Services
       expose the same ports); none fails the render. A definition's own serviceAddress whose host
       is the app's stable Service or its -preview Service (<fullName> or <fullName>-preview, with .<namespace>, .svc or
       .svc.cluster.local, with or without a scheme or user info) keeps its path on that address. It may name no port or
       the http Service port; another port fails the render, because the chart cannot tell which port of the target
       Service serves it. Any other host fails the render, because the canary run must test the canary's pods; the
       message shows the address without its scheme or user info. CorrelationId is always a JSON string (a numeric global.correlationId
       such as 12345 becomes "12345", helm.canary.correlationIdString) in its own case; the hook and the prod-tests ConfigMap
       render it as before.
       TestEngine refuses a canary in a prod-class environment (the request's EnvironmentName, the namespace,
       contains prod and not preprod) when a filter's first TestCategory starts with preprod (Caller contract rule 7),
       so such a filter fails the render here, with TestEngine's own reading of a filter: the text before the first &,
       without TestCategory=. A filter TestEngine reads from Vault (a vault: reference) is not known here. On v2 the
       Stage is the testEnvironmentTag after TestEngine's clean-up, and the same rule applies to it (V2_TRIGGER.md:
       Stage); testTags do not change the Stage. Like the filter rule, the check runs only in prod-class
       environments, although TestEngine applies its rule wherever it accepts a canary (AQA-109 decision 1). */ -}}
{{- define "helm.canary.tests.request" -}}
{{- $ctx := .context -}}
{{- $fullName := include "helm.fullname" $ctx -}}
{{- $namespace := include "helm.namespace" $ctx -}}
{{- /* The wording of the failures below: the run and the way out follow the template (name), the target Service follows the target. */ -}}
{{- $stable := eq (toString .target) "stable" -}}
{{- $dark := eq (toString .name) "tests-dark" -}}
{{- $kind := ternary "stable" "-preview" $stable -}}
{{- $Run := ternary "The dark stage's tests-dark run" "The canary tests run" $dark -}}
{{- $template := ternary "tests-dark" "tests" $dark -}}
{{- $wayOut := ternary "set global.strategy.canary.dark: false" "leave tests out of global.strategy.canary.analysis.templates" $dark -}}
{{- $servicePort := include "helm.canary.previewPort" (dict "application" $ctx.application "port" (dig "ports" "http" 8080 $ctx.application)) -}}
{{- if not $servicePort -}}
  {{- fail (printf "application '%s': %s calls the %s Service on its http port, and its %s Service exposes none. Set applications.%s.ports.http to the http Service port (with service.ports, name that Service port http)." $ctx.appName (untitle $Run) $kind $kind $ctx.appName) -}}
{{- end -}}
{{- $base := printf "http://%s%s.%s.svc.cluster.local:%v" $fullName (ternary "" "-preview" $stable) $namespace $servicePort -}}
{{- $ownHosts := list -}}
{{- range (list $fullName (printf "%s-preview" $fullName)) -}}
  {{- $ownHosts = concat $ownHosts (list (lower .) (lower (printf "%s.%s" . $namespace)) (lower (printf "%s.%s.svc" . $namespace)) (lower (printf "%s.%s.svc.cluster.local" . $namespace))) -}}
{{- end -}}
{{- $stableFqdn := printf "%s.%s.svc.cluster.local" $fullName $namespace -}}
{{- $addresses := list -}}
{{- range (dig "testtrigger" "testdefinitions" list $ctx.application) -}}
  {{- $definition := . -}}
  {{- $address := $base -}}
  {{- with .serviceAddress -}}
    {{- /* host[:port] and the path, without the scheme or user info (never printed: it can hold a password). */ -}}
    {{- $rest := regexReplaceAll "^[^/?#@]*@" (regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://" (toString .) "") "" -}}
    {{- $hostPort := regexReplaceAll "[/?#].*$" $rest "" -}}
    {{- $host := trimSuffix "." (lower (regexReplaceAll ":[0-9]*$" $hostPort "")) -}}
    {{- $port := trimPrefix ":" (regexFind ":[0-9]+$" $hostPort) -}}
    {{- if not (has $host $ownHosts) -}}
      {{- fail (printf "application '%s': test definition '%s' sets serviceAddress '%s', whose host is not the application's own Service (%s). %s must test the canary, so it calls the %s Service, and the chart cannot move another host there. Remove serviceAddress (the run then calls %s), point it at %s with the path the tests need, or %s." $ctx.appName (toString $definition.name) $rest $stableFqdn $Run $kind $base $stableFqdn $wayOut) -}}
    {{- end -}}
    {{- if and $port (ne $port (toString $servicePort)) -}}
      {{- fail (printf "application '%s': test definition '%s' sets serviceAddress '%s', whose port %s is not the application's http Service port (%s). %s calls the %s Service on its http port, and the chart cannot tell which %s port serves port %s. Remove the port, or use port %s." $ctx.appName (toString $definition.name) $rest $port (toString $servicePort) $Run $kind $kind $port (toString $servicePort)) -}}
    {{- end -}}
    {{- $address = printf "%s%s" $base (trimPrefix $hostPort $rest) -}}
  {{- end -}}
  {{- $addresses = append $addresses $address -}}
{{- end -}}
{{- /* AQA-109: the trigger the application's test definitions go to (helm.testtrigger.version, which also checks their
       v2 fields and the one-trigger-per-application rule): filters go to v1, testEnvironmentTag to v2. There is no
       fallback from v2 to v1: a v1 request without TestFilters would run every test in the image. */ -}}
{{- $version := include "helm.testtrigger.version" $ctx -}}
{{- $run := dict "serviceAddresses" $addresses "tolerations" (list) "runKind" "canary" "slipStep" "none" "requestHeaders" (.requestHeaders | default dict) "correlationId" (include "helm.canary.correlationIdString" $ctx) -}}
{{- $environmentName := lower (toString $namespace) -}}
{{- if and (contains "prod" $environmentName) (not (contains "preprod" $environmentName)) -}}
  {{- range (dig "testtrigger" "testdefinitions" list $ctx.application) -}}
    {{- $definition := . -}}
    {{- if eq $version "v2" -}}
      {{- /* The v2 Stage is the tag after TestEngine's clean-up (V2_TRIGGER.md: Stage): characters outside A-Za-z0-9-
             become -, runs of - collapse, and - is trimmed at both ends. */ -}}
      {{- $tag := toString .testEnvironmentTag -}}
      {{- $stage := trimAll "-" (regexReplaceAll "-+" (regexReplaceAll "[^A-Za-z0-9-]" $tag "-") "-") -}}
      {{- if hasPrefix "preprod" (lower $stage) -}}
        {{- fail (printf "application '%s': test definition '%s' has the testEnvironmentTag '%s', whose Stage '%s' starts with preprod. TestEngine refuses such a tag in a prod canary run (RunKind canary in a prod environment), so the %s analysis would fail every prod canary. Use a tag that does not start with preprod, or %s in prod." $ctx.appName (toString $definition.name) $tag $stage $template $wayOut) -}}
      {{- end -}}
    {{- end -}}
    {{- $filters := .filters | default list -}}
    {{- if kindIs "string" $filters }}{{ $filters = list $filters }}{{ end -}}
    {{- range $filters -}}
      {{- $category := trim (replace "TestCategory=" "" (first (splitList "&" (toString .)))) -}}
      {{- if hasPrefix "preprod" (lower $category) -}}
        {{- fail (printf "application '%s': test definition '%s' has the filter '%s', whose first TestCategory starts with preprod. TestEngine refuses such a filter in a prod canary run (RunKind canary in a prod environment), so the %s analysis would fail every prod canary. Put a category that does not start with preprod first in the filter, or %s in prod." $ctx.appName (toString $definition.name) (toString .) $template $wayOut) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if eq $version "v2" -}}
{{- include "helm.testtrigger.v2request" (merge (dict "testRun" $run) $ctx) -}}
{{- else -}}
{{- include "helm.testtrigger.v1request" (merge (dict "testRun" $run) $ctx) -}}
{{- end -}}
{{- end -}}

{{- /* The Job spec of the tests and tests-dark metrics, for an Argo Rollouts job provider: one pod that runs
       helm.canary.tests.script on analysis.tests.image. Takes context (the application context), name (the container
       and label suffix), and target and requestHeaders (optional, passed to helm.canary.tests.request). TESTS_REMEDY is
       the way out the script names when TestEngine has RUN_KINDS_ENABLED off: removing tests from
       analysis.templates, or for tests-dark setting dark: false. The TestEngine URL is the one the PostSync hook uses (helm.specs.testenginehook):
       global.testengineWebhookUrl, else the v1 URL in Vault (url, or dev_url for the argo-events-test instance). The
       key is testtrigger.apikey, else the shared vault:DevOps/data/testengine/api#encoded_header (the hook sends
       testtrigger.apikey as it is, empty when unset). The key must be a vault: reference: a literal key would be stored
       in the AnalysisTemplate and in every AnalysisRun and Job, so it fails the render. Both reach the pod as vault:
       environment values, injected when the pod starts, as for the hook. backoffLimit 0 and restartPolicy Never, so a
       failed run is never repeated by Kubernetes (the script resubmits once itself); tolerations [] keeps the pod on
       on-demand nodes (Caller contract rules 10 and 13). No Istio sidecar, as for the alerts Job: a sidecar that
       outlives the script would keep the Job running until its deadline. TESTS_TRIGGER_VERSION v2 comes after
       TESTS_REMEDY, and only for an application on TestEngine's v2 trigger (AQA-109), so the Job of a filters-only
       application is the same as before. */ -}}
{{- define "helm.canary.tests.jobSpec" -}}
{{- $ctx := .context -}}
{{- $cfg := include "helm.canary.config" $ctx | fromJson -}}
{{- $global := $ctx.Values.global | default dict -}}
{{- $urlKey := ternary "dev_url" "url" (eq (toString (dig "argoEventsInstance" "" $global)) "argo-events-test") -}}
{{- $url := dig "testengineWebhookUrl" "" $global | default (printf "vault:DevOps/data/testengine/api/v1#%s" $urlKey) -}}
{{- $apikey := dig "testtrigger" "apikey" "" $ctx.application | default "vault:DevOps/data/testengine/api#encoded_header" -}}
{{- if not (hasPrefix "vault:" (toString $apikey)) -}}
  {{- fail (printf "application '%s': testtrigger.apikey is not a vault: reference. The canary tests Job would carry the key in the AnalysisTemplate and in every AnalysisRun and Job it creates. Remove testtrigger.apikey, so the shared vault:DevOps/data/testengine/api#encoded_header is used, or set it to a vault: reference." $ctx.appName) -}}
{{- end -}}
backoffLimit: 0
activeDeadlineSeconds: {{ include "helm.canary.tests.activeDeadlineSeconds" $ctx }}
template:
  metadata:
    {{- /* Not the app's selector labels, so the pod never becomes an endpoint of the app's Service. */}}
    labels:
      app.kubernetes.io/name: {{ printf "%s-%s" (include "helm.fullname" $ctx) .name | trunc 63 | trimSuffix "-" }}
      app.kubernetes.io/component: canary-analysis
    annotations:
      sidecar.istio.io/inject: "false"
  spec:
    restartPolicy: Never
    tolerations: []
    {{- include "helm.podSecurityContext" (dict "Values" $ctx.Values) | nindent 4 }}
    containers:
    - name: {{ .name }}
      image: {{ $cfg.analysis.tests.image }}
      {{- /* The pod status then carries the script's last lines, including its FAIL reason. */}}
      terminationMessagePolicy: FallbackToLogsOnError
      command:
      - python3
      - -I
      - -B
      - -c
      - |
        {{- include "helm.canary.tests.script" . | nindent 8 }}
      env:
      - name: TESTENGINE_URL
        value: {{ $url | quote }}
      - name: TESTENGINE_APIKEY
        value: {{ $apikey | quote }}
      - name: TESTS_BUDGET_SECONDS
        value: {{ include "helm.canary.tests.budgetSeconds" $ctx | quote }}
      - name: TESTS_REQUEST
        value: |-
          {{- include "helm.testtrigger.commandSafeJson" (dict "json" (include "helm.canary.tests.request" (dict "context" $ctx "name" .name "target" .target "requestHeaders" .requestHeaders)) "application" $ctx.application "argoTemplate" true "encodeVaultInline" true) | nindent 10 }}
      - name: TESTS_REMEDY
        value: {{ ternary "set global.strategy.canary.dark: false" "remove tests from global.strategy.canary.analysis.templates" (eq (toString .name) "tests-dark") | quote }}
      {{- /* AQA-109: only for v2, so a filters-only application renders as before; the script's default is v1. */}}
      {{- if eq (include "helm.testtrigger.version" $ctx) "v2" }}
      - name: TESTS_TRIGGER_VERSION
        value: v2
      {{- end }}
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 500m
          memory: 256Mi
      {{- include "helm.containerSecurityContext" (dict "Values" $ctx.Values) | nindent 6 }}
{{- end -}}

{{- /* The script of the tests Job, on TestEngine's v1 caller contract (V1_TRIGGER.md: Caller contract):
       0. GET /v1/capabilities; a 404 or run_kinds_enabled false sends no POST and fails, naming RUN_KINDS_ENABLED.
       1. POST /v1/trigger with TESTS_REQUEST; only 2xx goes on. A 425 dispatched nothing and the same request is sent
          again; a 422 "run kinds disabled" and every other answer fail without a retry. A POST with no answer fails
          without a retry, because it may have started a run.
       2. Every member must echo the request's run_kind and slip_step.
       3. GET /v1/runs/{id} every poll interval until a terminal status. A 404 within 60 s of the POST is retried, after
          that it fails; a 5xx (503: the status store is unavailable) fails; no answer is retried.
       4. Exit 0 only on passed; failed exits 1.
       5. no_results or infra_failed: one new POST (a new run), then exit 1 unless that run passes. With less than 60 s
          of the poll budget left, the new POST is skipped and the run fails, as that run could not end in time.
       The poll budget (TESTS_BUDGET_SECONDS, analysis.tests.timeout) covers all of it, and every HTTP call ends by the
       budget too: a SIGALRM watchdog bounds the whole call (connect, send, status line, headers and body) by the time
       left, and the socket timeout is also set to the time left before each connect and each read. When the budget runs
       out the Job fails with a FAIL line, before activeDeadlineSeconds stops the pod. An error answer whose body cannot
       be read still counts by its status. Any other error ends the run with "FAIL: unexpected <error type>".
       TESTS_POLL_INTERVAL_SECONDS (10), TESTS_NOT_FOUND_GRACE_SECONDS (60) and TESTS_RESUBMIT_FLOOR_SECONDS (60) are not
       rendered; the offline test
       (.github/scripts/test_canary_tests_check.py) sets them to run fast. The script logs paths, statuses, error types
       and TestEngine's error details, never the URL's host, the key or the request. Both RUN_KINDS_ENABLED failures (0
       and the 422 in 1) name TESTS_REMEDY, the way out of the template that runs the script, after turning
       RUN_KINDS_ENABLED on.
       AQA-109, TESTS_TRIGGER_VERSION v2 (rendered only for test definitions with testEnvironmentTag; unset means v1):
       the request must be a v2 request (every test with TestEnvironmentTag, none with TestFilters), and a v1 request
       must carry no TestEnvironmentTag, or nothing is sent. In 0, a 404, or a trigger_versions without "v2", sends no
       POST and fails, naming TRIGGER_V2_ENABLED and TESTS_REMEDY; a test with MultiRun while multi_run_enabled is not
       true logs a WARN line (the run is one Job) and goes on. In 1 and 5 the POST goes to /v2/trigger, never to
       /v1/trigger; with v2 listed, a 404 there means the mesh has no /v2/trigger route and fails without a retry. Every
       other rule, the polling of /v1/runs/{id} included, is the same as on v1. There is no fallback to v1. */ -}}
{{- define "helm.canary.tests.script" -}}
import http.client, json, os, re, signal, ssl, sys, time, urllib.parse

TERMINAL = ("passed", "failed", "no_results", "infra_failed")
RUN_ID = re.compile(r"^[0-9a-f]{32}$")
USER_AGENT = "mycarrier-helm-canary-tests/1"
MAX_BODY = 1024 * 1024
STARTED = time.monotonic()
BUDGET = INTERVAL = NOT_FOUND_GRACE = RESUBMIT_FLOOR = 0.0
REMEDY = ""
VERSION = "v1"
TRIGGER = "/v1/trigger"
WATCHDOG = {"armed": False}


class Fail(Exception):
    """Ends the run with exit 1 and this reason."""


class NoAnswer(Exception):
    """No HTTP answer in time: a DNS, connection, TLS or read error, or the end of the call's time."""


def log(message):
    print("[%4ds] %s" % (time.monotonic() - STARTED, message), flush=True)


def api_base(url):
    """The API root of the trigger URL: a trailing /v1/trigger or /trigger is removed, so the URL may name the v1
    trigger (as the hook's does), the legacy trigger or the API root."""
    url = url.strip().rstrip("/")
    for suffix in ("/v1/trigger", "/trigger"):
        if url.endswith(suffix):
            return url[: -len(suffix)]
    return url


def detail(document, text):
    if isinstance(document, dict):
        text = str(document.get("detail") or document.get("title") or text)
    return " ".join(text.split())[:500] or "(empty body)"


def time_left(stop):
    left = stop - time.monotonic()
    if left <= 0:
        raise TimeoutError()
    return left


def on_alarm(signum, frame):
    if WATCHDOG["armed"]:
        raise TimeoutError()  # interrupts a connect, send or read that would run past the call's end


def read_body(response, sock, stop):
    """The body, read one chunk at a time with the socket timeout set to the time left, so a slow answer cannot run
    past the call's end. A body shorter than its Content-Length raises IncompleteRead."""
    chunks, size = [], 0
    while not response.isclosed():  # the response closes the socket once the whole body is read
        sock.settimeout(time_left(stop))
        chunk = response.read1(65536)
        if not chunk:
            break
        size += len(chunk)
        if size > MAX_BODY:
            raise http.client.HTTPException("body too large")
        chunks.append(chunk)
    if response.length:
        raise http.client.IncompleteRead(b"", response.length)
    return b"".join(chunks)


def call(method, url, key, deadline, body=None, limit=15):
    """(HTTP status, JSON document or None, body text); NoAnswer when there is no HTTP answer by the earlier of limit
    seconds and the poll budget. NoAnswer carries the error's type (gaierror, ConnectionRefusedError,
    SSLCertVerificationError, TimeoutError...), never its message: some messages name the host."""
    stop = min(time.monotonic() + limit, deadline)
    parts = urllib.parse.urlsplit(url)
    target = (parts.path or "/") + ("?" + parts.query if parts.query else "")
    headers = {"Authorization": key, "Accept": "application/json", "User-Agent": USER_AGENT}
    data = None
    if body is not None:
        data = body.encode("utf-8")
        headers["Content-Type"] = "application/json"
    connection = None
    try:
        WATCHDOG["armed"] = True
        signal.setitimer(signal.ITIMER_REAL, time_left(stop))
        try:
            if parts.scheme == "https":
                connection = http.client.HTTPSConnection(parts.hostname, parts.port, timeout=time_left(stop),
                                                         context=ssl.create_default_context())
            else:
                connection = http.client.HTTPConnection(parts.hostname, parts.port, timeout=time_left(stop))
            connection.request(method, target, body=data, headers=headers)
            sock = connection.sock
            sock.settimeout(time_left(stop))
            response = connection.getresponse()
        except (http.client.HTTPException, OSError) as e:
            raise NoAnswer(type(e).__name__)
        try:
            raw = read_body(response, sock, stop)
        except (http.client.HTTPException, OSError) as e:
            if 200 <= response.status < 300:
                raise NoAnswer(type(e).__name__)
            raw = b""  # an error answer counts by its status, also when its body cannot be read
    except TimeoutError:  # the time was up before the call, or the watchdog fired outside the guarded steps
        raise NoAnswer("TimeoutError")
    finally:
        WATCHDOG["armed"] = False
        signal.setitimer(signal.ITIMER_REAL, 0)
        if connection is not None:
            connection.close()
    text = raw.decode("utf-8", "replace")
    try:
        document = json.loads(text) if text.strip() else None
    except ValueError:
        document = None
    return response.status, document, text


def wait(deadline, reason):
    """Sleeps one poll interval, or fails when the poll budget is spent."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise Fail("%s; the poll budget of %g s (global.strategy.canary.analysis.tests.timeout) is spent" % (reason, BUDGET))
    time.sleep(min(INTERVAL, remaining))


def preflight(base, key, kind, deadline, multi_run=False):
    while True:
        try:
            status, document, text = call("GET", base + "/v1/capabilities", key, deadline)
        except NoAnswer as e:
            log("GET /v1/capabilities: no answer (%s)" % e)
            wait(deadline, "GET /v1/capabilities never answered")
            continue
        if status == 404 and VERSION == "v2":
            raise Fail("GET /v1/capabilities answered 404: this TestEngine has no run kinds and no v2 trigger (a build"
                       " before MC.TestEngine#95, or the route is missing), so no tests were started. The canary tests"
                       " of test definitions with testEnvironmentTag need TestEngine with RUN_KINDS_ENABLED=true and"
                       " TRIGGER_V2_ENABLED=true. Turn them on in TestEngine, put filters back on the test definitions,"
                       " or %s." % REMEDY)
        if status == 404:
            raise Fail("GET /v1/capabilities answered 404: this TestEngine has no run kinds (a build before MC.TestEngine#95,"
                       " or the route is missing), so no tests were started. The canary tests need TestEngine with"
                       " RUN_KINDS_ENABLED=true.")
        if status == 401:
            raise Fail("GET /v1/capabilities answered 401: TestEngine refused the key in TESTENGINE_APIKEY")
        if status != 200 or not isinstance(document, dict):
            raise Fail("GET /v1/capabilities answered HTTP %d: %s" % (status, detail(document, text)))
        if document.get("run_kinds_enabled") is not True:
            raise Fail("TestEngine has RUN_KINDS_ENABLED off (run_kinds_enabled: %s), so it refuses canary runs and no"
                       " tests were started. Turn RUN_KINDS_ENABLED on in TestEngine, or %s."
                       % (json.dumps(document.get("run_kinds_enabled")), REMEDY))
        kinds = document.get("run_kinds")
        if isinstance(kinds, list) and kind not in kinds:
            raise Fail("TestEngine offers the run kinds %s, not %s; no tests were started" % (json.dumps(kinds), kind))
        if VERSION == "v2":
            versions = document.get("trigger_versions")
            if not isinstance(versions, list) or "v2" not in versions:
                raise Fail("TestEngine does not list v2 in trigger_versions (%s): TRIGGER_V2_ENABLED is off there, or"
                           " the build is older than v2, so it has no /v2/trigger and no tests were started. Turn"
                           " TRIGGER_V2_ENABLED on in TestEngine, put filters back on the test definitions, or %s."
                           % (json.dumps(versions), REMEDY))
            if multi_run and document.get("multi_run_enabled") is not True:
                log("WARN: multiRun is set, and this TestEngine does not pack Jobs yet (multi_run_enabled: %s): each"
                    " test definition runs as one Job" % json.dumps(document.get("multi_run_enabled")))
        log("TestEngine %s: run kinds enabled%s" % (document.get("api_version") or "(no api_version)",
                                                    ", v2 trigger listed" if VERSION == "v2" else ""))
        return


def submit(base, key, body, kind, step, deadline):
    """POSTs the request and returns (run id, time of the answer)."""
    while True:
        if time.monotonic() >= deadline:
            raise Fail("POST %s was not sent: the poll budget of %g s"
                       " (global.strategy.canary.analysis.tests.timeout) is spent" % (TRIGGER, BUDGET))
        try:
            status, document, text = call("POST", base + TRIGGER, key, deadline, body=body, limit=60)
        except NoAnswer as e:
            raise Fail("POST %s: no answer (%s); it may have started a run, so it is not sent again" % (TRIGGER, e))
        answered = time.monotonic()
        if status == 425:
            log("POST %s answered 425 (%s): nothing was dispatched; the same request goes again"
                % (TRIGGER, detail(document, text)))
            wait(deadline, "POST %s kept answering 425" % TRIGGER)
            continue
        if status == 422 and "run kinds disabled" in text.lower():
            raise Fail("POST %s answered 422 run kinds disabled: TestEngine has RUN_KINDS_ENABLED off, so the"
                       " platform paused canary runs; not retried. Turn RUN_KINDS_ENABLED on in TestEngine, or %s."
                       % (TRIGGER, REMEDY))
        if status == 401:
            raise Fail("POST %s answered 401: TestEngine refused the key in TESTENGINE_APIKEY" % TRIGGER)
        if status == 404 and VERSION == "v2":
            raise Fail("POST /v2/trigger answered 404, and TestEngine lists v2 in /v1/capabilities: the /v2/trigger"
                       " route is missing (the mesh does not route it to the API), so no tests were started; not"
                       " retried")
        if not 200 <= status < 300:
            raise Fail("POST %s answered HTTP %d: %s" % (TRIGGER, status, detail(document, text)))
        run_id = document.get("slip_aggregate_id") if isinstance(document, dict) else None
        if not isinstance(run_id, str) or not RUN_ID.match(run_id):
            raise Fail("POST %s answered HTTP %d without a slip_aggregate_id to poll" % (TRIGGER, status))
        members = document.get("test_batches")
        if not isinstance(members, list) or not members or any(
                not isinstance(m, dict) or m.get("run_kind") != kind or m.get("slip_step") != step for m in members):
            raise Fail("run %s: TestEngine did not echo run_kind %s and slip_step %s for every member, so it treats the"
                       " request as a default run; the run is not polled" % (run_id, kind, step))
        log("POST %s: run %s started (%d members, run_kind %s, slip_step %s)"
            % (TRIGGER, run_id, len(members), kind, step))
        return run_id, answered


def poll(base, key, run_id, posted, deadline):
    last = "no answer yet"
    while True:
        if time.monotonic() >= deadline:  # no call without time left, so the reason keeps the last status
            wait(deadline, "run %s did not end in time (last status: %s)" % (run_id, last))
        try:
            status, document, text = call("GET", base + "/v1/runs/" + run_id, key, deadline)
        except NoAnswer as e:
            log("GET /v1/runs/%s: no answer (%s)" % (run_id, e))
            if time.monotonic() < deadline:  # a call the end of the budget cut short keeps the last status
                last = "no answer (%s)" % e
        else:
            if status == 200 and isinstance(document, dict) and isinstance(document.get("status"), str):
                state = document["status"]
                if state in TERMINAL:
                    message = " ".join(str(document.get("message") or "").split())[:500]
                    log("run %s: %s%s" % (run_id, state, " (%s)" % message if message else ""))
                    return state
                if state != last:
                    log("run %s: %s" % (run_id, state))
                last = state
            elif status == 404:
                waited = time.monotonic() - posted
                if waited >= NOT_FOUND_GRACE:
                    raise Fail("GET /v1/runs/%s still answered 404 %d s after the POST: TestEngine has no record of the"
                               " run (lost or expired), so its outcome is unknown" % (run_id, waited))
                last = "404 (no record yet)"
            elif status >= 500:
                raise Fail("GET /v1/runs/%s answered HTTP %d%s: %s" % (
                    run_id, status, " (the run status store is unavailable)" if status == 503 else "",
                    detail(document, text)))
            else:
                raise Fail("GET /v1/runs/%s answered HTTP %d: %s" % (run_id, status, detail(document, text)))
        wait(deadline, "run %s did not end in time (last status: %s)" % (run_id, last))


def run():
    global BUDGET, INTERVAL, NOT_FOUND_GRACE, RESUBMIT_FLOOR, REMEDY, VERSION, TRIGGER
    BUDGET = float(os.environ.get("TESTS_BUDGET_SECONDS") or 420)
    INTERVAL = float(os.environ.get("TESTS_POLL_INTERVAL_SECONDS") or 10)
    REMEDY = os.environ.get("TESTS_REMEDY") or ""
    NOT_FOUND_GRACE = float(os.environ.get("TESTS_NOT_FOUND_GRACE_SECONDS") or 60)
    RESUBMIT_FLOOR = float(os.environ.get("TESTS_RESUBMIT_FLOOR_SECONDS") or 60)
    signal.signal(signal.SIGALRM, on_alarm)
    deadline = STARTED + BUDGET
    url = os.environ.get("TESTENGINE_URL") or ""
    key = (os.environ.get("TESTENGINE_APIKEY") or "").strip()
    if url.startswith("vault:") or key.startswith("vault:"):
        raise Fail("TESTENGINE_URL or TESTENGINE_APIKEY is still a vault: reference: the Vault webhook did not inject"
                   " it into the pod")
    if not key:
        raise Fail("TESTENGINE_APIKEY is empty (check the Vault property)")
    if any(not 32 <= ord(c) < 127 for c in key):
        raise Fail("TESTENGINE_APIKEY holds characters that cannot go in an HTTP header (only printable ASCII can);"
                   " check the Vault property")
    parts = urllib.parse.urlsplit(url.strip())
    try:
        valid_url = parts.scheme in ("http", "https") and bool(parts.hostname) and (parts.port or 1) > 0
    except ValueError:
        valid_url = False
    if not valid_url:
        raise Fail("TESTENGINE_URL is not an http(s) URL with a host")
    VERSION = os.environ.get("TESTS_TRIGGER_VERSION") or "v1"
    if VERSION not in ("v1", "v2"):
        raise Fail("TESTS_TRIGGER_VERSION is %s; it must be v1 or v2" % json.dumps(VERSION[:20]))
    TRIGGER = "/%s/trigger" % VERSION
    body = os.environ.get("TESTS_REQUEST") or ""
    try:
        tests = json.loads(body)["Tests"]
        environment = tests[0]["TestEnvironmentVariables"]
        kind, step = environment["RunKind"], environment["SlipStep"]
        tagged = [isinstance(t, dict) and bool(t.get("TestEnvironmentTag")) for t in tests]
    except (ValueError, LookupError, TypeError):
        raise Fail("TESTS_REQUEST is not a %s request with RunKind and SlipStep in its first test" % VERSION)
    # Never a tag on v1 (v1 refuses it), and never a v2 request with TestFilters or without a tag (no fallback to v1).
    if VERSION == "v2" and not (all(tagged) and all("TestFilters" not in t for t in tests)):
        raise Fail("TESTS_REQUEST is not a v2 request: every test needs TestEnvironmentTag and no TestFilters; no"
                   " tests were started")
    if VERSION == "v1" and any(tagged):
        raise Fail("TESTS_REQUEST sets TestEnvironmentTag, which goes to /v2/trigger only, and TESTS_TRIGGER_VERSION"
                   " is v1; no tests were started")
    multi_run = VERSION == "v2" and any(t.get("MultiRun") is True for t in tests)
    base = api_base(url)
    preflight(base, key, kind, deadline, multi_run)
    for attempt in (1, 2):
        run_id, posted = submit(base, key, body, kind, step, deadline)
        state = poll(base, key, run_id, posted, deadline)
        if state == "passed":
            log("PASS: run %s passed" % run_id)
            return 0
        if state == "failed":
            raise Fail("run %s failed: the tests failed or timed out in TestEngine" % run_id)
        if attempt == 1:
            left = deadline - time.monotonic()
            if left < RESUBMIT_FLOOR:
                raise Fail("run %s ended %s, and the resubmit was skipped: %d s of the poll budget is left, less than"
                           " the %g s a new run needs at least" % (run_id, state, max(left, 0), RESUBMIT_FLOOR))
            log("run %s ended %s; the request goes once more as a new run" % (run_id, state))
            continue
        raise Fail("run %s ended %s again after one resubmit. no_results: the filters matched no test, or the test"
                   " container could not write its results (check its log); infra_failed: TestEngine could not run"
                   " the tests" % (run_id, state))


def main():
    try:
        return run()
    except Fail as e:
        log("FAIL: %s" % e)
    except Exception as e:  # never the message or a traceback: they can hold the URL or the key
        log("FAIL: unexpected %s" % type(e).__name__)
    return 1


sys.exit(main())
{{- end -}}
