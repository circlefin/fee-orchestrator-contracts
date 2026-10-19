/**
 * Copyright 2026 Circle Internet Group, Inc.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
const fs = require('fs');

const COVERAGE_TABLE_HEADER_PATTERN = /^\| File\s+\| % Lines\s+\| % Statements\s+\| % Branches\s+\| % Funcs\s+\|$/;
const COVERAGE_TABLE_TOTAL_ROW_NAME = 'Total';
const COVERAGE_TABLE_COLUMN_DELIM = '|';

const COVERAGE_TABLE_COVERAGE_FRACTION_REGEXP = /\((\d+)\/(\d+)\)/;

const MIN_REQUIRED_LINE_COVERAGE_PERCENTAGE = 100;
const MIN_REQUIRED_STATEMENT_COVERAGE_PERCENTAGE = 100;
const MIN_REQUIRED_BRANCH_COVERAGE_PERCENTAGE = 100;
const MIN_REQUIRED_FUNCTION_COVERAGE_PERCENTAGE = 100;

const CoverageLevel = Object.freeze({
    DOES_NOT_MEET_MINIMUM: 0,
    MEETS_MINIMUM_WITH_SLACK: 1,
    MEETS_MINIMUM: 2,
});

const NUM_COLUMNS = 5;

const TOTAL_UNITS_SLACK_THRESHOLD = 8;
const COVERAGE_SLACK_PERCENTAGE = 5;

const PASS_WITH_SLACK_WHITELIST_FILE = "script/coverage/passWithSlackWhitelist.txt"

function loadExclusionSet(filePath) {
    try {
        return new Set(
            fs.readFileSync(filePath, "utf8")
              .split("\n")
              .map(l => l.trim())
              .filter(l => l !== "" && !l.startsWith("//"))
        );
    } catch (err) {
        console.warn(`[coverage] exclusion file not found: ${filePath} – using empty set`);
        return new Set();
    }
}

const FUNCTION_EXCLUSION_LIST = loadExclusionSet("script/coverage/excludedFunctions.txt");
const FILE_EXCLUSION_LIST     = loadExclusionSet("script/coverage/excludedFiles.txt");

function pct(a, b) {
    return b === 0 ? "100.00%" : `${(a * 100 / b).toFixed(2)}%`;
}

function getNonWhitelistedPassWithSlackFiles(aboveThresholdWithSlackFileNames) {
    if (aboveThresholdWithSlackFileNames.length == 0) {
        return [];
    }
    let passWithSlackWhitelist = fs.readFileSync(PASS_WITH_SLACK_WHITELIST_FILE, "utf8").trim();
    if (passWithSlackWhitelist.length == 0) {
        return aboveThresholdWithSlackFileNames;
    }

    passWithSlackWhitelist = new Set(passWithSlackWhitelist.split("\n"));
    return aboveThresholdWithSlackFileNames.filter(fileName => !passWithSlackWhitelist.has(fileName));
}

function parseCoverageDetails(rawCoveragePercentText) {
    const match = COVERAGE_TABLE_COVERAGE_FRACTION_REGEXP.exec(rawCoveragePercentText);

    if (match) {
        return {
            coveredUnits: parseInt(match[1]),
            totalUnits: parseInt(match[2]),
        }
    }
    throw new Error(`Unparseable input: ${rawCoveragePercentText}`);
}

function parseCoverageTableRow(rawRowText) {
    const cols = rawRowText.split(COVERAGE_TABLE_COLUMN_DELIM);
    if (cols.length - 2 !== NUM_COLUMNS) return null;

    const c = cols.slice(1, -1).map(s => s.trim());
    const fileName = c[0];

    const excluded = [...FUNCTION_EXCLUSION_LIST]
        .filter(tag => {
            if (tag.includes("#")) {
                const [path, fn] = tag.split("#");
                if (path === "" && fn) return true;
                return tag === `${fileName}#${fn}`;
            }
            return false;
        }).length;

    const lineCoverage = parseCoverageDetails(c[1]);
    const statementCoverage = parseCoverageDetails(c[2]);

    const rawBranch = parseCoverageDetails(c[3]);
    const branchTotal = Math.max(rawBranch.totalUnits - excluded, 0);
    const branchCoverage = {
        coveredUnits: Math.min(rawBranch.coveredUnits, branchTotal),
        totalUnits: branchTotal,
    };

    const rawFunc = parseCoverageDetails(c[4]);
    const funcTotal = Math.max(rawFunc.totalUnits - excluded, 0);
    const functionCoverage = {
        coveredUnits: Math.min(rawFunc.coveredUnits, funcTotal),
        totalUnits: funcTotal,
    };

    return {
        fileName,
        lineCoverage,
        statementCoverage,
        branchCoverage,
        functionCoverage,
        _origCols: c,
        _excluded: excluded,
    };
}

function getCoverageLevel(coverageDetail, minCoveragePercent) {
    let coveragePercent = 100;
    if (coverageDetail.totalUnits > 0) {
        coveragePercent = (coverageDetail.coveredUnits / coverageDetail.totalUnits) * 100;
    }

    if (coveragePercent >= minCoveragePercent) {
        return CoverageLevel.MEETS_MINIMUM;
    } else if (coverageDetail.totalUnits <= TOTAL_UNITS_SLACK_THRESHOLD && (coveragePercent >= minCoveragePercent - COVERAGE_SLACK_PERCENTAGE)) {
        return CoverageLevel.MEETS_MINIMUM_WITH_SLACK;
    }
    return CoverageLevel.DOES_NOT_MEET_MINIMUM;
}

function getFileCoverageLevel(coverageRow) {
    return Math.min(
        getCoverageLevel(coverageRow.lineCoverage, MIN_REQUIRED_LINE_COVERAGE_PERCENTAGE),
        getCoverageLevel(coverageRow.statementCoverage, MIN_REQUIRED_STATEMENT_COVERAGE_PERCENTAGE),
        getCoverageLevel(coverageRow.branchCoverage, MIN_REQUIRED_BRANCH_COVERAGE_PERCENTAGE),
        getCoverageLevel(coverageRow.functionCoverage, MIN_REQUIRED_FUNCTION_COVERAGE_PERCENTAGE)
    );
}

function getFormattedCoverageTableRowsTest(coverageTableRows, tableHeader) {
    const separator = '+' + '='.repeat(tableHeader.length - 2) + '+';
    return tableHeader + '\n'
        + separator + '\n'
        + coverageTableRows.join('\n') + '\n';
}

function rebuildRow(rowObj) {
    const c = [...rowObj._origCols];
    if (rowObj._excluded === 0) return "|" + c.join(" | ") + " |";

    c[3] = `${pct(rowObj.branchCoverage.coveredUnits, rowObj.branchCoverage.totalUnits)} `
        + `(${rowObj.branchCoverage.coveredUnits}/${rowObj.branchCoverage.totalUnits})`;

    c[4] = `${pct(rowObj.functionCoverage.coveredUnits, rowObj.functionCoverage.totalUnits)} `
        + `(${rowObj.functionCoverage.coveredUnits}/${rowObj.functionCoverage.totalUnits})`;

    return "|" + c.join(" | ") + " |";
}

(async function main() {
    const coverateReportFileName = process.argv[2];
    const coverageReportRawText = fs.readFileSync(coverateReportFileName, "utf8");

    let coverageTableBodyRaw = "";
    let actualTableHeader = "";
    try {
        const lines = coverageReportRawText.split('\n');
        let headerIndex = -1;

        for (let i = 0; i < lines.length; i++) {
            if (COVERAGE_TABLE_HEADER_PATTERN.test(lines[i])) {
                headerIndex = i;
                actualTableHeader = lines[i];
                break;
            }
        }

        if (headerIndex === -1) {
            throw new Error("Coverage table header not found");
        }

        coverageTableBodyRaw = lines.slice(headerIndex + 1).join('\n');
    } catch (error) {
        console.error("Unexpected coverage report format");
        console.error(error);
        process.exit(1);
    }

    const belowThresholdFiles = [];
    const aboveThresholdWithSlackFileRows = [];
    const aboveThresholdWithSlackFileNames = [];
    const aboveThresholdFiles = [];
    let totalCoverageRow = "";

    let adjLineCov = 0, adjLineTot = 0;
    let adjStmtCov = 0, adjStmtTot = 0;
    let adjBrCov   = 0, adjBrTot   = 0;
    let adjFnCov   = 0, adjFnTot   = 0;

    const allRows = coverageTableBodyRaw.split("\n");
    const coverageTableRows = allRows.filter((row, index) => {
        return row.trim() !== '' && !row.trim().startsWith('+') && !row.trim().startsWith('╰') && !row.trim().startsWith('╭');
    });

    for (const rawRow of coverageTableRows) {
        const row = parseCoverageTableRow(rawRow);
        if (!row) continue;

        if (FILE_EXCLUSION_LIST.has(row.fileName)) {
            continue;
        }

        const prettyRow = rebuildRow(row);

        if (row.fileName === COVERAGE_TABLE_TOTAL_ROW_NAME) {
            totalCoverageRow = prettyRow;
            continue;
        }

        switch (getFileCoverageLevel(row)) {
            case CoverageLevel.MEETS_MINIMUM:
                aboveThresholdFiles.push(prettyRow);
                break;
            case CoverageLevel.MEETS_MINIMUM_WITH_SLACK:
                aboveThresholdWithSlackFileRows.push(prettyRow);
                aboveThresholdWithSlackFileNames.push(row.fileName);
                break;
            case CoverageLevel.DOES_NOT_MEET_MINIMUM:
                belowThresholdFiles.push(prettyRow);
                break;
        }

        adjLineCov += row.lineCoverage.coveredUnits;
        adjLineTot += row.lineCoverage.totalUnits;

        adjStmtCov += row.statementCoverage.coveredUnits;
        adjStmtTot += row.statementCoverage.totalUnits;

        adjBrCov   += row.branchCoverage.coveredUnits;
        adjBrTot   += row.branchCoverage.totalUnits;

        adjFnCov   += row.functionCoverage.coveredUnits;
        adjFnTot   += row.functionCoverage.totalUnits;
    }

    const nonWhitelistedPassWithSlackFiles =
        getNonWhitelistedPassWithSlackFiles(aboveThresholdWithSlackFileNames);

    if (aboveThresholdFiles.length > 0) {
        console.log("Files above coverage threshold: ");
        console.log(getFormattedCoverageTableRowsTest(aboveThresholdFiles, actualTableHeader));
    }

    console.log("\nAdjusted total coverage (after exclusions):");
    console.log(
        `  Lines     : ${pct(adjLineCov,  adjLineTot )} (${adjLineCov}/${adjLineTot})\n` +
        `  Statements: ${pct(adjStmtCov, adjStmtTot)} (${adjStmtCov}/${adjStmtTot})\n` +
        `  Branches  : ${pct(adjBrCov,   adjBrTot  )} (${adjBrCov}/${adjBrTot})\n` +
        `  Functions : ${pct(adjFnCov,   adjFnTot  )} (${adjFnCov}/${adjFnTot})`
    );

    const hasCoverageViolation = belowThresholdFiles.length > 0 || nonWhitelistedPassWithSlackFiles.length > 0;
    if (hasCoverageViolation) {
        if (belowThresholdFiles.length > 0) {
            console.error("\nFiles below minimum coverage threshold:");
            console.error(getFormattedCoverageTableRowsTest(belowThresholdFiles, actualTableHeader));
        }
        if (nonWhitelistedPassWithSlackFiles.length > 0) {
            console.error("\nFiles meeting threshold only with slack and not whitelisted:");
            for (const file of nonWhitelistedPassWithSlackFiles) {
                console.error("  -", file);
            }
        }
        process.exit(2);
    }
})();
