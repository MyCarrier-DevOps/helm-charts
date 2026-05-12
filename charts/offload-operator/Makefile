CHART_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
CRD_DIR   := $(CHART_DIR)crds
SCHEMA_DIR := $(CHART_DIR)schemas

CRDS := $(wildcard $(CRD_DIR)/offload.mycarrier.dev_*.yaml)

.DEFAULT_GOAL := help

## help: Show this help.
.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*?## "} /^## /{sub(/^## /,""); print}' $(MAKEFILE_LIST)

## schemas: Regenerate JSON Schemas from CRDs (schemas/<singular>.schema.json).
.PHONY: schemas
schemas: $(SCHEMA_DIR)
	@command -v yq >/dev/null || { echo "ERROR: yq not on PATH (https://github.com/mikefarah/yq)"; exit 1; }
	@for crd in $(CRDS); do \
		kind=$$(yq '.spec.names.kind' $$crd); \
		group=$$(yq '.spec.group' $$crd); \
		version=$$(yq '.spec.versions[0].name' $$crd); \
		singular=$$(yq '.spec.names.singular' $$crd); \
		out="$(SCHEMA_DIR)/$${singular}.schema.json"; \
		yq -o=json '{ \
			"$$schema": "http://json-schema.org/draft-07/schema#", \
			"$$id": "https://mycarrier.dev/schemas/'"$${singular}"'.schema.json", \
			"title": "'"$${kind}"' ('"$${group}"'/'"$${version}"')" \
		} + .spec.versions[0].schema.openAPIV3Schema' $$crd > $$out; \
		echo "wrote $$out"; \
	done

$(SCHEMA_DIR):
	@mkdir -p $@

## verify: Validate every sample under tests/samples/ against the matching schema (requires check-jsonschema).
.PHONY: verify
verify: schemas
	@command -v check-jsonschema >/dev/null || { echo "ERROR: check-jsonschema not on PATH (pip install check-jsonschema)"; exit 1; }
	@if [ ! -d "$(CHART_DIR)tests/samples" ]; then echo "no tests/samples directory; nothing to verify"; exit 0; fi
	@for sample in $(CHART_DIR)tests/samples/offloadbase-*.yaml; do \
		[ -e "$$sample" ] || continue; \
		check-jsonschema --schemafile $(SCHEMA_DIR)/offloadbase.schema.json $$sample; \
	done
	@for sample in $(CHART_DIR)tests/samples/offloadroute-*.yaml; do \
		[ -e "$$sample" ] || continue; \
		check-jsonschema --schemafile $(SCHEMA_DIR)/offloadroute.schema.json $$sample; \
	done

## clean: Remove generated schemas.
.PHONY: clean
clean:
	rm -rf $(SCHEMA_DIR)
