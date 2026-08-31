// Loaded via `node-red --settings /opt/node-red/settings.js`. Everything not
// set here falls back to Node-RED's built-in defaults.
//
// NO adminAuth on purpose: this process binds to 127.0.0.1 inside the
// workspace container and is only reachable through Coder's authenticated
// agent proxy (Issue #60 §1). Adding a second login here would be redundant
// and would break the proxied deep-link.
//
// The base path is resolved at container RUNTIME by the coder_script that
// launches this process (docker-workspace/main.tf, coder_script.nodered),
// not baked in at Terraform-render time — see Issue #60 Task 2/Task 4 notes
// on the `coder rename` rebuild-risk this avoids.
const base = process.env.NODE_RED_BASE_PATH || "/";

module.exports = {
    uiHost: "127.0.0.1",
    uiPort: parseInt(process.env.NODE_RED_PORT || "1880", 10),
    httpAdminRoot: base,
    httpNodeRoot: base + "api/",
    userDir: process.env.NODE_RED_USER_DIR || "/home/coder/.node-red",
    // Global npm root, NOT userDir — confirmed live via `npm root -g` in the
    // built image (see docs/milestone-reports/issue-60-jupyter-nodered.md):
    // lets the dashboard/agent palette nodes be discovered with zero network
    // access needed on a fresh, empty home volume.
    nodesDir: process.env.NODE_RED_NODES_DIR || "/usr/lib/node_modules",
    credentialSecret: process.env.NODE_RED_CREDENTIAL_SECRET || undefined,
    ui: { path: "dashboard" },
    logging: { console: { level: "info", metrics: false, audit: false } },
};
