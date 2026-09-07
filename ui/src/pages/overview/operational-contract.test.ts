import { describe, expect, it } from "vitest";
import fixtures from "./operational-contract.fixtures.json" with { type: "json" };
import schema from "./operational-contract.schema.json" with { type: "json" };
import {
  createOperationalContractJsonSchema,
  parseArtifactResponse,
  parseDetail,
  parsePage,
} from "./operational-contract.ts";

describe("existing operational response contract", () => {
  it("keeps the shared Python schema identical to its typed source", () => {
    expect(schema).toEqual(createOperationalContractJsonSchema());
  });
  it.each(fixtures)("accepts actual synthetic Python responses: $name", (fixture) => {
    expect(parsePage(fixture.list).items.length).toBeGreaterThan(0);
    const detail = parseDetail(fixture.detail, fixture.requested_operation_id);
    expect(parseArtifactResponse(fixture.artifact).sha256).toBe(detail.item.artifacts[0]?.sha256);
    if (fixture.name === "ordinary-previous-attempt") {
      expect(detail.item.artifact_context?.relation).toBe("previous_attempt");
      expect(detail.work_contract?.independent_verification.covers_all_current_artifacts).toBe(
        false,
      );
    }
    if (fixture.name === "ordinary-corrected")
      expect(detail.item.artifact_context?.relation).toBe("current_attempt");
    if (fixture.name === "federation-requested-current")
      expect(detail.requested.operation_id).not.toBe(detail.item.operation_id);
  });
  it("rejects missing requested identity before rendering", () => {
    const fixture = fixtures[0]!;
    expect(() =>
      parseDetail(
        {
          ...fixture.detail,
          work_contract: { ...fixture.detail.work_contract, requested_event_id: undefined },
        },
        fixture.requested_operation_id,
      ),
    ).toThrow();
  });
  it("rejects stale current-proof claims on previous-attempt evidence", () => {
    const fixture = fixtures.find((value) => value.name === "ordinary-previous-attempt")!;
    expect(() =>
      parseDetail(
        {
          ...fixture.detail,
          work_contract: {
            ...fixture.detail.work_contract,
            independent_verification: {
              ...fixture.detail.work_contract.independent_verification,
              covers_all_current_artifacts: true,
            },
          },
        },
        fixture.requested_operation_id,
      ),
    ).toThrow();
  });
  it("rejects malformed pages and invalid declared/returned sizes", () => {
    expect(() => parsePage({ ...fixtures[0]!.list, items: "not a list" })).toThrow();
    expect(() => parseArtifactResponse({ ...fixtures[0]!.artifact, bytes: -1 })).toThrow();
    expect(() =>
      parsePage({
        ...fixtures[0]!.list,
        items: [
          { ...fixtures[0]!.list.items[0], artifacts: [{ sha256: "a".repeat(64), bytes: -1 }] },
        ],
      }),
    ).toThrow();
  });
});

it("preserves rendered scope, owner request and verification fields while stripping unrelated metadata", () => {
  const fixture = fixtures[0]!;
  const page = parsePage({
    ...fixture.list,
    unrelated_metadata: "synthetic-private-sentinel",
    coverage: {
      ...fixture.list.coverage,
      scope: {
        ...fixture.list.coverage.scope,
        source: "synthetic-source",
        recorded_from: "2026-01-01T00:00:00Z",
        recorded_before: "2026-01-02T00:00:00Z",
      },
    },
  });
  expect(page.coverage.scope.source).toBe("synthetic-source");
  expect(page.coverage.scope.recorded_from).toBe("2026-01-01T00:00:00Z");
  expect(page.coverage.observed_at).toBe(fixture.list.coverage.observed_at);
  expect(JSON.stringify(page)).not.toContain("synthetic-private-sentinel");
  const detail = parseDetail(
    {
      ...fixture.detail,
      work_contract: {
        ...fixture.detail.work_contract,
        pending_owner_feedback: [
          { event_id: "synthetic-request", owner: "Technical owner", reason: "Inspect the result" },
        ],
        structural_verification: {
          status: "passed_recorded",
          semantic_correctness_established: false,
        },
        independent_verification: {
          semantic_correctness_established: false,
          covers_all_current_artifacts: true,
          artifacts: [
            {
              event_id: "synthetic-verifier",
              outcome: "PASS",
              artifact_sha256: fixture.detail.item.artifacts[0]!.sha256,
              verifier_report_sha256: "b".repeat(64),
              verification_kind: "structural_artifact_contract",
              semantic_correctness_established: false,
            },
          ],
        },
      },
    },
    fixture.requested_operation_id,
  );
  expect(detail.work_contract?.pending_owner_feedback[0]?.reason).toBe("Inspect the result");
  expect(detail.work_contract?.structural_verification.status).toBe("passed_recorded");
  expect(detail.work_contract?.independent_verification.artifacts[0]?.verification_kind).toBe(
    "structural_artifact_contract",
  );
  expect(detail.work_contract?.owner_accepted).toBe(false);
});
