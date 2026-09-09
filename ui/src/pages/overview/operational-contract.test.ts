import { assert, describe, expect, it } from "vitest";
import fixtures from "./operational-contract.fixtures.json" with { type: "json" };
import schema from "./operational-contract.schema.json" with { type: "json" };
import { createOperationalContractJsonSchema } from "./operational-contract.test-support.ts";
import { parseArtifactResponse, parseDetail, parsePage } from "./operational-contract.ts";

function required<T>(value: T | undefined): T {
  assert.isDefined(value, "Expected fixture or parsed item to exist");
  return value;
}

it("requires the exact requested event when a historical detail link names one", () => {
  const detail = required(fixtures[0]).detail;
  expect(
    parseDetail(detail, detail.requested.operation_id, detail.requested.event_id).requested
      .event_id,
  ).toBe(detail.requested.event_id);
  expect(() => parseDetail(detail, detail.requested.operation_id, "different-event")).toThrow(
    "Event identity mismatch",
  );
});

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
    if (fixture.name === "ordinary-corrected") {
      expect(detail.item.artifact_context?.relation).toBe("current_attempt");
    }
    if (fixture.name === "federation-requested-current") {
      expect(detail.requested.operation_id).not.toBe(detail.item.operation_id);
    }
  });
  it("rejects missing requested identity before rendering", () => {
    const fixture = required(fixtures[0]);
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
    const fixture = required(fixtures.find((value) => value.name === "ordinary-previous-attempt"));
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
    expect(() => parsePage({ ...required(fixtures[0]).list, items: "not a list" })).toThrow();
    expect(() => parseArtifactResponse({ ...required(fixtures[0]).artifact, bytes: -1 })).toThrow();
    expect(() =>
      parsePage({
        ...required(fixtures[0]).list,
        items: [
          {
            ...required(fixtures[0]).list.items[0],
            artifacts: [{ sha256: "a".repeat(64), bytes: -1 }],
          },
        ],
      }),
    ).toThrow();
  });
});

it("preserves rendered scope, owner request and verification fields while stripping unrelated metadata", () => {
  const fixture = required(fixtures[0]);
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
              artifact_sha256: required(fixture.detail.item.artifacts[0]).sha256,
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

it("admits only bounded display metadata without authority fields", () => {
  const fixture = structuredClone(required(fixtures[0]).list);
  const display = {
    label: "Technical result",
    change_summary: "An admitted summary",
    artifact_label: "Report",
    continuation_label: "Inspect current evidence",
  };
  expect(
    required(parsePage({ ...fixture, items: [{ ...fixture.items[0], display }] }).items[0]).display,
  ).toEqual(display);
  for (const invalid of [
    { ...display, label: "" },
    { ...display, label: "x".repeat(161) },
    { ...display, change_summary: "x".repeat(501) },
    { ...display, owner_accepted: true },
  ]) {
    expect(() =>
      parsePage({ ...fixture, items: [{ ...fixture.items[0], display: invalid }] }),
    ).toThrow();
  }
});

it("retains measured snapshot age without retaining snapshot filesystem metadata", () => {
  const page = parsePage({
    ...required(fixtures[0]).list,
    _authority_read: { snapshot_age_seconds: 123.4, snapshot_name: "not-for-ui" },
  });
  const { _authority_read: authorityRead } = page;
  expect(authorityRead).toEqual({ snapshot_age_seconds: 123.4 });
  expect(() =>
    parsePage({ ...required(fixtures[0]).list, _authority_read: { snapshot_age_seconds: -31 } }),
  ).toThrow();
});

it("preserves live-transaction reads with unknown snapshot age", () => {
  const page = parsePage({
    ...required(fixtures[0]).list,
    _authority_read: {
      canonical_source: "operational_ledger_live_read_transaction",
      read_only: true,
    },
  });
  const { _authority_read: authorityRead } = page;
  expect(authorityRead).toEqual({});
  expect(authorityRead?.snapshot_age_seconds).toBeUndefined();
});

function historyDetail() {
  const fixture = structuredClone(
    required(fixtures.find((value) => value.name === "ordinary-corrected")),
  );
  const review: {
    id: string;
    request_event_id: string;
    binding: { operation_id: string; event_id: string; artifact_sha256: string[] };
    state: string;
    binding_relation: string;
    requested_at_ms: number;
    expires_at_ms: number;
    disposition: { event_id: string; recorded_at_ms: number } | null;
  } = {
    id: "review-one",
    request_event_id: "request-one",
    binding: {
      operation_id: fixture.detail.item.operation_id,
      event_id: fixture.detail.item.event_id,
      artifact_sha256: fixture.detail.item.artifacts.map((artifact) => artifact.sha256),
    },
    state: "pending",
    binding_relation: "current",
    requested_at_ms: 100,
    expires_at_ms: 200,
    disposition: null,
  };
  return {
    ...fixture.detail,
    review_history: {
      items: [review],
      coverage: { complete: true, has_more: false, snapshot_sequence: 7 },
      owner_accepted: false,
    },
  };
}
it("retains bounded operator history without promoting earlier bindings or owner authority", () => {
  const detail = historyDetail();
  for (const state of ["pending", "accepted", "rejected"]) {
    required(detail.review_history.items[0]).state = state;
    required(detail.review_history.items[0]).disposition =
      state === "pending" ? null : { event_id: "disposition-one", recorded_at_ms: 150 };
    expect(parseDetail(detail, detail.requested.operation_id).review_history?.items[0]?.state).toBe(
      state,
    );
  }
  required(detail.review_history.items[0]).binding_relation = "previous";
  required(detail.review_history.items[0]).binding.event_id = "earlier-event";
  required(detail.review_history.items[0]).binding.artifact_sha256 = ["f".repeat(64)];
  expect(
    parseDetail(detail, detail.requested.operation_id).review_history?.items[0]?.binding_relation,
  ).toBe("previous");
  expect(parseDetail(detail, detail.requested.operation_id).review_history?.owner_accepted).toBe(
    false,
  );
});
it("rejects malformed, foreign and false-current operator history", () => {
  const mutations = [
    (d: ReturnType<typeof historyDetail>) => {
      required(d.review_history.items[0]).binding.operation_id = "foreign";
    },
    (d: ReturnType<typeof historyDetail>) => {
      required(d.review_history.items[0]).binding.event_id = "older";
    },
    (d: ReturnType<typeof historyDetail>) => {
      required(d.review_history.items[0]).binding.artifact_sha256 = ["f".repeat(64)];
    },
    (d: ReturnType<typeof historyDetail>) => {
      required(d.review_history.items[0]).binding.artifact_sha256.push(
        required(required(d.review_history.items[0]).binding.artifact_sha256[0]),
      );
    },
    (d: ReturnType<typeof historyDetail>) => {
      required(d.review_history.items[0]).state = "accepted";
    },
    (d: ReturnType<typeof historyDetail>) => {
      required(d.review_history.items[0]).disposition = {
        event_id: "unexpected",
        recorded_at_ms: 150,
      };
    },
    (d: ReturnType<typeof historyDetail>) => {
      d.review_history.items = Array.from({ length: 26 }, () =>
        required(d.review_history.items[0]),
      );
    },
    (d: ReturnType<typeof historyDetail>) => {
      d.review_history.owner_accepted = true;
    },
  ];
  for (const mutate of mutations) {
    const detail = historyDetail();
    mutate(detail);
    expect(() => parseDetail(detail, detail.requested.operation_id)).toThrow();
  }
  expect(
    parseDetail(required(fixtures[0]).detail, required(fixtures[0]).requested_operation_id)
      .review_history,
  ).toBeUndefined();
});

it("accepts bounded artifact basenames and rejects paths, controls and bidi labels", () => {
  const fixture = required(fixtures[0]).list;
  for (const display_name of [
    "native-test-receipt.json",
    "Screenshot QA.json",
    "résultat.json",
    "<img>.txt",
  ]) {
    expect(
      required(
        required(
          parsePage({
            ...fixture,
            items: [
              {
                ...fixture.items[0],
                artifacts: [{ sha256: "a".repeat(64), bytes: 3, display_name }],
              },
            ],
          }).items[0],
        ).artifacts[0],
      ).display_name,
    ).toBe(display_name);
  }
  for (const display_name of [
    "",
    ".",
    "..",
    "   ",
    "\ufeff",
    "../receipt.json",
    "folder/receipt.json",
    "folder\\receipt.json",
    "bad\nname",
    "bad\u0000name",
    "bad\u0085name",
    "bad\u202ename",
    "bad\u2066name",
    "bad\u200fname",
    "bad\u061cname",
    "x".repeat(161),
    3,
    null,
  ]) {
    expect(() =>
      parsePage({
        ...fixture,
        items: [
          { ...fixture.items[0], artifacts: [{ sha256: "a".repeat(64), bytes: 3, display_name }] },
        ],
      }),
    ).toThrow();
  }
  expect(required(parsePage(fixture).items[0]).artifacts[0]?.display_name).toBeUndefined();
});

it("counts artifact display names as Unicode code points like the shared JSON schema", () => {
  const fixture = required(fixtures[0]).list;
  const named = (display_name: string) => ({
    ...fixture,
    items: [
      { ...fixture.items[0], artifacts: [{ sha256: "a".repeat(64), bytes: 3, display_name }] },
    ],
  });
  expect(
    required(required(parsePage(named("😀".repeat(160))).items[0]).artifacts[0]).display_name,
  ).toBe("😀".repeat(160));
  expect(() => parsePage(named("😀".repeat(161)))).toThrow();
});

it.each(["empty", "failed", "partial", "duplicate"])(
  "rejects a complete verification claim with %s receipts",
  (mode) => {
    const detail = structuredClone(required(fixtures[0]).detail);
    const artifact = required(detail.item.artifacts[0]);
    const receipt = {
      event_id: "verifier",
      outcome: "PASS" as const,
      artifact_sha256: artifact.sha256,
      verifier_report_sha256: "d".repeat(64),
    };
    const rows =
      mode === "empty"
        ? []
        : mode === "failed"
          ? [
              { ...receipt, outcome: "FAIL" as const },
              { ...receipt, event_id: "second", artifact_sha256: "c".repeat(64) },
            ]
          : mode === "partial"
            ? [receipt]
            : [receipt, { ...receipt, event_id: "duplicate" }];
    const candidate = {
      ...detail,
      item: { ...detail.item, artifacts: [artifact, { ...artifact, sha256: "c".repeat(64) }] },
      work_contract: {
        ...detail.work_contract,
        independent_verification: { covers_all_current_artifacts: true, artifacts: rows },
      },
    };
    expect(() => parseDetail(candidate, detail.requested.operation_id)).toThrow(/coverage/i);
    expect(
      parseDetail(
        {
          ...candidate,
          work_contract: {
            ...candidate.work_contract,
            independent_verification: {
              ...candidate.work_contract.independent_verification,
              covers_all_current_artifacts: false,
            },
          },
        },
        detail.requested.operation_id,
      ).work_contract?.independent_verification.covers_all_current_artifacts,
    ).toBe(false);
  },
);

describe("operational scope and continuation consistency", () => {
  it.each(["task_id", "source", "project"] as const)(
    "rejects current and historical observations with a different %s",
    (field) => {
      const fixture = required(
        fixtures.find((value) => value.name === "federation-requested-current"),
      );
      const different =
        field === "project"
          ? "project" in fixture.detail.requested && fixture.detail.requested.project === "Argus"
            ? "EPC"
            : "Argus"
          : "different-identity";
      expect(() =>
        parseDetail(
          { ...fixture.detail, item: { ...fixture.detail.item, [field]: different } },
          fixture.requested_operation_id,
        ),
      ).toThrow("Detail scope mismatch");
      expect(() =>
        parseDetail(
          { ...fixture.detail, timeline: [{ ...fixture.detail.requested, [field]: different }] },
          fixture.requested_operation_id,
        ),
      ).toThrow("Detail scope mismatch");
    },
  );
  it.each([
    { complete: true, has_more: true, cursor: "next" },
    { complete: false, has_more: true, cursor: null },
    { complete: false, has_more: true, cursor: "" },
    { complete: true, has_more: false, cursor: "next" },
  ])(
    "rejects contradictory page continuation $complete/$has_more/$cursor",
    ({ complete, has_more, cursor }) => {
      const page = required(fixtures[0]).list;
      expect(() =>
        parsePage({
          ...page,
          next_cursor: cursor,
          coverage: { ...page.coverage, complete, has_more },
        }),
      ).toThrow("Page coverage mismatch");
    },
  );
});
