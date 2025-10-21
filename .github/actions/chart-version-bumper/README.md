# Chart version bumper

Chart version bumper is a Github Action that increases the Chart & App version of a given chart hosted in this repository.

If a chart's version has already been manually updated in the repository, the action now respects that semantic version and will not apply an additional automatic bump. When no manual change is detected the action falls back to automatically increasing the patch component of the chart version.

## Inputs

### `chart_name`

**Required** The name of the chart, in the `<repo_root>/charts/` directory

### `chart_version`

**Required** The (new) version of the chart.

### `app_version`

**Required** The (new) version of the app that the Helm chart contains

## Outputs

### `verboseChangeString` 

The changes that were made, in a human readable string, usable for pull request or slack messages

### `changeString`

The changes that were made, in a single line, usable for PR titles or commit messages
