#!/usr/bin/env node
// Merges a single --add-host=host.docker.internal:<ip> entry into a cloned
// repo's own .devcontainer/devcontainer.json `runArgs` array, in place,
// without disturbing any existing comments/formatting/trailing commas
// (devcontainer.json is JSONC). Used by
// coder/templates/devcontainer/main.tf's coder_script.repo_devcontainer_hostmap
// to fix Issue #114 (the repo-provided-devcontainer.json follow-up to Issue
// #107, whose bootstrap-generated-JSON case is fixed by plain printf in
// coder_script.empty_workspace_bootstrap -- that approach doesn't work here
// because the file already exists with arbitrary user content).
//
// Usage: node merge-devcontainer-runargs.js <devcontainer.json path> <runArg>
//
// Exits 0 (no-op) if the file doesn't exist -- e.g. repo_url was empty, or
// the cloned repo has no .devcontainer/devcontainer.json at all (a
// different, already-clean failure mode handled elsewhere in main.tf).

'use strict';

const fs = require('fs');
const { parseTree, findNodeAtLocation, getNodeValue, modify, applyEdits } = require('jsonc-parser');

const [, , filePath, runArg] = process.argv;

if (!filePath || !runArg) {
  console.error('usage: merge-devcontainer-runargs.js <devcontainer.json path> <runArg>');
  process.exit(1);
}

if (!fs.existsSync(filePath)) {
  console.log(`${filePath} does not exist, nothing to patch`);
  process.exit(0);
}

const text = fs.readFileSync(filePath, 'utf8');
const tree = parseTree(text);
const runArgsNode = tree ? findNodeAtLocation(tree, ['runArgs']) : undefined;
const existingRunArgs = runArgsNode ? getNodeValue(runArgsNode) : [];

if (Array.isArray(existingRunArgs) && existingRunArgs.some((entry) => typeof entry === 'string' && entry.startsWith('--add-host=host.docker.internal:'))) {
  console.log(`${filePath} already has a host.docker.internal runArg, leaving untouched`);
  process.exit(0);
}

const newRunArgs = Array.isArray(existingRunArgs) ? [...existingRunArgs, runArg] : [runArg];
const edits = modify(text, ['runArgs'], newRunArgs, { formattingOptions: { insertSpaces: true, tabSize: 2 } });
const patched = applyEdits(text, edits);

fs.writeFileSync(filePath, patched);
console.log(`merged ${runArg} into ${filePath}`);
