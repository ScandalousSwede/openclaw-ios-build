// Gateway Protocol schema module defines protocol validation shapes.
import { Type } from "typebox";
import { NonEmptyString } from "./primitives.js";

/**
 * Plugin approval schemas.
 *
 * These payloads cross from plugin/tool execution into reviewer-facing UI, so
 * title, description, decision set, and timeout limits are part of the public
 * gateway contract.
 */
const MAX_PLUGIN_APPROVAL_TIMEOUT_MS = 600_000;
const PLUGIN_APPROVAL_TITLE_MAX_LENGTH = 80;
const PLUGIN_APPROVAL_DESCRIPTION_MAX_LENGTH = 512;

const ArtifactReviewBindingSchema = Type.Object(
  {
    operation_id: Type.String({ pattern: "^[A-Za-z0-9_.:-]{1,512}$" }),
    event_id: Type.String({ pattern: "^[A-Za-z0-9_.:-]{1,512}$" }),
    artifact_sha256: Type.Array(Type.String({ pattern: "^[a-f0-9]{64}$" }), {
      minItems: 1,
      maxItems: 64,
      uniqueItems: true,
    }),
  },
  { additionalProperties: false },
);
const artifactFields = {
  kind: Type.Optional(Type.Literal("artifact_review")),
  binding: Type.Optional(ArtifactReviewBindingSchema),
  idempotency_key: Type.Optional(Type.String({ pattern: "^[A-Za-z0-9_.:-]{1,512}$" })),
};
const legacyApprovalArm = {
  not: { anyOf: ["kind", "binding", "idempotency_key"].map((key) => ({ required: [key] })) },
};
const artifactApprovalArm = (resolve: boolean) => ({
  required: ["kind", "binding", "idempotency_key"],
  properties: {
    kind: { const: "artifact_review" },
    binding: {},
    idempotency_key: {},
    ...(resolve
      ? { id: {}, decision: { enum: ["accept_artifact", "reject_artifact"] } }
      : { title: {}, description: {} }),
  },
  additionalProperties: false,
});

/** Approval request raised by a plugin before a sensitive tool action proceeds. */
export const PluginApprovalRequestParamsSchema = Type.Object(
  {
    ...artifactFields,
    pluginId: Type.Optional(NonEmptyString),
    title: Type.String({ minLength: 1, maxLength: PLUGIN_APPROVAL_TITLE_MAX_LENGTH }),
    description: Type.String({ minLength: 1, maxLength: PLUGIN_APPROVAL_DESCRIPTION_MAX_LENGTH }),
    severity: Type.Optional(Type.String({ enum: ["info", "warning", "critical"] })),
    toolName: Type.Optional(Type.String()),
    toolCallId: Type.Optional(Type.String()),
    allowedDecisions: Type.Optional(
      Type.Array(Type.String({ enum: ["allow-once", "allow-always", "deny"] }), {
        minItems: 1,
        maxItems: 3,
      }),
    ),
    agentId: Type.Optional(Type.String()),
    sessionKey: Type.Optional(Type.String()),
    approvalReviewerDeviceIds: Type.Optional(
      Type.Array(NonEmptyString, {
        description:
          "Trusted approval-runtime metadata naming operator devices that may review this approval; ordinary Gateway clients may send the field, but the Gateway only binds it for internal approval-runtime requests.",
      }),
    ),
    turnSourceChannel: Type.Optional(Type.String()),
    turnSourceTo: Type.Optional(Type.String()),
    turnSourceAccountId: Type.Optional(Type.String()),
    turnSourceThreadId: Type.Optional(Type.Union([Type.String(), Type.Number()])),
    timeoutMs: Type.Optional(Type.Integer({ minimum: 1, maximum: MAX_PLUGIN_APPROVAL_TIMEOUT_MS })),
    twoPhase: Type.Optional(Type.Boolean()),
  },
  { additionalProperties: false, anyOf: [legacyApprovalArm, artifactApprovalArm(false)] },
);

/** Reviewer decision payload resolving one pending plugin approval request. */
export const PluginApprovalResolveParamsSchema = Type.Object(
  {
    ...artifactFields,
    id: NonEmptyString,
    decision: NonEmptyString,
  },
  { additionalProperties: false, anyOf: [legacyApprovalArm, artifactApprovalArm(true)] },
);
