# chart-renderer's kube-linter check, for the scripts that lint rendered charts the way the pipeline does. Sourced.
#
# chart-renderer lints every rendered mycarrier-helm package with kube-linter, configured in MyCarrier-DevOps/chart-renderer
# ci/render/internal/infrastructure/checks/kubelinter.go. This copies that configuration as of chart-renderer 58f9166
# (kube-linter 0.8.3, ci/render/Dockerfile KUBELINTER_VERSION); compare it with kubelinter.go when the renderer changes:
#   - `kube-linter lint <dir> --exclude <each of kubeLinterExcludes> --ignore-paths <path> --add-all-built-in`, where
#     each ignored path is the full path of a file in the package named as in kubeLinterIgnored (it walks the dir);
#   - a render fails when the output matches `found [1-9]\d* lint error`.
# The renderer writes one file per template (helm template --output-dir) and ignores by file name, so lint a directory
# rendered the same way.
#
# Defines: lint <rendered dir> (kube-linter's output on stdout), lint_error_re, and check <description> <0 or 1>, which
# counts failures in fail. KUBE_LINTER chooses the binary.

KUBE_LINTER=${KUBE_LINTER:-kube-linter}
for t in helm "$KUBE_LINTER"; do command -v "$t" >/dev/null || { echo "FAIL: $t is required"; exit 1; }; done
echo "kube-linter $("$KUBE_LINTER" version)"

# chart-renderer 58f9166: kubeLinterExcludes, kubeLinterIgnored, lintErrors.
excludes=(env-var-secret no-anti-affinity latest-tag sorted-keys required-annotation-email default-service-account
  restart-policy minimum-three-replicas no-readiness-probe dnsconfig-options required-label-owner no-node-affinity
  non-isolated-pod no-rolling-update-strategy no-read-only-root-fs hpa-minimum-three-replicas)
ignored_names=(triggertestengine.yaml jobs.yaml)
lint_error_re='found [1-9][0-9]* lint error'
lint() {
  local args=(lint "$1") c name path
  for c in "${excludes[@]}"; do args+=(--exclude "$c"); done
  for name in "${ignored_names[@]}"; do
    while IFS= read -r path; do args+=(--ignore-paths "$path"); done < <(find "$1" -type f -name "$name")
  done
  args+=(--add-all-built-in)
  "$KUBE_LINTER" "${args[@]}" 2>&1 || true
}

fail=0
check() { if [ "$2" = 0 ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi; }
