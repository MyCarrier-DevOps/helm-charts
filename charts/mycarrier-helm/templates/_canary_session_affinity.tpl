{{- /* Cookie session affinity for an application's VirtualService (applications.<app>.canarySessionAffinity).
       An application whose pods hold only their own version's hashed chunks breaks at a weighted step when index.html
       comes from one revision and a lazy chunk from the other. Istio picks the weighted destination before it hashes, so a
       DestinationRule consistentHash cannot pin a browser; a cookie match ahead of the weighted route can. */ -}}

{{- /* "true" for a canary Rollout application with canarySessionAffinity: true (per application, like canaryCompare)
       where its canary steps render (helm.canary.stepsRendered: prod, or stepsOutsideProd), where the Rollout weights
       its routes and the release's global.correlationId is required; "false" otherwise, and the VirtualService renders
       as with the value off. Takes the application context (or a dict of application and Values). */ -}}
{{- define "helm.canary.sessionAffinity" -}}
{{- if and (eq .application.deploymentType "rollout") (eq (toString (dig "canarySessionAffinity" false .application)) "true") (eq (include "helm.canary.stepsRendered" .) "true") }}true{{ else }}false{{ end -}}
{{- end -}}

{{- /* The cookie of the release in the VirtualService's namespace, as JSON {name, canary, stable}. The name is
       mc-canary-<global.appStack>-<namespace>, each lower-cased and cut to [a-z0-9-], so two stacks or two namespaces
       on a shared host do not overwrite each other's cookie, and the frontends of one release share one. The two
       values are independent SHA-256 digests (first 32 hex digits) of "canary:<namespace>:<correlation id>" and
       "stable:<namespace>:<correlation id>", with the correlation id lower-cased (helm.canary.correlationId). The
       browser never holds the correlation id, the stable value does not reveal the canary one, and a cookie from one
       namespace (a drill outside prod) cannot be replayed in another.
       The values are not secret from anyone who knows the correlation id: the id is internal-only (it is on every pod
       label and in the slip, and the derivation is public), but with canarySessionAffinity on, whoever knows it can
       compute the canary cookie and reach the canary through the public host, the dark stage's canary included. The
       gateway strip of X-MyCarrier-Canary that protects the dark stage's header route does not cover this cookie.
       Takes a context with .Values. */ -}}
{{- define "helm.canary.sessionAffinity.cookies" -}}
{{- $cid := include "helm.canary.correlationId" . -}}
{{- $namespace := include "helm.namespace" . -}}
{{- $stack := regexReplaceAll "[^a-z0-9-]" (lower (toString .Values.global.appStack)) "-" -}}
{{- $suffix := regexReplaceAll "[^a-z0-9-]" (lower $namespace) "-" -}}
{{- toJson (dict "name" (printf "mc-canary-%s-%s" $stack $suffix) "canary" (sha256sum (printf "canary:%s:%s" $namespace $cid) | trunc 32) "stable" (sha256sum (printf "stable:%s:%s" $namespace $cid) | trunc 32)) -}}
{{- end -}}

{{- /* Match blocks (JSON) with a header condition added to each block of match; a missing match is one block of just
       the condition. A block that already matches on that header cannot also carry the condition, so it fails.
       Takes route (the route's name, for the message), match, header and matcher. */ -}}
{{- define "helm.canary.sessionAffinity.match" -}}
{{- $blocks := list -}}
{{- range (.match | default (list dict)) -}}
  {{- $headers := deepCopy (dig "headers" dict .) -}}
  {{- if hasKey $headers $.header -}}
    {{- fail (printf "canarySessionAffinity: route '%s' already matches on the '%s' header, so the session cookie match cannot be added to it. Match on something else in that route." $.route $.header) -}}
  {{- end -}}
  {{- $_ := set $headers $.header $.matcher -}}
  {{- $block := deepCopy (omit . "headers") -}}
  {{- $_ := set $block "headers" $headers -}}
  {{- $blocks = append $blocks $block -}}
{{- end -}}
{{- toJson $blocks -}}
{{- end -}}

{{- /* The Cookie header regex for a cookie of the given name and exact value, as an RE2 whole-value regex (Envoy's
       safe_regex matches the whole header value): the cookie is the first or follows "; ", and it ends the header or
       is followed by ";". Name and value are escaped, so the name cannot match as the tail of another name
       (xmc-canary-stack) or as another stack's name, nor the value as the head of another. Takes name and value. */ -}}
{{- define "helm.canary.sessionAffinity.cookieRegex" -}}
{{- printf "^(.*;\\s*)?%s=%s(;.*)?$" (regexQuoteMeta .name) (regexQuoteMeta .value) -}}
{{- end -}}

{{- /* The http routes of a VirtualService with, for each route that weights one of the given applications (a route
       whose destinations are exactly the stable Service and the -preview Service of that one application), a group
       of four routes in the route's place, as JSON. A route with only the -preview destination (a canary source
       route), only the stable one, or another host is not weighted and stays as it is, and so does a route of an
       application that is not in apps. Takes http (the parsed routes), apps (a map of each opted-in application's full
       name to its name), namespace and ctx (any context with .Values). The per-app VirtualService passes its own
       application, the multi-frontend one every frontend Rollout with canarySessionAffinity.
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
{{- $cookies := include "helm.canary.sessionAffinity.cookies" .ctx | fromJson -}}
{{- $attributes := "Path=/; Secure; HttpOnly; SameSite=Lax" -}}
{{- $routes := list -}}
{{- range .http -}}
  {{- $route := . -}}
  {{- $owner := "" -}}
  {{- range $fullName, $appName := $.apps -}}
    {{- $serviceDomain := printf "%s.%s.svc" $fullName $.namespace -}}
    {{- $stable := false -}}
    {{- $preview := false -}}
    {{- $foreign := false -}}
    {{- range ($route.route | default list) -}}
      {{- $host := toString .destination.host -}}
      {{- if include "helm.canary.isPreviewHost" (dict "host" $host "fullName" $fullName "namespace" $.namespace) }}{{ $preview = true -}}
      {{- else if or (eq $host $fullName) (eq $host $serviceDomain) (hasPrefix (printf "%s." $serviceDomain) $host) }}{{ $stable = true -}}
      {{- else }}{{ $foreign = true }}{{ end -}}
    {{- end -}}
    {{- if and $stable $preview (not $foreign) }}{{ $owner = $fullName }}{{ end -}}
  {{- end -}}
  {{- if not $owner -}}
    {{- $routes = append $routes $route -}}
  {{- else -}}
    {{- if not $cid -}}
      {{- fail (printf "application '%s': canarySessionAffinity needs global.correlationId, from which the cookie values derive; it is empty." (index $.apps $owner)) -}}
    {{- end -}}
    {{- $name := toString $route.name -}}
    {{- $canaryDestinations := list -}}
    {{- $stableDestinations := list -}}
    {{- $weightedDestinations := list -}}
    {{- range $route.route -}}
      {{- $isPreview := include "helm.canary.isPreviewHost" (dict "host" (toString .destination.host) "fullName" $owner "namespace" $.namespace) -}}
      {{- $cookie := ternary $cookies.canary $cookies.stable (eq $isPreview "true") -}}
      {{- $weightedDestination := deepCopy . -}}
      {{- $_ := set $weightedDestination "headers" (dict "response" (dict "add" (dict "set-cookie" (printf "%s=%s; %s" $cookies.name $cookie $attributes)))) -}}
      {{- $weightedDestinations = append $weightedDestinations $weightedDestination -}}
      {{- $destination := deepCopy . -}}
      {{- $_ := set $destination "weight" 100 -}}
      {{- if eq $isPreview "true" }}{{ $canaryDestinations = append $canaryDestinations $destination }}{{ else }}{{ $stableDestinations = append $stableDestinations $destination }}{{ end -}}
    {{- end -}}
    {{- $rest := omit $route "name" "match" "route" -}}

    {{- $pinCanary := deepCopy $rest -}}
    {{- $_ := set $pinCanary "name" (printf "%s-pin-canary" $name) -}}
    {{- $_ := set $pinCanary "match" (include "helm.canary.sessionAffinity.match" (dict "route" $name "match" $route.match "header" "cookie" "matcher" (dict "regex" (include "helm.canary.sessionAffinity.cookieRegex" (dict "name" $cookies.name "value" $cookies.canary)))) | fromJsonArray) -}}
    {{- $_ := set $pinCanary "route" $canaryDestinations -}}
    {{- $routes = append $routes $pinCanary -}}

    {{- $pinStable := deepCopy $rest -}}
    {{- $_ := set $pinStable "name" (printf "%s-pin-stable" $name) -}}
    {{- $_ := set $pinStable "match" (include "helm.canary.sessionAffinity.match" (dict "route" $name "match" $route.match "header" "cookie" "matcher" (dict "regex" (include "helm.canary.sessionAffinity.cookieRegex" (dict "name" $cookies.name "value" $cookies.stable)))) | fromJsonArray) -}}
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
