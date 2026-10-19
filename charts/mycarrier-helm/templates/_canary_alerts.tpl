{{- /* The script of the alerts template's alert-rules Job (analysistemplate.yaml): it reads Grafana's rules API once and
       exits 0 only when at least one alert rule that can fire matches the service, so a wrong service label or paused rules
       cannot leave the alerts check silently green. It repeats alert-gate's evaluate_rules (DEVOPS-329); keep the two in
       step. Any API error, redirect or body that is not JSON exits 1, after up to three tries for 5xx, 429 and network
       errors. */ -}}
{{- define "helm.canary.alerts.rulesCheck" -}}
import json, os, sys, time, urllib.error, urllib.request

# Same contract as alert-gate's evaluate_rules (DEVOPS-329): a rule matches when its labels, or the labels of any of
# its instances, carry the service and environment and are outside the Platform folder; it is evaluable when it is
# not paused, its health is not error, and not every instance is in an Error state.
SERVICE = os.environ["ALERTS_SERVICE"]
ENVIRONMENT = os.environ["ALERTS_ENVIRONMENT"]
URL = os.environ["GRAFANA_URL"].rstrip("/") + "/api/prometheus/grafana/api/v1/rules"
EXCLUDED_FOLDER = "Platform"


def matches(labels, folder):
    labels = labels if isinstance(labels, dict) else {}
    if (labels.get("grafana_folder") or folder) == EXCLUDED_FOLDER:
        return False
    if labels.get("service") != SERVICE:
        return False
    environment = labels.get("environment") or ""
    return environment in ("prod", "") if ENVIRONMENT == "prod" else environment == ENVIRONMENT


def instance_in_error(instance):
    state = str(instance.get("state") or "").lower()
    return "error" in state and not state.startswith("alerting")


def why_not_evaluable(rule):
    if rule.get("isPaused") is True:
        return "paused"
    if str(rule.get("health") or "").lower() == "error":
        return "unhealthy"
    instances = [a for a in (rule.get("alerts") or []) if isinstance(a, dict)]
    if instances and all(instance_in_error(a) for a in instances):
        return "unhealthy"
    return ""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a redirect would carry the token to another location; it ends as an HTTP error instead


def fetch():
    token = (os.environ.get("GRAFANA_API_KEY") or "").strip()
    if not token:
        raise RuntimeError("GRAFANA_API_KEY is not set")
    request = urllib.request.Request(URL, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    error = "no attempt made"
    for attempt in range(3):
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            error = "HTTP %d" % e.code
            if e.code < 500 and e.code != 429:
                break
        except Exception as e:  # timeout, connection error, a body that is not JSON
            error = type(e).__name__  # never the message: some echo the request headers
        if attempt < 2:
            time.sleep((2, 4)[attempt])
    raise RuntimeError("rules API: " + error)


def main():
    try:
        document = fetch()
    except RuntimeError as e:
        print("FAIL: %s" % e)
        return 1
    data = document.get("data") if isinstance(document, dict) else None
    groups = data.get("groups") if isinstance(data, dict) else None
    if not isinstance(groups, list) or document.get("status") != "success":
        print("FAIL: rules API returned an unexpected response (status is not success, or no data.groups list)")
        return 1
    counts = {"evaluable": 0, "paused": 0, "unhealthy": 0}
    for group in groups:
        group = group if isinstance(group, dict) else {}
        folder = group.get("file")
        for rule in group.get("rules") or []:
            if not isinstance(rule, dict):
                continue
            instances = [a.get("labels") for a in (rule.get("alerts") or []) if isinstance(a, dict)]
            if matches(rule.get("labels"), folder) or any(matches(i, folder) for i in instances):
                counts[why_not_evaluable(rule) or "evaluable"] += 1
    print("service=%s environment=%s: evaluable=%d paused=%d unhealthy=%d"
          % (SERVICE, ENVIRONMENT, counts["evaluable"], counts["paused"], counts["unhealthy"]))
    if not counts["evaluable"]:
        print("FAIL: no evaluable alert rule matches this service, so the alerts check cannot see it")
        return 1
    return 0


sys.exit(main())
{{- end -}}
