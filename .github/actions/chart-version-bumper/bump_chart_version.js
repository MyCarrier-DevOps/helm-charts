const yaml = require("yaml");
const { strOptions } = require('yaml/types');
const semver = require('semver');

function parseDocument(content, context) {
    try {
        // allow unbounded line width, to prevent us changing the YAML document unnecessary
        strOptions.fold.lineWidth = 0;
        return yaml.parseDocument(content);
    } catch (error) {
        throw Error(`Could not parse the ${context} document as YAML: ${error}`);
    }
}

function normalizeVersion(value) {
    if (value === undefined || value === null) {
        return null;
    }
    return value.toString();
}

function bumpPatchVersion(version) {
    const cleaned = semver.clean(version);
    if (!cleaned) {
        throw Error(`Current chart version "${version}" is not a valid semantic version.`);
    }

    const bumped = semver.inc(cleaned, 'patch');
    if (!bumped) {
        throw Error(`Failed to bump chart version from "${version}".`);
    }
    return bumped;
}

function changeEntry(field, from, to) {
    return { field, from, to };
}

// bumpChartVersion bumps the chartVersion and appVersion of the given chart.
exports.bumpChartVersion = function(chartYAML, chartVersion, appVersion, previousChartYAML = null) {
    const doc = parseDocument(chartYAML, 'current');

    const currentChartVersion = normalizeVersion(doc.get("version"));
    const currentAppVersion = normalizeVersion(doc.get("appVersion"));

    if (!currentChartVersion) {
        throw Error('Chart.yaml must define a "version" value.');
    }

    let previousChartVersion = null;
    let previousAppVersion = null;
    if (previousChartYAML) {
        const previousDoc = parseDocument(previousChartYAML, 'previous');
        previousChartVersion = normalizeVersion(previousDoc.get("version"));
        previousAppVersion = normalizeVersion(previousDoc.get("appVersion"));
    }

    const previousExists = previousChartYAML !== null;
    const manualChartVersionDetected = (!chartVersion || chartVersion === "") && (
        (!previousExists && currentChartVersion !== null) ||
        (previousChartVersion !== null && currentChartVersion !== null && previousChartVersion !== currentChartVersion)
    );

    const manualAppVersionDetected = previousAppVersion !== null && currentAppVersion !== null && previousAppVersion !== currentAppVersion;

    let targetChartVersion = chartVersion;
    if (!targetChartVersion || targetChartVersion === "") {
        if (manualChartVersionDetected) {
            targetChartVersion = currentChartVersion;
        } else if (currentChartVersion !== null) {
            targetChartVersion = bumpPatchVersion(currentChartVersion);
        }
    }

    const changes = [];

    if (targetChartVersion && currentChartVersion !== targetChartVersion) {
        doc.set("version", targetChartVersion);
        changes.push(changeEntry("chartVersion", currentChartVersion, targetChartVersion));
    } else if (manualChartVersionDetected) {
        const fromValue = previousChartVersion !== null ? previousChartVersion : 'N/A';
        changes.push(changeEntry("chartVersion", fromValue, currentChartVersion));
    }

    let appVersionChanged = false;
    if (appVersion && currentAppVersion !== appVersion) {
        doc.set("appVersion", appVersion);
        changes.push(changeEntry("appVersion", currentAppVersion, appVersion));
        appVersionChanged = true;
    }

    if (!appVersionChanged && manualAppVersionDetected) {
        const fromValue = previousAppVersion !== null ? previousAppVersion : 'N/A';
        changes.push(changeEntry("appVersion", fromValue, currentAppVersion));
    }

    return { newYAML: doc.toString(), changes };
};