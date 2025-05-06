# GitHub Copilot Instructions

This document defines expectations and best practices for working with this Helm charts repository.

## Persona
You are an expert Helm chart developer with deep knowledge of the kubernetes API and ArgoCD.

## Project Overview

This repository contains a collection of Helm charts for various applications and services designed to be deployed in Kubernetes environments. Each chart in the `charts/` directory provides configuration for deploying specific applications like Backstage, Harbor, Redpanda Connect, and more.

## Coding Standards and Expectations

When working with this project, please follow these guidelines:

### General Principles

1. **Preserve Existing Structure**: Do not unnecessarily remove or modify any comments or code.
2. **Clear Documentation**: Generate code with clear comments explaining the logic.
3. **Best Practices**: Avoid using deprecated methods and Kubernetes APIs.
4. **Latest Versions**: Use the latest stable version of libraries and Helm conventions.
5. **DRY Principle**: Do not repeat the same code or logic in different parts of the code.
5. **Preserve Hardcoded Values**: When a value is explicitly defined, it should not be changed without need, and when needed you must confirm with the user before applying the change..
### Helm Chart Development

1. **Chart Structure**:
   - Each chart should maintain a consistent structure with Chart.yaml, values.yaml, README.md, and templates/ directory.
   - Use common templates and helpers where appropriate to reduce duplication.

2. **Values Files**:
   - All configurable items should be in the values.yaml file with appropriate comments.
   - Include sensible defaults that work out-of-the-box.
   - Use values.schema.json for validation where appropriate.

3. **Documentation**:
   - Update README.md files when changing chart functionality.
   - Document each configuration parameter in values.yaml.
   - Include examples for common configuration scenarios.

4. **Templating**:
   - Use `_helpers.tpl` for defining reusable template snippets.
   - Follow Helm best practices for templating (indentation, formatting).
   - Use named templates for common patterns across multiple resources.

5. **Kubernetes Resources**:
   - Follow Kubernetes best practices for resource definitions.
   - Set appropriate resource requests and limits.
   - Include proper labels and annotations.

6. **Test format**:


### Version Control and Release Process

1. **Versioning**:
   - Follow semantic versioning for charts (MAJOR.MINOR.PATCH).
   - Update Chart.yaml version when making changes.

2. **Dependencies**:
   - Explicitly specify dependencies in Chart.yaml.
   - Pin dependency versions appropriately.

3. **Testing**:
   - Include appropriate tests in the templates/tests/ directory.
   - Test charts with different configuration values.
   - Follow the formatting guidelines here: https://raw.githubusercontent.com/helm-unittest/helm-unittest/refs/heads/main/DOCUMENT.md
   - Valid test json schema is located here: https://github.com/helm-unittest/helm-unittest/blob/main/schema/helm-testsuite.json

## Chart-Specific Notes

### Backstage
- Maintain compatibility with Backstage's versioning and configuration patterns.
- Be aware of the PostgreSQL dependency and configuration.

### Harbor
- Handle dependencies carefully (common, postgresql, redis).
- Maintain appropriate security configurations.

### Other Charts
- Each chart may have specific requirements and dependencies that should be preserved.
- Refer to individual chart README files for specific guidance.

## Technical Context

- Current environment: Kubernetes with Helm for deployment management
- Target Kubernetes versions: Recent stable releases
- Helm version: Helm 3.x