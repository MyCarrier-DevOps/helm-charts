{{- /* Dark-stage preview VirtualService (applications.<app>.canaryDarkPreview).
       Argo Rollouts' managed route canary-header (the dark stage's route) matches only X-MyCarrier-Canary and goes
       first in every VirtualService the Rollout lists, so a request that carries the header skips the app's path
       routes and their rewrites (oauth-callback: /callback -> /ui/welcome/index.html). The managed route is a bare
       route Argo Rollouts writes itself (createHeaderRoute: name, header match, canary destination); it cannot carry
       a path match or a rewrite, and a route named in managedRoutes is removed by RemoveManagedRoutes on every
       reconcile of a settled Rollout, so the chart cannot put its own routes ahead of it.
       With the value on, tests-dark calls the -preview Service (the canary pods) instead of the stable Service, and
       this second VirtualService, which the Rollout does not list (so Argo Rollouts adds no managed route to it),
       carries the app's own routes for the host <fullName>-preview with every destination on the app's own Services
       replaced by the -preview Service. */ -}}

{{- /* "true" for a canary Rollout application with canaryDarkPreview: true for which the chart renders tests-dark (the
       leader of a release whose preset steps run the dark stage, and no analysisTemplates entry of its own replaces
       tests-dark: helm.canary.testsDark.wanted) and the steps render; "false" otherwise, so a follower or a leader with
       its own tests-dark template gets no VirtualService nothing calls. Takes the application context. A
       multi-frontend release with the dark stage on already fails in helm.canary.virtualServices, so the value needs no
       check of its own. */ -}}
{{- define "helm.canary.darkPreview" -}}
{{- if and (eq (toString (dig "canaryDarkPreview" false .application)) "true") (eq .application.deploymentType "rollout") (eq (include "helm.canary.stepsRendered" .) "true") (eq (include "helm.canary.testsDark.wanted" .) "true") }}true{{ else }}false{{ end -}}
{{- end -}}

{{- /* The http routes of the -preview VirtualService, as YAML: each route of the app's own VirtualService
       (helm.specs.virtualservice.base, so before the source and cookie routes) except the routes with a redirect, with
       one -preview destination in place of the destinations on the app's own Services (stable or -preview), the
       other destinations (backend-api) and match, rewrite, timeout, retries, headers (response headers) and
       corsPolicy as they are, so a response from the preview host is what the public route sends.
       fault: a route keeps it only when it is a deterministic abort, abort.percentage.value 100 (the allowlist's
       -forbidden route: 100% delay and 100% abort 403), so the preview host answers a disallowed path as the public
       host does. Any other fault (delay only, a partial abort, an abort without percentage, which Istio applies to no
       request) is removed and the route forwards as usual: tests-dark is one zero-tolerance run (failureLimit 0), so
       chaos must not reach it.
       Ports: the default route has an own destination per service.ports entry. The preview route keeps the one on the
       port tests-dark calls (helm.canary.previewPort for ports.http, as helm.canary.tests.request derives it), else the
       first own destination. Takes the application context. */ -}}
{{- define "helm.canary.darkPreview.routes" -}}
{{- $fullName := include "helm.fullname" . -}}
{{- $namespace := include "helm.namespace" . -}}
{{- $serviceDomain := printf "%s.%s.svc" $fullName $namespace -}}
{{- $previewHost := printf "%s-preview.%s.svc.cluster.local" $fullName $namespace -}}
{{- $testsPort := include "helm.canary.previewPort" (dict "application" .application "port" (dig "ports" "http" 8080 .application)) -}}
{{- $base := include "helm.specs.virtualservice.base" . | fromYaml -}}
{{- $routes := list -}}
{{- range ($base.http | default list) -}}
  {{- if not .redirect -}}
    {{- /* The own destination to keep: the first one on the tests-dark port, else the first. */ -}}
    {{- $keep := dict "index" -1 -}}
    {{- $own := list -}}
    {{- range $i, $d := .route -}}
      {{- $host := toString $d.destination.host -}}
      {{- if or (eq $host $fullName) (eq $host $serviceDomain) (hasPrefix (printf "%s." $serviceDomain) $host) (include "helm.canary.isPreviewHost" (dict "host" $host "fullName" $fullName "namespace" $namespace)) -}}
        {{- $own = append $own $i -}}
        {{- if and (lt (int ($keep.index)) 0) $testsPort (eq (toString (dig "destination" "port" "number" "" $d)) $testsPort) }}{{ $_ := set $keep "index" $i }}{{ end -}}
      {{- end -}}
    {{- end -}}
    {{- if and $own (lt (int ($keep.index)) 0) }}{{ $_ := set $keep "index" (first $own) }}{{ end -}}
    {{- $destinations := list -}}
    {{- range $i, $d := .route -}}
      {{- if not (has $i $own) -}}
        {{- $destinations = append $destinations $d -}}
      {{- else if eq $i (int ($keep.index)) -}}
        {{- $_ := set $d.destination "host" $previewHost -}}
        {{- $_ := set $d "weight" 100 -}}
        {{- $destinations = append $destinations $d -}}
      {{- end -}}
    {{- end -}}
    {{- $route := omit . "route" -}}
    {{- if not (eq (toString (dig "abort" "percentage" "value" 0 (default dict .fault))) "100") }}{{ $route = omit $route "fault" }}{{ end -}}
    {{- $_ := set $route "route" $destinations -}}
    {{- $routes = append $routes $route -}}
  {{- end -}}
{{- end -}}
{{- toYaml $routes -}}
{{- end -}}
