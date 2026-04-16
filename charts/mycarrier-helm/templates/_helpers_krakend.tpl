{{/*
Helpers for the KrakenDAutoConfig CR rendered by templates/krakendAutoConfig.yaml.

Guarantees:
- The generated spec.openapi.url always points at the application's internal
  address (<baseFullName>.<metaEnv>.internal) and NEVER at the public/external
  domain, so that KrakenD only ever fetches the OpenAPI spec from a
  cluster-local endpoint.
- spec.urlTransform.hostMapping auto-includes catch-all entries that rewrite
  any external hostname the OpenAPI `servers:` block might advertise back to
  the internal URL, so that generated backends stay internal regardless of
  what the upstream spec declares.
*/}}

{{/*
helm.krakend.enabled returns "true" when the application has opted in to
KrakenDAutoConfig rendering AND every prerequisite for the `.internal`
ServiceEntry is satisfied. This mirrors the gating in
templates/internal-serviceentry.yaml so we never emit a KrakenDAutoConfig
that points at an internal host that was never created.

Prerequisites (all must hold):
  - networking.krakend.enabled == true
  - not a feature environment
  - networking.istio.enabled == true
  - istioDisabled != true (top-level application flag)
  - service.istioDisabled != true
  - networking.istio.internalEnabled == true

Any violation fails the render with a clear, targeted error.

Usage:
  {{- if eq (include "helm.krakend.enabled" $appContext) "true" }}
*/}}
{{- define "helm.krakend.enabled" -}}
{{- $app := .application -}}
{{- $krakend := dig "networking" "krakend" dict $app -}}
{{- $enabled := dig "enabled" false $krakend -}}
{{- if not $enabled -}}
false
{{- else -}}
{{- $envName := .Values.environment.name | default "dev" -}}
{{- $istioEnabled := dig "networking" "istio" "enabled" true $app -}}
{{- $appIstioDisabled := dig "istioDisabled" false $app -}}
{{- $serviceIstioDisabled := dig "service" "istioDisabled" false $app -}}
{{- $internalEnabled := dig "networking" "istio" "internalEnabled" true $app -}}
{{- if hasPrefix "feature" $envName -}}
{{- fail (printf "networking.krakend.enabled=true is not supported in feature environments (got environment=%q). The `.internal` ServiceEntry only exists in non-feature environments; new public API endpoints must be developed and released directly to dev." $envName) -}}
{{- else if not $istioEnabled -}}
{{- fail (printf "networking.krakend.enabled=true requires networking.istio.enabled=true. The KrakenDAutoConfig spec.openapi.url relies on the application's `.internal` ServiceEntry, which is not rendered when Istio is disabled.") -}}
{{- else if $appIstioDisabled -}}
{{- fail (printf "networking.krakend.enabled=true is incompatible with istioDisabled=true. The KrakenDAutoConfig spec.openapi.url relies on the application's `.internal` ServiceEntry, which is not rendered when istioDisabled=true.") -}}
{{- else if $serviceIstioDisabled -}}
{{- fail (printf "networking.krakend.enabled=true is incompatible with service.istioDisabled=true. The KrakenDAutoConfig spec.openapi.url relies on the application's `.internal` ServiceEntry, which is not rendered when service.istioDisabled=true.") -}}
{{- else if not $internalEnabled -}}
{{- fail (printf "networking.krakend.enabled=true requires networking.istio.internalEnabled=true. The KrakenDAutoConfig spec.openapi.url relies on the application's `.internal` ServiceEntry, which is not rendered when internalEnabled is false.") -}}
{{- else -}}
true
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
helm.krakend.internalHost returns the <baseFullName>.<metaEnv>.internal host
used for both spec.openapi.url and the urlTransform.hostMapping `to:` side.
*/}}
{{- define "helm.krakend.internalHost" -}}
{{- $baseFullName := include "helm.basename" . -}}
{{- $metaenv := include "helm.metaEnvironment" . -}}
{{- printf "%s.%s.internal" $baseFullName $metaenv -}}
{{- end -}}

{{/*
helm.krakend.internalURL returns http://<internalHost>. No port is included;
Istio resolves the host via the internal ServiceEntry and routes to the
application's http port.
*/}}
{{- define "helm.krakend.internalURL" -}}
{{- printf "http://%s" (include "helm.krakend.internalHost" .) -}}
{{- end -}}

{{/*
helm.krakend.externalHosts returns a newline-separated list of external
hostnames that the application may advertise in its OpenAPI `servers:` block.
Used to emit catch-all hostMapping entries that rewrite external URLs → the
internal URL.

Sources (all deduplicated):
- staticHostname.<domain>         (when .application.staticHostname is set)
- <appStack>-<appName>.<domainPrefix>.<domain>  (standard external host)
- every entry in .application.networking.istio.hosts
*/}}
{{- define "helm.krakend.externalHosts" -}}
{{- $app := .application -}}
{{- $appName := .appName -}}
{{- $domain := include "helm.domain" . -}}
{{- $domainPrefix := include "helm.domain.prefix" . -}}
{{- $appStack := .Values.global.appStack | default "app" -}}
{{- $hosts := list -}}
{{- if $app.staticHostname -}}
{{- $hosts = append $hosts (printf "%s.%s" (trimSuffix "." $app.staticHostname) $domain) -}}
{{- end -}}
{{- $standard := printf "%s.%s.%s" ((list $appStack $appName) | join "-" | lower | trunc 63 | trimSuffix "-") $domainPrefix $domain -}}
{{- $hosts = append $hosts $standard -}}
{{- $istioHosts := dig "networking" "istio" "hosts" (list) $app -}}
{{- range $istioHosts -}}
{{- $hosts = append $hosts . -}}
{{- end -}}
{{- $hosts | uniq | join "\n" -}}
{{- end -}}

{{/*
helm.krakend.autoConfigName returns the metadata.name for the KAC CR.
Defaults to <fullName>-autoconfig, truncated to 63 chars.
*/}}
{{- define "helm.krakend.autoConfigName" -}}
{{- $app := .application -}}
{{- $override := dig "networking" "krakend" "name" "" $app -}}
{{- if $override -}}
{{- $override | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-autoconfig" (include "helm.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
helm.krakend.autoConfigNamespace returns the namespace the KAC CR is rendered
into. Priority:
  1. networking.krakend.autoConfigNamespace
  2. networking.krakend.gatewayRef.namespace  (colocate with gateway)
  3. .Values.global.krakendGatewayNamespace
  4. application namespace
*/}}
{{- define "helm.krakend.autoConfigNamespace" -}}
{{- $app := .application -}}
{{- $krakend := dig "networking" "krakend" dict $app -}}
{{- $override := dig "autoConfigNamespace" "" $krakend -}}
{{- $gatewayNs := dig "gatewayRef" "namespace" "" $krakend -}}
{{- $globalNs := "" -}}
{{- if and .Values.global (hasKey (.Values.global | default dict) "krakendGatewayNamespace") -}}
{{- $globalNs = .Values.global.krakendGatewayNamespace -}}
{{- end -}}
{{- if $override -}}
{{- $override -}}
{{- else if $gatewayNs -}}
{{- $gatewayNs -}}
{{- else if $globalNs -}}
{{- $globalNs -}}
{{- else -}}
{{- include "helm.namespace" . -}}
{{- end -}}
{{- end -}}

{{/*
helm.krakend.gatewayNamespace returns the namespace for spec.gatewayRef.
Priority:
  1. networking.krakend.gatewayRef.namespace
  2. .Values.global.krakendGatewayNamespace
  3. application namespace
*/}}
{{- define "helm.krakend.gatewayNamespace" -}}
{{- $app := .application -}}
{{- $krakend := dig "networking" "krakend" dict $app -}}
{{- $gatewayNs := dig "gatewayRef" "namespace" "" $krakend -}}
{{- $globalNs := "" -}}
{{- if and .Values.global (hasKey (.Values.global | default dict) "krakendGatewayNamespace") -}}
{{- $globalNs = .Values.global.krakendGatewayNamespace -}}
{{- end -}}
{{- if $gatewayNs -}}
{{- $gatewayNs -}}
{{- else if $globalNs -}}
{{- $globalNs -}}
{{- else -}}
{{- include "helm.namespace" . -}}
{{- end -}}
{{- end -}}

{{/*
helm.krakend.validateExtraHostMapping fails the render when any user-supplied
`extraHostMapping` entry's `to:` value is not an internal address.

Internal-only invariant: `to:` must either
  - be a bare hostname ending in `.internal` or `.svc.cluster.local`, or
  - be an http(s) URL whose host ends in `.internal` or `.svc.cluster.local`.

Values that contain the configured external domain are rejected with a
dedicated error for clarity. Any other value (example.com, an IP literal,
https://public-site, etc.) is rejected as non-internal.
*/}}
{{- define "helm.krakend.validateExtraHostMapping" -}}
{{- $app := .application -}}
{{- $appName := .appName -}}
{{- $domain := include "helm.domain" . -}}
{{- $extra := dig "networking" "krakend" "urlTransform" "extraHostMapping" (list) $app -}}
{{- range $i, $entry := $extra -}}
{{- $to := $entry.to | default "" -}}
{{- if contains $domain $to -}}
{{- fail (printf "application %q: networking.krakend.urlTransform.extraHostMapping[%d].to=%q contains the external domain %q. The KrakenDAutoConfig must only map to internal addresses (.internal or .svc.cluster.local)." $appName $i $to $domain) -}}
{{- end -}}
{{- /* Extract the host portion: strip scheme and path/port. */ -}}
{{- $host := $to -}}
{{- if contains "://" $host -}}
{{- $host = (splitList "://" $host | last) -}}
{{- end -}}
{{- $host = (splitList "/" $host | first) -}}
{{- $host = (splitList ":" $host | first) -}}
{{- $isInternal := or (hasSuffix ".internal" $host) (hasSuffix ".svc.cluster.local" $host) -}}
{{- if not $isInternal -}}
{{- fail (printf "application %q: networking.krakend.urlTransform.extraHostMapping[%d].to=%q is not an internal address. The host portion must end in .internal or .svc.cluster.local." $appName $i $to) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
helm.specs.krakendautoconfig renders the full `spec:` body of the
KrakenDAutoConfig CR. Expects the standard $appContext dict with keys
appName, application, Values, ctx.
*/}}
{{- define "helm.specs.krakendautoconfig" -}}
{{- $app := .application -}}
{{- $appName := .appName -}}
{{- $krakend := dig "networking" "krakend" dict $app -}}
{{- $internalURL := include "helm.krakend.internalURL" . -}}
{{- /* Validate user input up front */ -}}
{{- include "helm.krakend.validateExtraHostMapping" . -}}
{{- /* gatewayRef (required) */ -}}
{{- $gatewayRef := dig "gatewayRef" dict $krakend -}}
{{- $gatewayName := required (printf "application %q: networking.krakend.gatewayRef.name is required when networking.krakend.enabled=true" $appName) (dig "name" "" $gatewayRef) -}}
gatewayRef:
  name: {{ $gatewayName }}
  namespace: {{ include "helm.krakend.gatewayNamespace" . }}
{{- /* trigger */ -}}
{{- $trigger := dig "trigger" "OnChange" $krakend }}
trigger: {{ $trigger }}
{{- if eq $trigger "Periodic" }}
{{- $interval := dig "periodic" "interval" "" $krakend -}}
{{- if not $interval -}}
{{- fail (printf "application %q: networking.krakend.periodic.interval is required when trigger=Periodic" $appName) -}}
{{- end }}
periodic:
  interval: {{ $interval | quote }}
{{- end }}
{{- /* openapi — always internal. Normalize path to ensure a leading slash. */ -}}
{{- $openapi := dig "openapi" dict $krakend -}}
{{- $path := dig "path" "/swagger/v1/swagger.json" $openapi -}}
{{- if and $path (not (hasPrefix "/" $path)) -}}
{{- $path = printf "/%s" $path -}}
{{- end }}
openapi:
  url: {{ printf "%s%s" $internalURL $path | quote }}
  allowClusterLocal: {{ dig "allowClusterLocal" true $openapi }}
{{- if hasKey $openapi "format" }}
  format: {{ $openapi.format }}
{{- end }}
{{- if hasKey $openapi "auth" }}
  auth:
{{ toYaml $openapi.auth | indent 4 }}
{{- end }}
{{- /* urlTransform — always emitted: identity + catch-all external-host mappings */ -}}
{{- $urlTransform := dig "urlTransform" dict $krakend -}}
{{- $externalHostsStr := include "helm.krakend.externalHosts" . -}}
{{- $externalHosts := list -}}
{{- if $externalHostsStr -}}
{{- $externalHosts = splitList "\n" $externalHostsStr -}}
{{- end -}}
{{- $extra := dig "extraHostMapping" (list) $urlTransform }}
urlTransform:
  hostMapping:
    - from: {{ $internalURL | quote }}
      to: {{ $internalURL | quote }}
{{- range $host := $externalHosts }}
{{- if $host }}
    - from: {{ printf "http://%s" $host | quote }}
      to: {{ $internalURL | quote }}
    - from: {{ printf "https://%s" $host | quote }}
      to: {{ $internalURL | quote }}
{{- end }}
{{- end }}
{{- range $entry := $extra }}
    - from: {{ $entry.from | quote }}
      to: {{ $entry.to | quote }}
{{- end }}
{{- if hasKey $urlTransform "stripPathPrefix" }}
  stripPathPrefix: {{ $urlTransform.stripPathPrefix | quote }}
{{- end }}
{{- if hasKey $urlTransform "addPathPrefix" }}
  addPathPrefix: {{ $urlTransform.addPathPrefix | quote }}
{{- end }}
{{- /* defaults passthrough */ -}}
{{- if hasKey $krakend "defaults" }}
defaults:
{{ toYaml $krakend.defaults | indent 2 }}
{{- end }}
{{- /* overrides passthrough */ -}}
{{- if hasKey $krakend "overrides" }}
overrides:
{{ toYaml $krakend.overrides | indent 2 }}
{{- end }}
{{- /* filter passthrough */ -}}
{{- if hasKey $krakend "filter" }}
filter:
{{ toYaml $krakend.filter | indent 2 }}
{{- end }}
{{- /* cue passthrough */ -}}
{{- if hasKey $krakend "cue" }}
cue:
{{ toYaml $krakend.cue | indent 2 }}
{{- end }}
{{- end -}}
