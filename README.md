[![Release Charts](https://github.com/MyCarrier-DevOps/helm_charts/actions/workflows/main.yml/badge.svg)](https://github.com/MyCarrier-DevOps/helm_charts/actions/workflows/main.yml)
## TL;DR

```bash
$ helm repo add mycarrier https://charts.mycarrier.dev
$ helm install my-release mycarrier/my-chart
```

## Chart submission
Develop your chart and either push to main or submit a PR to main. When the push is performed or PR merged GHA will fire an action to automatically register your chart to the helm repository. Upon subsequent updates to your chart the patch level will automatically increment. Major and minor versions will be set within the chart itself.

## values.yaml Metadata

For the readme generator tool to work, you need to add some metadata to your `values.yaml` file.

By default we use a format similar to Javadoc, using `@xxx` for tags followed by the tag structure.

The following are the tags supported at this very moment:

- For a parameter: `## @param fullKeyPath [modifier?] Description`.
- For a section: `## @section Section Title"`.
- To skip an object and all its children: `## @skip fullKeyPath`.
- To add a description for an intermediate object (i.e. not final in the YAML tree): `## @extra fullkeyPath Description`.

All the tags as well as the two initial `#` characters for the comments style can be configured in the [configuration file](#configuration-file).

> IMPORTANT: tags' order or position in the file is NOT important except for the @section tag. The @section that will include in the section all the parameters after it until a new section is found or the file ends.

The `modifier` is optional and it will change how the parameter is processed.
Several modifiers can be applied by separating them using commas (`,`). When affecting the value, the last one takes precedence.

Currently supported modifiers:

- `[array]` Indicates that the value of the parameter must be set to `[]`.
- `[object]` Indicates that the value of the parameter must be set to `{}`.
- `[string]` Indicates that the value of the parameter must be set to `""`.
- `[nullable]` Indicates that the parameter value can be set to `null`.

The modifiers are also customizable via the [configuration file](#configuration-file).

## Configuration file

The configuration file has the following structure:

```
{
  "comments": {
    "format": "##"                       <-- Which is the comments format in the values YAML
  },
  "tags": {
    "param": "@param",                   <-- Tag that indicates a parameter
    "section": "@section",               <-- Tag that indicates a section
    "skip": "@skip",                     <-- Tag that indicates the object must be skipped
    "extra": "@extra"                    <-- Tag to add a description for an intermediate object
  },
  "modifiers": {
    "array": "array",                    <-- Modifier that indicates an array type
    "object": "object"                   <-- Modifier that indicates an object type
    "string": "string"                   <-- Modifier that indicates a string type
    "nullable": "nullable"               <-- Modifier that indicates a parameter that can be set to null
  },
  "regexp": {
    "paramsSectionTitle": "Parameters"   <-- Title of the parameters section to replace in the README.md
  }
}
```



The helm "bump-chart-version" github action is the work of New Relic and can be found here: https://github.com/newrelic/helm-charts

