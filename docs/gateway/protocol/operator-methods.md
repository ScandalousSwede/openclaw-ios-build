---
summary: "Operator helper methods, exec approvals, and agent delivery fallback"
read_when:
  - Building an operator surface on top of the Gateway
  - Resolving exec approvals from a client
  - Requesting outbound delivery from an agent run
title: "Gateway protocol operator methods"
sidebarTitle: "Operator methods"
doc-schema-version: 1
---

Methods an operator client calls on behalf of a person: helper reads, exec approval resolution, and delivery behavior for agent runs.

## Operator helper methods

- `commands.list` (`operator.read`) fetches the runtime command inventory for
  an agent.
  - `agentId` is optional; omit it to read the default agent workspace.
  - `scope` controls which surface the primary `name` targets: `text` returns
    the primary text command token without the leading `/`; `native` and the
    default `both` path return provider-aware native names when available.
  - `textAliases` carries exact slash aliases such as `/model` and `/m`.
  - `nativeName` carries the provider-aware native command name when one
    exists.
  - `provider` is optional and only affects native naming plus native plugin
    command availability.
  - `includeArgs=false` omits serialized argument metadata from the response.
- `tools.catalog` (`operator.read`) fetches the runtime tool catalog for an
  agent. The response includes grouped tools and provenance metadata:
  - `source`: `core` or `plugin`
  - `pluginId`: plugin owner when `source="plugin"`
  - `optional`: whether a plugin tool is optional
- `tools.effective` (`operator.read`) fetches the runtime-effective tool
  inventory for a session.
  - `sessionKey` is required.
  - The gateway derives trusted runtime context from the session server-side
    instead of accepting caller-supplied auth or delivery context.
  - The response is a session-scoped server-derived projection of the active
    inventory, including core, plugin, channel, and already-discovered MCP
    server tools.
  - `tools.effective` is read-only for MCP: it may project a warm session MCP
    catalog through the final tool policy, but does not create MCP runtimes,
    connect transports, or issue `tools/list`. If no matching warm catalog
    exists, the response may include a notice such as `mcp-not-yet-connected`,
    `mcp-not-yet-listed`, or `mcp-stale-catalog`.
  - Effective tool entries use `source="core"`, `source="plugin"`,
    `source="channel"`, or `source="mcp"`.
- `tools.invoke` (`operator.write`) invokes one available tool through the
  same gateway policy path as `/tools/invoke`.
  - `name` is required. `args`, `sessionKey`, `agentId`, `confirm`, and
    `idempotencyKey` are optional.
  - If both `sessionKey` and `agentId` are present, the resolved session agent
    must match `agentId`.
  - Owner-only core wrappers such as `cron`, `gateway`, and `nodes` require
    owner/admin identity (`operator.admin`) even though `tools.invoke` itself
    is `operator.write`.
  - The response is an SDK-facing envelope with `ok`, `toolName`, optional
    `output`, and typed `error` fields. Approval or policy refusals return
    `ok:false` in the payload rather than bypassing the gateway tool policy
    pipeline.
- `skills.status` (`operator.read`) fetches the visible skill inventory for an
  agent.
  - `agentId` is optional; omit it to read the default agent workspace.
  - The response includes eligibility, missing requirements, config checks,
    and sanitized install options without exposing raw secret values.
- `skills.search` and `skills.detail` (`operator.read`) return ClawHub
  discovery metadata.
- `skills.upload.begin`, `skills.upload.chunk`, and `skills.upload.commit`
  (`operator.admin`) stage a private skill archive before installing it. This
  is a separate admin upload path for trusted clients, not the normal ClawHub
  skill install flow, and is disabled by default unless
  `skills.install.allowUploadedArchives` is enabled.
  - `skills.upload.begin({ kind: "skill-archive", slug, sizeBytes, sha256?, force?, idempotencyKey? })`
    creates an upload bound to that slug and force value.
  - `skills.upload.chunk({ uploadId, offset, dataBase64 })` appends bytes at
    the exact decoded offset.
  - `skills.upload.commit({ uploadId, sha256? })` verifies the final size and
    SHA-256. Commit only finalizes the upload; it does not install the skill.
  - Uploaded skill archives are zip archives containing a `SKILL.md` root. The
    archive's internal directory name never selects the install target.
- `skills.install` (`operator.admin`) has three modes:
  - ClawHub mode: `{ source: "clawhub", slug, version?, force? }` installs a
    skill folder into the default agent workspace `skills/` directory.
  - Upload mode: `{ source: "upload", uploadId, slug, force?, sha256?, timeoutMs? }`
    installs a committed upload into the default agent workspace
    `skills/<slug>` directory. The slug and force value must match the
    original `skills.upload.begin` request. Rejected unless
    `skills.install.allowUploadedArchives` is enabled; the setting does not
    affect ClawHub installs.
  - Gateway installer mode: `{ name, installId, timeoutMs? }` runs a declared
    `metadata.openclaw.install` action on the gateway host. Older clients may
    still send `dangerouslyForceUnsafeInstall`; this field is deprecated,
    accepted only for protocol compatibility, and ignored. Use
    `security.installPolicy` for operator-owned install decisions.
- `skills.update` (`operator.admin`) has two modes:
  - ClawHub mode updates one tracked slug or all tracked ClawHub installs in
    the default agent workspace. Updates that would replace a skill directory
    whose installed files no longer match the recorded install digests are
    refused; the per-skill failure in `details.results` carries
    `code: "force_required"`. Retry with the optional `force: true` parameter
    to replace such a skill anyway.
  - Config mode patches `skills.entries.<skillKey>` values such as `enabled`,
    `apiKey`, and `env`.

### `models.list` views

`models.list` accepts an optional `view` parameter
(`src/agents/model-catalog-visibility.ts`):

- Omitted or `"default"`: if `agents.defaults.modelPolicy.allow` is configured, the
  response is the allowed catalog, including dynamically discovered models
  for `provider/*` entries. Otherwise the response is the full gateway
  catalog.
- `"configured"`: picker-sized behavior. If `agents.defaults.modelPolicy.allow` is
  configured, it still wins, including provider-scoped discovery for
  `provider/*` entries. Without an allowlist, the response uses explicit
  `models.providers.<provider>.models` entries, falling back to the full
  catalog only when no configured model rows exist.
- `"provider-config"`: source-authored `models.providers.*.models` inventory,
  independent of picker allowlists. Rows include public model capabilities and
  route-aware availability, but omit provider endpoints, auth material, and
  runtime request configuration.
- `"all"`: full gateway catalog, bypassing `agents.defaults.modelPolicy.allow`. Use for
  diagnostics/discovery UIs, not normal model pickers.

Two optional controls separate automatic reads from operator-requested discovery:

- `preparedOnly: true` reuses the current prepared catalog or a completed catalog for that
  runtime generation without starting provider discovery. Control UI startup and polling use
  this mode.
- `refresh: true` replaces a completed full catalog when the selected view requires discovery.
  Concurrent refreshes share one build; a failed refresh leaves the previous completed catalog
  available and returns the failure to the caller.

`preparedOnly: true` and `refresh: true` are mutually exclusive because one forbids discovery
while the other requests it.

## Exec approvals

- When an exec request needs approval, the gateway broadcasts
  `exec.approval.requested`.
- Operator clients resolve by calling `exec.approval.resolve` (requires
  `operator.approvals`).
- For `host=node`, `exec.approval.request` must include `systemRunPlan`
  (canonical `argv`/`cwd`/`rawCommand`/session metadata). Requests missing
  `systemRunPlan` are rejected.
- After approval, forwarded `node.invoke system.run` calls reuse that
  canonical `systemRunPlan` as the authoritative command/cwd/session context.
- If a caller mutates `command`, `rawCommand`, `cwd`, `agentId`, or
  `sessionKey` between prepare and the final approved `system.run` forward,
  the gateway rejects the run instead of trusting the mutated payload.

## Canonical artifact review

An existing external canonical writer can expose artifact review through the
`artifact_review` branch of `plugin.approval.request`, `plugin.approval.list`, and
`plugin.approval.resolve`. Configure the trusted helper explicitly:

```json 5
{
  "gateway": {
    "artifactReview": {
      "command": "/usr/local/bin/artifact-review-helper",
      "args": [],
      "timeoutMs": 5000
    }
  }
}
```

The command must be absolute. Arguments are fixed configuration, limited to 32
entries of 4096 characters each; timeout defaults to 5000ms and accepts 100–15000ms.
Restart the Gateway after changing this startup configuration. Omission disables
artifact request/resolution; listing returns `{ available: false, items: [] }`.

Requests contain `kind: "artifact_review"`, `binding`, `idempotency_key`, `title`
(1–80 characters), and `description` (1–512 characters). The binding contains
`operation_id`, `event_id`, and 1–64 unique lowercase SHA-256 strings in
`artifact_sha 256`. Identifiers use 1–512 letters, digits, underscores, periods,
colons, or hyphens. Resolution replaces the display fields with the exact review
`id` and `decision: "accept_artifact"` or `"reject_artifact"`. Execution permission
values and channel-reviewer claims are rejected. List selects only
`{ kind: "artifact_review" }` and returns at most 100 unexpired authorized records.

The authenticated connection must be an operator with a paired device and
`operator.approvals` or `operator.admin`. Current profile restrictions still
apply: a session-isolated profile cannot use these sessionless artifact records;
the existing administrator override is preserved. Caller-supplied actor or owner
claims never establish authority.

The helper receives bounded JSON on stdin: `method`, the authenticated `actor`
(`device_id`, `connection_id`, `scopes`), and `command` for request/resolution.
Input and output each have a 65536-byte limit. The helper owns durable requester
and reviewer authorization, expiry, current event/artifact binding, and atomic
idempotency. It must commit before returning a receipt with `id`, `binding`,
`actor_device_id`, `canonical_event_id`, `idempotency_key`, and `state` (`pending`,
`accepted`, or `rejected`). List returns `{ items }`; every item includes `id`,
`binding`, positive `created_at_ms`, later `expires_at_ms`,
`requested_by_device_id`, and up to 64 `reviewer_device_ids`.

These records stay with the canonical writer. They do not create execution
approval records, grant permission to run a tool, or establish a named person's
acceptance. Ordinary plugin approval requests keep their existing manager,
channel delivery, push notifications, and decision behavior.

A helper timeout terminates the process before releasing admitted request
ownership. An error can follow a committed effect: reconcile or retry the exact
same command and idempotency key instead of inventing a new request. While the
Gateway drains, an external artifact review cannot borrow an execution
approval's continuation ownership; retry after readiness. Private helper error
text is never returned to the client.

## Agent delivery fallback

- `agent` requests can include `deliver=true` to request outbound delivery.
- `bestEffortDeliver=false` (the default) keeps strict behavior: unresolved or
  internal-only delivery targets return `INVALID_REQUEST`.
- `bestEffortDeliver=true` allows fallback to session-only execution when no
  external deliverable route can be resolved (for example internal/webchat
  sessions or ambiguous multi-channel configs).
- Final `agent` results may include `result.deliveryStatus` when delivery was
  requested, using the same `sent`, `suppressed`, `partial_failed`, and
  `failed` statuses documented for
  [`openclaw agent --json --deliver`](/cli/agent#json-delivery-status).
