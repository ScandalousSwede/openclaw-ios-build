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
      // Reject control characters in external artifact names; this is an exclusion contract.
      // eslint-disable-next-line no-control-regex
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
