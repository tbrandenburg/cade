// Loaded via `node-red --settings /opt/node-red/settings.js`. Everything not
// set here falls back to Node-RED's built-in defaults.
//
// NO adminAuth on purpose: this process binds to 127.0.0.1 inside the
// workspace container and is only reachable through Coder's authenticated
// agent proxy (Issue #60 §1). Adding a second login here would be redundant
// and would break the proxied deep-link.
//
// The base path is normally left at the default ("/") — see
// docker-workspace/main.tf's coder_script.nodered comment for why: Coder's
// real path-based coder_app proxy strips the `/@owner/ws.../apps/nodered`
// prefix before forwarding, and Node-RED's own HTML emits relative asset
// paths, so root-mounting it works correctly through that stripped-prefix
// proxy without any prefix configuration at all. NODE_RED_BASE_PATH is kept
// as an override for other deployment shapes (e.g. a future wildcard-DNS
// subdomain=true setup, or running this file outside Coder entirely).
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
