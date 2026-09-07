import { z } from "zod";

const identity = z.string().min(1).max(300);
const digest = z.string().regex(/^[0-9a-f]{64}$/);
const artifactSchema = z.object({
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
const pageSchema = z.object({
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
const detailSchema = z.object({
  item: operationSchema,
  requested: operationSchema,
  timeline: z.array(operationSchema),
  work_contract: workContractSchema.optional(),
  coverage: z.object({ complete: z.boolean(), has_more: z.boolean() }),
});
const artifactResponseSchema = z.object({
  sha256: digest,
  bytes: z.number().int().min(0).max(1_048_576),
  mime_type: z.string(),
  content_base64: z.string().max(1_398_104),
  operation_id: identity.optional(),
});

export type Artifact = z.infer<typeof artifactSchema>;
export type Operation = z.infer<typeof operationSchema>;
export type Page = z.infer<typeof pageSchema>;
export type WorkContract = z.infer<typeof workContractSchema>;
export type DetailResponse = z.infer<typeof detailSchema>;

export const operationalResponseSchemas = {
  list: pageSchema,
  detail: detailSchema,
  artifact: artifactResponseSchema,
};
// One neutral response contract, exported for the existing Python/plugin fixtures.
// Extra admitted backend metadata is allowed on input and stripped from UI values.
export function createOperationalContractJsonSchema() {
  return {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: "urn:argus:operational-read-response:v1",
    $defs: Object.fromEntries(
      Object.entries(operationalResponseSchemas).map(([name, schema]) => [
        name,
        z.toJSONSchema(schema, { io: "input" }),
      ]),
    ),
  };
}

export function parsePage(value: unknown): Page {
  return pageSchema.parse(value);
}
export function parseArtifactResponse(value: unknown) {
  return artifactResponseSchema.parse(value);
}
export function parseDetail(value: unknown, requestedId: string): DetailResponse {
  const detail = detailSchema.parse(value);
  if (detail.requested.operation_id !== requestedId) throw new Error("Operation identity mismatch");
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
  return detail;
}
