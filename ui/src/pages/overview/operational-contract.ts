import { z } from "zod";

const identity = z.string().min(1).max(300);
const digest = z.string().regex(/^[0-9a-f]{64}$/);
const artifactSchema = z.object({
  display_name: z
    .string()
    .min(1)
    .refine((value) => Array.from(value).length <= 160)
    .meta({ maxLength: 160 })
    .regex(
      /^(?!\.{1,2}$)(?![\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]*$)[^/\\\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]+$/u,
    )
    .optional(),
  sha256: digest,
  bytes: z.number().int().nonnegative().nullable(),
});
const artifactContextSchema = z.object({
  relation: z.enum(["current_attempt", "previous_attempt", "federation_observation", "unknown"]),
  current_attempt_id: z.string().nullable(),
  artifact_attempt_id: z.string().nullable(),
});
const operationSchema = z.object({
  operation_id: identity,
  task_id: z.string(),
  event_id: identity,
  title: z.string(),
  project: z.enum(["Argus", "MiKobots", "EPC"]).optional(),
  native: z
    .object({
      adapter: z.string().max(200),
      native_event: z.string().max(200),
      outcome: z.string().max(200).nullable(),
      session_id: z.string().max(200),
      turn_id: z.string().max(200).nullable(),
      item_id: z.string().max(200).nullable(),
    })
    .nullable()
    .optional(),
  display: z
    .object({
      label: z.string().min(1).max(160),
      change_summary: z.string().min(1).max(500).optional(),
      artifact_label: z.string().min(1).max(160).optional(),
      continuation_label: z.string().min(1).max(160).optional(),
    })
    .strict()
    .optional(),
  source: z.string(),
  kind: z.string(),
  state: z.string(),
  occurred_at: z.string(),
  observed_at: z.string(),
  artifacts: z.array(artifactSchema),
  owner_accepted: z.literal(false),
  evidence_scope: z.string().optional(),
  executor_id: z.string().nullable().optional(),
  capability_id: z.string().nullable().optional(),
  artifact_context: artifactContextSchema.optional(),
});
const workContractSchema = z.object({
  schema: z.literal("argus.work.read-contract.v1"),
  operation_id: identity,
  requested_operation_id: identity,
  requested_event_id: identity,
  latest_event_id: identity,
  native_observations: z.array(
    z.object({
      event_id: identity,
      adapter: z.string().nullable(),
      outcome: z.string().nullable(),
    }),
  ),
  structural_verification: z.object({
    status: z.enum(["not_established", "passed_recorded", "failed_recorded"]),
    semantic_correctness_established: z.literal(false),
  }),
  independent_verification: z.object({
    semantic_correctness_established: z.boolean().optional(),
    artifacts: z.array(
      z.object({
        event_id: identity,
        outcome: z.enum(["PASS", "FAIL"]),
        artifact_sha256: digest,
        verifier_report_sha256: digest,
        verification_kind: z.string().optional(),
        semantic_correctness_established: z.boolean().optional(),
      }),
    ),
    covers_all_current_artifacts: z.boolean(),
  }),
  owner_disposition: z.object({ status: z.literal("not_established") }),
  owner_accepted: z.literal(false),
  pending_owner_feedback: z.array(
    z.object({ event_id: identity, owner: z.string().nullable(), reason: z.string().nullable() }),
  ),
  continuation: z.object({
    mode: z.literal("read_only"),
    action: z.literal("inspect_current_evidence"),
    operation_id: identity,
    event_id: identity,
    artifact_sha256: z.array(digest),
    dispatch_enabled: z.literal(false),
    artifact_context: artifactContextSchema.optional(),
  }),
  coverage: z.object({
    scope: z.enum(["canonical_operation_trace", "canonical_federation_observation"]),
    complete: z.boolean(),
    cross_scope_absence_established: z.literal(false),
  }),
  is_state_transition: z.literal(false),
});
const snapshotReadSchema = z
  .object({
    snapshot_age_seconds: z.number().finite().min(-30).optional(),
  })
  .optional();
const pageSchema = z.object({
  _authority_read: snapshotReadSchema,
  items: z.array(operationSchema),
  next_cursor: z.string().nullable(),
  coverage: z.object({
    scope: z.object({
      corpus: z.string(),
      project: z.string(),
      task_id: z.string().nullable().optional(),
      source: z.string().nullable().optional(),
      recorded_from: z.string().nullable().optional(),
      recorded_before: z.string().nullable().optional(),
    }),
    complete: z.boolean(),
    has_more: z.boolean(),
    snapshot_sequence: z.number().int().nonnegative(),
    observed_at: z.string(),
  }),
});
const reviewIdentity = z.string().regex(/^[A-Za-z0-9_.:-]{1,512}$/);
const reviewHistorySchema = z
  .object({
    items: z
      .array(
        z
          .object({
            id: reviewIdentity,
            request_event_id: reviewIdentity,
            binding: z
              .object({
                operation_id: reviewIdentity,
                event_id: reviewIdentity,
                artifact_sha256: z.array(digest).min(1).max(64),
              })
              .strict(),
            state: z.enum(["pending", "accepted", "rejected"]),
            binding_relation: z.enum(["current", "previous"]),
            requested_at_ms: z.number().int().nonnegative(),
            expires_at_ms: z.number().int().nonnegative(),
            disposition: z
              .object({ event_id: reviewIdentity, recorded_at_ms: z.number().int().nonnegative() })
              .strict()
              .nullable(),
          })
          .strict(),
      )
      .max(25),
    coverage: z
      .object({
        complete: z.boolean(),
        has_more: z.boolean(),
        snapshot_sequence: z.number().int().nonnegative(),
      })
      .strict(),
    owner_accepted: z.literal(false),
  })
  .strict()
  .describe(
    "Recorded receipt-qualified artifact review history, not an actionable approval list. Pending means a qualified request with no qualified disposition recorded; expiry is request expiry only. Actionability comes only from the authenticated pending-action list.",
  );
const detailSchema = z.object({
  item: operationSchema,
  requested: operationSchema,
  timeline: z.array(operationSchema),
  work_contract: workContractSchema.optional(),
  review_history: reviewHistorySchema.optional(),
  coverage: z.object({ complete: z.boolean(), has_more: z.boolean() }),
});
const artifactResponseSchema = z.object({
  sha256: digest,
  bytes: z.number().int().min(0).max(1_048_576),
  mime_type: z.string(),
  content_base64: z.string().max(1_398_104),
  operation_id: identity.optional(),
  event_id: identity.optional(),
});

export type Artifact = z.infer<typeof artifactSchema>;
export type Operation = z.infer<typeof operationSchema>;
export type Page = z.infer<typeof pageSchema>;
export type WorkContract = z.infer<typeof workContractSchema>;
export type ReviewHistory = z.infer<typeof reviewHistorySchema>;
export type DetailResponse = z.infer<typeof detailSchema>;

export const operationalResponseSchemas = {
  list: pageSchema,
  detail: detailSchema,
  artifact: artifactResponseSchema,
};
// One neutral response contract, exported for the existing Python/plugin fixtures.
// Extra admitted backend metadata is allowed on input and stripped from UI values.
export function createOperationalContractJsonSchema() {
  const contract = {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: "urn:argus:operational-read-response:v1",
    $defs: Object.fromEntries(
      Object.entries(operationalResponseSchemas).map(([name, schema]) => [
        name,
        z.toJSONSchema(schema, { io: "input" }),
      ]),
    ),
  };
  // Cross-field constraints shared with the incumbent Python reader schema.
  const history = contract.$defs.detail.properties!.review_history as {
    properties: {
      items: {
        items: {
          properties: { binding: { properties: { artifact_sha256: { uniqueItems?: boolean } } } };
          allOf?: unknown[];
        };
      };
    };
  };
  history.properties.items.items.properties.binding.properties.artifact_sha256.uniqueItems = true;
  history.properties.items.items.allOf = [
    {
      if: { properties: { state: { const: "pending" } } },
      then: { properties: { disposition: { type: "null" } } },
      else: { properties: { disposition: { type: "object" } } },
    },
  ];
  return contract;
}

export function parsePage(value: unknown): Page {
  return pageSchema.parse(value);
}
export function parseArtifactResponse(value: unknown) {
  return artifactResponseSchema.parse(value);
}
export function parseDetail(
  value: unknown,
  requestedId: string,
  requestedEventId?: string,
): DetailResponse {
  const detail = detailSchema.parse(value);
  if (detail.requested.operation_id !== requestedId) throw new Error("Operation identity mismatch");
  if (requestedEventId !== undefined && detail.requested.event_id !== requestedEventId)
    throw new Error("Event identity mismatch");
  const contract = detail.work_contract;
  const hashes = new Set(detail.item.artifacts.map((artifact) => artifact.sha256));
  if (
    contract &&
    (contract.operation_id !== detail.item.operation_id ||
      contract.latest_event_id !== detail.item.event_id ||
      contract.requested_operation_id !== detail.requested.operation_id ||
      contract.requested_event_id !== detail.requested.event_id ||
      contract.continuation.operation_id !== detail.item.operation_id ||
      contract.continuation.event_id !== detail.item.event_id ||
      contract.continuation.artifact_sha256.some((hash) => !hashes.has(hash)) ||
      contract.independent_verification.artifacts.some(
        (verification) => !hashes.has(verification.artifact_sha256),
      ))
  ) {
    throw new Error("Work contract identity mismatch");
  }
  const context = detail.item.artifact_context;
  if (
    context?.relation === "previous_attempt" &&
    contract?.independent_verification.covers_all_current_artifacts
  )
    throw new Error("Previous attempt cannot establish current proof");
  if (
    context?.relation === "previous_attempt" &&
    (!context.current_attempt_id ||
      !context.artifact_attempt_id ||
      context.current_attempt_id === context.artifact_attempt_id)
  )
    throw new Error("Artifact attempt mismatch");
  if (
    context?.relation === "current_attempt" &&
    (!context.current_attempt_id || context.current_attempt_id !== context.artifact_attempt_id)
  )
    throw new Error("Artifact attempt mismatch");
  if (
    contract?.continuation.artifact_context &&
    JSON.stringify(contract.continuation.artifact_context) !== JSON.stringify(context)
  )
    throw new Error("Continuation artifact attempt mismatch");
  for (const review of detail.review_history?.items ?? []) {
    const reviewHashes = new Set(review.binding.artifact_sha256);
    if (
      review.binding.operation_id !== detail.item.operation_id ||
      reviewHashes.size !== review.binding.artifact_sha256.length ||
      (review.state === "pending") !== (review.disposition === null)
    )
      throw new Error("Review history identity mismatch");
    if (
      review.binding_relation === "current" &&
      (context?.relation !== "current_attempt" ||
        review.binding.event_id !== detail.item.event_id ||
        reviewHashes.size !== hashes.size ||
        [...reviewHashes].some((hash) => !hashes.has(hash)))
    )
      throw new Error("Review history current binding mismatch");
  }
  return detail;
}
