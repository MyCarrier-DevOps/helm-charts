{{- /* Cookie session affinity for an application's VirtualService (applications.<app>.canarySessionAffinity).
       An application whose pods hold only their own version's hashed chunks breaks at a weighted step when index.html
       comes from one revision and a lazy chunk from the other. Istio picks the weighted destination before it hashes, so a
       DestinationRule consistentHash cannot pin a browser; a cookie match ahead of the weighted route can. */ -}}

{{- /* "true" for a Rollout application with canarySessionAffinity: true (per application, like canaryCompare); "false"
       for any other application, which the value leaves as it is. Takes the application context. */ -}}
{{- define "helm.canary.sessionAffinity" -}}
{{- if and (eq .application.deploymentType "rollout") (eq (toString (dig "canarySessionAffinity" false .application)) "true") }}true{{ else }}false{{ end -}}
{{- end -}}

{{- /* Match blocks (JSON) with a header condition added to each block of match; a missing match is one block of just
       the condition. A block that already matches on that header cannot also carry the condition, so it fails.
       Takes route (the route's name, for the message), match, header and matcher. */ -}}
{{- define "helm.canary.sessionAffinity.match" -}}
{{- $blocks := list -}}
{{- range (.match | default (list dict)) -}}
  {{- $headers := deepCopy (dig "headers" dict .) -}}
  {{- if hasKey $headers $.header -}}
    {{- fail (printf "global.strategy.canary.sessionAffinity: route '%s' already matches on the '%s' header, so the session cookie match cannot be added to it. Match on something else in that route." $.route $.header) -}}
  {{- end -}}
  {{- $_ := set $headers $.header $.matcher -}}
  {{- $block := deepCopy (omit . "headers") -}}
  {{- $_ := set $block "headers" $headers -}}
  {{- $blocks = append $blocks $block -}}
{{- end -}}
{{- toJson $blocks -}}
{{- end -}}

{{- /* The Cookie header value of a cookie named mc-canary whose value is exactly the given one, as an RE2 whole-value
       regex (Envoy's safe_regex matches the whole header value): the cookie is the first or follows "; ", and it ends
       the header or is followed by ";". The value is escaped, and the name cannot match as the tail of another name
       (xmc-canary) or the value as the head of another (<id>x, or <id> against stable-<id>). */ -}}
{{- define "helm.canary.sessionAffinity.cookieRegex" -}}
{{- printf "^(.*;\\s*)?mc-canary=%s(;.*)?$" (regexQuoteMeta .) -}}
{{- end -}}

{{- /* The http routes of the application's VirtualService with, for each route that weights the application (a route
       with both the application's stable Service and its -preview Service as destinations, and no other), a group of
       four routes in the route's place, as JSON. A route with only the -preview destination (a canary source route)
       or only the stable one is not weighted and stays as it is. Takes http (the parsed routes), fullName, namespace
       appName and ctx (any context with .Values).
         <route>-pin-canary  the route's match and the canary cookie: the -preview destinations only
         <route>-pin-stable  the route's match and the stable cookie: the stable destinations only
         <route>             the weighted route Argo Rollouts manages, with its name and weights: a page load
                             (Sec-Fetch-Dest: document) only; each destination adds a Set-Cookie naming the revision
                             it serves
         <route>-stable      the route's match: the stable destinations only, for a request without a cookie (or with
                             a cookie of an earlier release) and without Sec-Fetch-Dest: document
       Argo Rollouts sets only weight on the destinations of the routes it manages, so the destination headers stay
       through every weight; it puts only managedRoutes ahead of the others and keeps the rest in this order, so the
       pin and stable routes keep their place. The cookie is a session cookie, added (add, not set) so the app's own
       Set-Cookie stays. Only a page load sets it, so a chunk, fetch or XHR response carries none. */ -}}
{{- define "helm.canary.sessionAffinity.routes" -}}
{{- $cid := include "helm.canary.correlationId" .ctx -}}
{{- $attributes := "Path=/; Secure; HttpOnly; SameSite=Lax" -}}
{{- $serviceDomain := printf "%s.%s.svc" .fullName .namespace -}}
{{- $routes := list -}}
{{- range .http -}}
  {{- $route := . -}}
  {{- $stable := false -}}
  {{- $preview := false -}}
  {{- $foreign := false -}}
  {{- range ($route.route | default list) -}}
    {{- $host := toString .destination.host -}}
    {{- if include "helm.canary.isPreviewHost" (dict "host" $host "fullName" $.fullName "namespace" $.namespace) }}{{ $preview = true -}}
    {{- else if or (eq $host $.fullName) (eq $host $serviceDomain) (hasPrefix (printf "%s." $serviceDomain) $host) }}{{ $stable = true -}}
    {{- else }}{{ $foreign = true }}{{ end -}}
  {{- end -}}
  {{- if not (and $stable $preview (not $foreign)) -}}
    {{- $routes = append $routes $route -}}
  {{- else -}}
    {{- if not $cid -}}
      {{- fail (printf "application '%s': canarySessionAffinity needs global.correlationId, which names the release's cookie; it is empty." $.appName) -}}
    {{- end -}}
    {{- $name := toString $route.name -}}
    {{- $canaryDestinations := list -}}
    {{- $stableDestinations := list -}}
    {{- $weightedDestinations := list -}}
    {{- range $route.route -}}
      {{- $isPreview := include "helm.canary.isPreviewHost" (dict "host" (toString .destination.host) "fullName" $.fullName "namespace" $.namespace) -}}
      {{- $cookie := ternary $cid (printf "stable-%s" $cid) (eq $isPreview "true") -}}
      {{- $weightedDestination := deepCopy . -}}
      {{- $_ := set $weightedDestination "headers" (dict "response" (dict "add" (dict "set-cookie" (printf "mc-canary=%s; %s" $cookie $attributes)))) -}}
      {{- $weightedDestinations = append $weightedDestinations $weightedDestination -}}
      {{- $destination := deepCopy . -}}
      {{- $_ := set $destination "weight" 100 -}}
      {{- if eq $isPreview "true" }}{{ $canaryDestinations = append $canaryDestinations $destination }}{{ else }}{{ $stableDestinations = append $stableDestinations $destination }}{{ end -}}
    {{- end -}}
    {{- $rest := omit $route "name" "match" "route" -}}

    {{- $pinCanary := deepCopy $rest -}}
    {{- $_ := set $pinCanary "name" (printf "%s-pin-canary" $name) -}}
    {{- $_ := set $pinCanary "match" (include "helm.canary.sessionAffinity.match" (dict "route" $name "match" $route.match "header" "cookie" "matcher" (dict "regex" (include "helm.canary.sessionAffinity.cookieRegex" $cid))) | fromJsonArray) -}}
    {{- $_ := set $pinCanary "route" $canaryDestinations -}}
    {{- $routes = append $routes $pinCanary -}}

    {{- $pinStable := deepCopy $rest -}}
    {{- $_ := set $pinStable "name" (printf "%s-pin-stable" $name) -}}
    {{- $_ := set $pinStable "match" (include "helm.canary.sessionAffinity.match" (dict "route" $name "match" $route.match "header" "cookie" "matcher" (dict "regex" (include "helm.canary.sessionAffinity.cookieRegex" (printf "stable-%s" $cid)))) | fromJsonArray) -}}
    {{- $_ := set $pinStable "route" $stableDestinations -}}
    {{- $routes = append $routes $pinStable -}}

    {{- $managed := deepCopy $route -}}
    {{- $_ := set $managed "match" (include "helm.canary.sessionAffinity.match" (dict "route" $name "match" $route.match "header" "sec-fetch-dest" "matcher" (dict "exact" "document")) | fromJsonArray) -}}
    {{- $_ := set $managed "route" $weightedDestinations -}}
    {{- $routes = append $routes $managed -}}

    {{- $fallback := deepCopy $rest -}}
    {{- $_ := set $fallback "name" (printf "%s-stable" $name) -}}
    {{- if $route.match }}{{ $_ := set $fallback "match" (deepCopy $route.match) }}{{ end -}}
    {{- $_ := set $fallback "route" $stableDestinations -}}
    {{- $routes = append $routes $fallback -}}
  {{- end -}}
{{- end -}}
{{- toJson $routes -}}
{{- end -}}
