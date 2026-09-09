import { operationalResponseSchemas } from "./operational-schemas.ts";
import type { Page, DetailResponse } from "./operational-schemas.ts";
export type {
  Artifact,
  Operation,
  Page,
  WorkContract,
  ReviewHistory,
  DetailResponse,
} from "./operational-schemas.ts";

const {
  list: pageSchema,
  detail: detailSchema,
  artifact: artifactResponseSchema,
} = operationalResponseSchemas;

export function parsePage(value: unknown): Page {
  const page = pageSchema.parse(value);
  const cursorMatches = page.coverage.has_more
    ? page.next_cursor !== null && page.next_cursor.length > 0
    : page.next_cursor === null;
  if (!cursorMatches || (page.coverage.complete && page.coverage.has_more)) {
    throw new Error("Page coverage mismatch");
  }
  return page;
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
  if (detail.requested.operation_id !== requestedId) {
    throw new Error("Operation identity mismatch");
  }
  if (requestedEventId !== undefined && detail.requested.event_id !== requestedEventId) {
    throw new Error("Event identity mismatch");
  }
  // Both canonical producers scope a detail chain to one project/source/task;
  // federation corrections may change operation/event IDs within that chain.
  if (
    [detail.item, ...detail.timeline].some(
      (observation) =>
        observation.task_id !== detail.requested.task_id ||
        observation.source !== detail.requested.source ||
        observation.project !== detail.requested.project,
    )
  ) {
    throw new Error("Detail scope mismatch");
  }
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
  const verification = contract?.independent_verification;
  if (verification?.covers_all_current_artifacts) {
    const verifiedHashes = new Set(
      verification.artifacts.map((receipt) => receipt.artifact_sha256),
    );
    // The canonical projection has one current PASS receipt per current artifact.
    // A claimed aggregate cannot substitute for that complete bound receipt set.
    if (
      !hashes.size ||
      verifiedHashes.size !== hashes.size ||
      verification.artifacts.length !== verifiedHashes.size ||
      verification.artifacts.some((receipt) => receipt.outcome !== "PASS")
    ) {
      throw new Error("Verification coverage mismatch");
    }
  }
  const context = detail.item.artifact_context;
  if (
    context?.relation === "previous_attempt" &&
    contract?.independent_verification.covers_all_current_artifacts
  ) {
    throw new Error("Previous attempt cannot establish current proof");
  }
  if (
    context?.relation === "previous_attempt" &&
    (!context.current_attempt_id ||
      !context.artifact_attempt_id ||
      context.current_attempt_id === context.artifact_attempt_id)
  ) {
    throw new Error("Artifact attempt mismatch");
  }
  if (
    context?.relation === "current_attempt" &&
    (!context.current_attempt_id || context.current_attempt_id !== context.artifact_attempt_id)
  ) {
    throw new Error("Artifact attempt mismatch");
  }
  if (
    contract?.continuation.artifact_context &&
    JSON.stringify(contract.continuation.artifact_context) !== JSON.stringify(context)
  ) {
    throw new Error("Continuation artifact attempt mismatch");
  }
  for (const review of detail.review_history?.items ?? []) {
    const reviewHashes = new Set(review.binding.artifact_sha256);
    if (
      review.binding.operation_id !== detail.item.operation_id ||
      reviewHashes.size !== review.binding.artifact_sha256.length ||
      (review.state === "pending") !== (review.disposition === null)
    ) {
      throw new Error("Review history identity mismatch");
    }
    if (
      review.binding_relation === "current" &&
      (context?.relation !== "current_attempt" ||
        review.binding.event_id !== detail.item.event_id ||
        reviewHashes.size !== hashes.size ||
        [...reviewHashes].some((hash) => !hashes.has(hash)))
    ) {
      throw new Error("Review history current binding mismatch");
    }
  }
  return detail;
}
