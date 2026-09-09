/* @vitest-environment jsdom */
import { assert, describe, expect, it, vi } from "vitest";
import { item, page, mount, setupOperationalViewTests } from "./operational-view.test-helpers.ts";

setupOperationalViewTests();
const workContract = {
  schema: "argus.work.read-contract.v1",
  operation_id: item.operation_id,
  requested_operation_id: item.operation_id,
  requested_event_id: item.event_id,
  latest_event_id: item.event_id,
  native_observations: [
    { event_id: item.event_id, adapter: "synthetic-harness", outcome: "success" },
  ],
  structural_verification: { status: "not_established", semantic_correctness_established: false },
  independent_verification: { artifacts: [], covers_all_current_artifacts: false },
  owner_disposition: { status: "not_established" },
  owner_accepted: false,
  pending_owner_feedback: [],
  continuation: {
    mode: "read_only",
    action: "inspect_current_evidence",
    operation_id: item.operation_id,
    event_id: item.event_id,
    artifact_sha256: [],
    dispatch_enabled: false,
  },
  coverage: {
    scope: "canonical_federation_observation",
    complete: true,
    cross_scope_absence_established: false,
  },
  is_state_transition: false,
};
async function mountContract(
  contract: unknown,
  current: Omit<typeof item, "artifacts"> & {
    artifacts: { sha256: string; bytes: number | null }[];
    artifact_context?: {
      relation: "current_attempt" | "previous_attempt" | "federation_observation" | "unknown";
      current_attempt_id: string | null;
      artifact_attempt_id: string | null;
    };
    project?: string;
    evidence_scope?: string;
    executor_id?: string;
    capability_id?: string;
  } = item,
) {
  const requested = {
    ...item,
    task_id: current.task_id,
    source: current.source,
    project: current.project,
  };
  const request = vi
    .fn()
    .mockResolvedValueOnce(page)
    .mockResolvedValueOnce({
      item: current,
      requested,
      timeline: [current, requested],
      coverage: { complete: true, has_more: false },
      work_contract: contract,
    });
  const mounted = await mount(request);
  [...mounted.element.querySelectorAll("button")]
    .find((node) => node.textContent?.includes("Open work"))
    ?.click();
  await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(2));
  await mounted.element.updateComplete;
  return mounted;
}
describe("read-only work evidence contract", () => {
  it("separates producer success from verification, owner disposition and continuation", async () => {
    const { element, request } = await mountContract(workContract);
    await vi.waitFor(() => expect(element.textContent).toContain("Evidence basis"));
    const basis = element.querySelector(".argus-work-contract")!;
    const text = basis.textContent?.replace(/\s+/g, " ") ?? "";
    expect(text).toContain("synthetic-harness: success · producer observation");
    expect(text).toContain("Not established in returned evidence");
    expect(text).toContain("Unknown in this reader. Owner acceptance not recorded.");
    expect(text).toContain("Evidence outside this scope has not been ruled out");
    expect(basis.querySelector("a")?.getAttribute("href")).toContain(
      "argus_operation=external-held-out",
    );
    expect(basis.querySelector("button")).toBeNull();
    expect(request.mock.calls.map((call) => call[0])).toEqual([
      "argus.operations.list",
      "argus.operations.detail",
    ]);
  });
  it("shows recorded failure and incomplete independent coverage without promoting acceptance", async () => {
    const artifact = { sha256: "a".repeat(64), bytes: 3 };
    const { element } = await mountContract(
      {
        ...workContract,
        native_observations: [{ event_id: item.event_id, adapter: null, outcome: null }],
        structural_verification: {
          status: "failed_recorded",
          semantic_correctness_established: false,
        },
        independent_verification: {
          artifacts: [
            {
              event_id: "verification-a",
              outcome: "FAIL",
              artifact_sha256: artifact.sha256,
              verifier_report_sha256: "b".repeat(64),
            },
          ],
          covers_all_current_artifacts: false,
        },
        pending_owner_feedback: [
          { event_id: "feedback-a", owner: "Technical owner", reason: "Inspect the failed check" },
        ],
        continuation: { ...workContract.continuation, artifact_sha256: [artifact.sha256] },
        coverage: { ...workContract.coverage, complete: false },
      },
      { ...item, artifacts: [artifact] },
    );
    await vi.waitFor(() =>
      expect(element.textContent).toContain("Failed structural check recorded"),
    );
    const basis = element.querySelector(".argus-work-contract")!;
    const text = basis.textContent?.replace(/\s+/g, " ") ?? "";
    expect(text).toContain("Unknown producer: outcome not recorded");
    expect(text).toContain("do not establish a pass for all current artifacts");
    expect(text).toContain("FAIL · artifact " + artifact.sha256);
    expect(
      element.querySelector(".argus-owner-request")?.textContent?.replace(/\s+/g, " "),
    ).toContain("Technical owner: Inspect the failed check");
    expect(text).toContain("Partial returned scope");
    expect(text).toContain("Owner acceptance not recorded");
  });
  it.each([
    { operation_id: "another-observation" },
    { requested_event_id: "another-requested-event" },
    {
      independent_verification: {
        artifacts: [
          {
            event_id: "old-verification",
            outcome: "PASS",
            artifact_sha256: "f".repeat(64),
            verifier_report_sha256: "e".repeat(64),
          },
        ],
        covers_all_current_artifacts: true,
      },
    },
    { continuation: { ...workContract.continuation, dispatch_enabled: true } },
  ])("refuses a mismatched identity or execution-bearing contract: %j", async (delta) => {
    const { element } = await mountContract({ ...workContract, ...delta });
    await vi.waitFor(() => expect(element.textContent).toContain("Work detail is unavailable"));
    expect(element.querySelector(".argus-work-contract")).toBeNull();
    expect(element.querySelector(".argus-detail")).toBeNull();
  });
});

describe("result-first evidence hierarchy", () => {
  it("keeps compact native headings and full source limitations outside provenance", async () => {
    const title =
      "Reader correction: synthetic source summary with explicit sample and scope limits";
    const operation = {
      ...item,
      title,
      project: "MiKobots",
      native: {
        adapter: "codex-app-server",
        native_event: "turn/started",
        outcome: "in_progress",
        session_id: "synthetic-thread",
        turn_id: "synthetic-turn",
        item_id: null,
      },
    };
    const { element } = await mountContract(workContract, operation);
    Object.assign(element, { page: { ...page, items: [operation] } });
    element.requestUpdate();
    await element.updateComplete;
    const detail = element.querySelector(".argus-detail")!;
    expect(detail.querySelector("h3")!.textContent!.trim()).toBe(
      "MiKobots · Codex turn observed running",
    );
    expect(detail.querySelector(":scope > .argus-source-summary")!.textContent).toBe(title);
    expect(detail.querySelector<HTMLDetailsElement>(":scope > details")!.open).toBe(false);
    expect(detail.querySelector(":scope > details")!.textContent).toContain(title);
    expect(element.querySelector(".argus-work-title")!.textContent!.trim()).toBe(
      "MiKobots · Codex turn observed running",
    );
  });

  it("keeps full selected summary visible and detailed provenance collapsed", async () => {
    const title = "Reader correction " + "detailed producer narrative ".repeat(30);
    const { element } = await mountContract(workContract, { ...item, title });
    const detail = element.querySelector(".argus-detail")!;
    expect(detail.querySelector("h3")!.textContent!.trim()).toBe(title.trim());
    const provenance = detail.querySelector<HTMLDetailsElement>(":scope > details")!;
    expect(provenance.open).toBe(false);
    expect(provenance.textContent).toContain(title);
    expect(provenance.textContent).toContain("Owner acceptance not recorded");
    expect(detail.querySelector(".argus-owner-request")).toBeNull();
    expect(detail.textContent).not.toContain("approval required");
    expect(detail.querySelector(".argus-disposition")?.textContent).toContain("not established");
  });

  it("shows ordinary admitted operations through the same detail contract", async () => {
    const { element } = await mountContract(
      {
        ...workContract,
        native_observations: [],
        coverage: { ...workContract.coverage, scope: "canonical_operation_trace" },
      },
      {
        ...item,
        title: "Technical completion · observed",
        source: "canonical:codex-completion-adapter",
        evidence_scope: "admitted_canonical_technical_operation",
        executor_id: "synthetic-executor",
        capability_id: "codex.completion",
      },
    );
    const provenance = element.querySelector(".argus-detail > details")!;
    expect(provenance.textContent).toContain("admitted_canonical_technical_operation");
    expect(provenance.textContent).toContain("synthetic-executor");
    expect(provenance.textContent).toContain("No native outcome included in this scope");
    expect(element.querySelector(".argus-disposition")?.textContent).toContain("not established");
  });

  it.each([
    [null, 3, true, true],
    [null, 3, false, false],
    [3, 3, true, true],
    [2, 3, false, true],
    [null, 2, false, true],
    [null, -1, false, true],
  ])(
    "verifies declared size %s against returned size %s",
    async (declared, returned, succeeds, hashMatches) => {
      const digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
      const artifact = { sha256: digest, bytes: declared };
      const cryptoMock = {
        subtle: {
          digest: vi
            .fn()
            .mockResolvedValue(
              Uint8Array.from(digest.match(/../g)!, (pair) =>
                hashMatches ? Number.parseInt(pair, 16) : 0,
              ).buffer,
            ),
        },
      };
      vi.stubGlobal("crypto", cryptoMock);
      const create = vi.fn().mockReturnValue("blob:verified-synthetic");
      vi.stubGlobal(
        "URL",
        class extends URL {
          static override createObjectURL = create;
          static override revokeObjectURL = vi.fn();
        },
      );
      try {
        const { element, request } = await mountContract(
          {
            ...workContract,
            continuation: { ...workContract.continuation, artifact_sha256: [digest] },
          },
          { ...item, artifacts: [artifact] },
        );
        request.mockResolvedValueOnce({
          sha256: digest,
          event_id: item.event_id,
          bytes: returned,
          mime_type: "text/plain; charset=utf-8",
          content_base64: "YWJj",
        });
        const button = [...element.querySelectorAll("button")].find((node) =>
          node.textContent?.includes("Verify artifact"),
        )!;
        if (declared === null) {
          expect(button.textContent).toContain("size checked on open");
        }
        expect(button.closest("details")).toBeNull();
        button.click();
        await vi.waitFor(() =>
          expect(element.textContent).toContain(
            succeeds ? "Open verified artifact" : "Artifact could not be verified",
          ),
        );
        expect(create).toHaveBeenCalledTimes(succeeds ? 1 : 0);
      } finally {
        vi.unstubAllGlobals();
      }
    },
  );
});

it("names structural-only verification in the primary summary without hiding its semantic limit", async () => {
  const artifact = { sha256: "a".repeat(64), bytes: 3 };
  const { element } = await mountContract(
    {
      ...workContract,
      structural_verification: {
        status: "passed_recorded",
        semantic_correctness_established: false,
      },
      independent_verification: {
        semantic_correctness_established: false,
        artifacts: [
          {
            event_id: "structural-verifier-event",
            outcome: "PASS",
            artifact_sha256: artifact.sha256,
            verifier_report_sha256: "b".repeat(64),
            verification_kind: "structural_artifact_contract",
            semantic_correctness_established: false,
          },
        ],
        covers_all_current_artifacts: true,
      },
      continuation: { ...workContract.continuation, artifact_sha256: [artifact.sha256] },
    },
    { ...item, artifacts: [artifact] },
  );
  const summary = element.querySelector(".argus-disposition")!;
  expect(summary.closest("details")).toBeNull();
  expect(summary.textContent).toContain(
    "Structural verification passed for the current artifacts.",
  );
  expect(summary.textContent).toContain("Semantic correctness is not established by this receipt.");
  expect(summary.textContent).not.toContain("Independent PASS");
  expect(element.querySelector(".argus-detail > details")?.hasAttribute("open")).toBe(false);
});

it("keeps previous-attempt artifacts inspectable without labeling them a current result", async () => {
  const artifact = { sha256: "a".repeat(64), bytes: 3 };
  const artifact_context = {
    relation: "previous_attempt" as const,
    current_attempt_id: "retry-two",
    artifact_attempt_id: "attempt-one",
  };
  const { element } = await mountContract(
    {
      ...workContract,
      continuation: {
        ...workContract.continuation,
        artifact_sha256: [artifact.sha256],
        artifact_context,
      },
    },
    { ...item, state: "running", artifacts: [artifact], artifact_context },
  );
  expect(element.querySelector(".argus-artifact-attempt")?.textContent).toContain(
    "No artifact from the current attempt is available",
  );
  expect(element.querySelector(".argus-detail")?.textContent).toContain(
    "Inspect previous-attempt evidence",
  );
  expect(
    [...element.querySelectorAll("button")].some((button) =>
      button.textContent?.includes("Verify previous-attempt artifact"),
    ),
  ).toBe(true);
  expect(element.querySelector(".argus-detail")?.textContent).not.toContain("Inspect the result");
});

it("labels legacy missing attempt attribution as available evidence", async () => {
  const { element } = await mountContract(workContract);
  expect(element.querySelector(".argus-detail")?.textContent).toContain(
    "Inspect available evidence",
  );
  expect(element.querySelector(".argus-detail")?.textContent).not.toContain("Inspect the result");
});

it("uses admitted display metadata while preserving raw producer title and authority distinctions", async () => {
  const displayed = {
    ...item,
    display: {
      label: "Reader correction · useful label",
      change_summary: "<script>synthetic text</script>",
      artifact_label: "Technical report",
      continuation_label: "Inspect the report with the owning workflow",
    },
  };
  const request = vi
    .fn()
    .mockResolvedValueOnce({ ...page, items: [displayed] })
    .mockResolvedValueOnce({
      item: displayed,
      requested: displayed,
      timeline: [displayed],
      coverage: { complete: true, has_more: false },
    });
  const { element } = await mount(request);
  element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
  await vi.waitFor(() =>
    expect(element.querySelector(".argus-detail h3")?.textContent).toContain("useful label"),
  );
  expect(element.querySelector(".argus-detail > details")?.textContent).toContain(item.title);
  expect(element.querySelector(".argus-detail")?.textContent).toContain(
    "<script>synthetic text</script>",
  );
  expect(element.querySelector(".argus-detail script")).toBeNull();
  expect(element.textContent).toContain("Recorded state: verified");
  expect(element.textContent).toContain("Owner acceptance not recorded");
});

it("does not label an active federation observation without artifacts as a result", async () => {
  const active = {
    ...item,
    kind: "task.started",
    state: "observed",
    artifacts: [],
    artifact_context: {
      relation: "federation_observation",
      current_attempt_id: null,
      artifact_attempt_id: null,
    },
  };
  const request = vi
    .fn()
    .mockResolvedValueOnce({ ...page, items: [active] })
    .mockResolvedValueOnce({
      item: active,
      requested: active,
      timeline: [active],
      coverage: { complete: true, has_more: false },
    });
  const { element } = await mount(request);
  element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
  await vi.waitFor(() =>
    expect(element.querySelector(".argus-detail")?.textContent).toContain(
      "Inspect recorded evidence",
    ),
  );
  expect(element.querySelector(".argus-detail")?.textContent).not.toContain("Inspect the result");
  expect(element.querySelector(".argus-detail")?.textContent).toContain(
    "No artifact references were returned",
  );
  expect(element.querySelector(".argus-detail")?.textContent).toContain("Recorded state: observed");
  expect(element.querySelector(".argus-detail > details")?.textContent).toContain(
    "Artifact links belong to this observation.",
  );
  expect(element.querySelector(".argus-detail > details")?.textContent).not.toContain(
    "current attempt not recorded",
  );
});

describe("current artifact operator review", () => {
  const ordinary = {
    ...item,
    evidence_scope: "admitted_canonical_technical_operation",
    capability_id: "codex.completion",
    artifacts: [{ sha256: "a".repeat(64), bytes: 3 }],
    artifact_context: {
      relation: "current_attempt",
      current_attempt_id: "attempt",
      artifact_attempt_id: "attempt",
    },
  };
  async function openReview(
    value: typeof ordinary,
    available = true,
    resolve = vi.fn().mockRejectedValue(new Error("unknown result")),
    pendingReviews: unknown[] = [],
  ) {
    const request = vi.fn(async (method: string, params?: unknown) => {
      if (method === "argus.operations.list") {
        return { ...page, items: [value] };
      }
      if (method === "argus.operations.detail") {
        return {
          item: value,
          requested: value,
          timeline: [value],
          coverage: { complete: true, has_more: false },
        };
      }
      return resolve(method, params);
    });
    const result = await mount(request, true, available, pendingReviews);
    [...result.element.querySelectorAll("button")]
      .find((b) => b.textContent?.includes("Open work"))
      ?.click();
    await vi.waitFor(() => expect(result.element.querySelector(".argus-detail")).not.toBeNull());
    await result.element.updateComplete;
    return {
      ...result,
      resolve,
      button: () =>
        [...result.element.querySelectorAll("button")].find((b) =>
          b.textContent?.includes("Request operator review"),
        ),
    };
  }
  it("opens the current pending review button without a second request or decision", async () => {
    const binding = {
      operation_id: ordinary.operation_id,
      event_id: ordinary.event_id,
      artifact_sha256: ordinary.artifacts.map((a) => a.sha256),
    };
    const pending = {
      id: "durable-review",
      kind: "artifact_review",
      expiresAtMs: Date.now() + 60000,
      artifactReview: { binding },
    };
    const result = await openReview(ordinary, true, vi.fn(), [pending]);
    result.overlays.refreshApprovals.mockResolvedValue(true);
    const button = [...result.element.querySelectorAll("button")].find((b) =>
      b.textContent?.includes("Open pending review"),
    );
    expect(button).toBeDefined();
    button!.click();
    await vi.waitFor(() =>
      expect(result.element.textContent).toContain("No new request or decision was submitted"),
    );
    expect(result.overlays.refreshApprovals).toHaveBeenCalledWith(binding, expect.any(Function));
    expect(
      result.request.mock.calls.some(
        ([method]) => method === "plugin.approval.request" || method === "plugin.approval.resolve",
      ),
    ).toBe(false);
  });
  it("retries the exact binding with one stable request key after an unknown result", async () => {
    const { button, resolve, element } = await openReview(ordinary);
    expect(button()).toBeDefined();
    button()!.click();
    await vi.waitFor(() => expect(element.textContent).toContain("Artifact review unavailable"));
    button()!.click();
    await vi.waitFor(() => expect(resolve).toHaveBeenCalledTimes(2));
    const firstCall = resolve.mock.calls[0];
    const secondCall = resolve.mock.calls[1];
    assert.isDefined(firstCall);
    assert.isDefined(secondCall);
    expect(firstCall[1]).toEqual(secondCall[1]);
    expect(firstCall[1].binding).toEqual({
      operation_id: item.operation_id,
      event_id: item.event_id,
      artifact_sha256: ["a".repeat(64)],
    });
  });
  it("does not offer review for federation, prior artifacts, or an unavailable adapter", async () => {
    for (const [value, available] of [
      [{ ...ordinary, evidence_scope: "canonical_federation_observation" }, true],
      [
        {
          ...ordinary,
          artifact_context: {
            ...ordinary.artifact_context,
            relation: "previous_attempt",
            artifact_attempt_id: "earlier-attempt",
          },
        },
        true,
      ],
      [ordinary, false],
    ] as const) {
      window.history.replaceState({}, "", "/overview");
      const result = await openReview(value as typeof ordinary, available);
      expect(result.button()).toBeUndefined();
      result.element.remove();
    }
  });
  it("prevents duplicate concurrent requests and does not record an operator decision", async () => {
    let finish!: (value: unknown) => void;
    const resolve = vi.fn(
      () =>
        new Promise((r) => {
          finish = r;
        }),
    );
    const { button, request, element } = await openReview(ordinary, true, resolve);
    button()!.click();
    await element.updateComplete;
    expect(button()!.disabled).toBe(true);
    button()!.click();
    expect(resolve).toHaveBeenCalledTimes(1);
    finish({ id: "pending" });
    await vi.waitFor(() =>
      expect(element.textContent).toContain("This action does not submit an artifact decision"),
    );
    expect(request.mock.calls.some(([method]) => method === "plugin.approval.resolve")).toBe(false);
  });
});

describe("recorded operator review history", () => {
  it.each(["pending", "accepted", "rejected"])(
    "labels %s history without inventing an actionable request",
    async (state) => {
      const current = {
        ...item,
        artifacts: [{ sha256: "a".repeat(64), bytes: 3 }],
        artifact_context: {
          relation: "current_attempt",
          current_attempt_id: "attempt-two",
          artifact_attempt_id: "attempt-two",
        },
      };
      const detail = {
        item: current,
        requested: current,
        timeline: [current],
        coverage: { complete: true, has_more: false },
        review_history: {
          items: [
            {
              id: "old-review",
              request_event_id: "old-request",
              binding: {
                operation_id: current.operation_id,
                event_id: "old-event",
                artifact_sha256: ["b".repeat(64)],
              },
              state,
              binding_relation: "previous",
              requested_at_ms: 100,
              expires_at_ms: 200,
              disposition:
                state === "pending"
                  ? null
                  : { event_id: "operator-disposition", recorded_at_ms: 150 },
            },
          ],
          coverage: { complete: false, has_more: true, snapshot_sequence: 9 },
          owner_accepted: false,
        },
      };
      const request = vi
        .fn()
        .mockResolvedValueOnce({ ...page, items: [current] })
        .mockResolvedValueOnce(detail);
      const { element, setConnected } = await mount(request);
      element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
      await vi.waitFor(() =>
        expect(element.querySelector(".argus-review-history")?.textContent).toContain(
          "Earlier evidence binding",
        ),
      );
      const text = element.querySelector(".argus-review-history")!.textContent!;
      expect(text).toContain(
        state === "pending"
          ? "No qualified disposition recorded"
          : `Operator ${state} the bound artifact`,
      );
      expect(text).toContain("does not establish a currently actionable review");
      expect(text).toContain("passed");
      expect(element.textContent).not.toContain("Open pending review");
      setConnected(false);
      await element.updateComplete;
      expect(element.textContent).toContain("Disconnected");
      expect(element.textContent).not.toContain("Open pending review");
    },
  );
  it("marks history absent from older readers as not supplied", async () => {
    const request = vi
      .fn()
      .mockResolvedValueOnce(page)
      .mockResolvedValueOnce({
        item,
        requested: item,
        timeline: [item],
        coverage: { complete: true, has_more: false },
      });
    const { element } = await mount(request);
    element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
    await vi.waitFor(() =>
      expect(element.textContent).toContain("Operator review history was not supplied"),
    );
  });
});

it("shows the entire admitted surface-result limitations outside collapsed provenance", async () => {
  const title =
    "Reader correction · Synthetic surface audit: all sampled pieces covered; sampled excess reported using reused samples. Retrospective completed observation with hash-verified artifact. No fresh native queries, Hausdorff bound, dynamics qualification, physical dispatch or owner acceptance.";
  const observation = { ...item, title };
  const request = vi
    .fn()
    .mockResolvedValueOnce({ ...page, items: [observation] })
    .mockResolvedValueOnce({
      item: observation,
      requested: observation,
      timeline: [observation],
      coverage: { complete: true, has_more: false },
    });
  const { element } = await mount(request);
  element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
  await vi.waitFor(() =>
    expect(element.querySelector(".argus-selected-title")?.textContent?.trim()).toBe(title),
  );
  expect(element.querySelector(".argus-selected-title")?.closest("details")).toBeNull();
  expect(element.querySelector<HTMLDetailsElement>(".argus-detail > details")?.open).toBe(false);
});

it("distinguishes named artifacts with escaped labels while retaining hash and size", async () => {
  const selected = {
    ...item,
    artifacts: [
      { sha256: "a".repeat(64), bytes: 100, display_name: "native-test-receipt.json" },
      { sha256: "b".repeat(64), bytes: 200, display_name: "<img onerror=alert(1)>.json" },
      { sha256: "c".repeat(64), bytes: null },
    ],
  };
  const request = vi
    .fn()
    .mockResolvedValueOnce({ ...page, items: [selected] })
    .mockResolvedValueOnce({
      item: selected,
      requested: selected,
      timeline: [selected],
      coverage: { complete: true, has_more: false },
    });
  const { element } = await mount(request);
  element.querySelector<HTMLButtonElement>(".argus-work-row")!.click();
  await vi.waitFor(() =>
    expect(element.querySelector(".argus-detail")?.textContent).toContain(
      "native-test-receipt.json · aaaaaaaaaaaa (100 bytes)",
    ),
  );
  expect(element.querySelector(".argus-detail")?.textContent).toContain(
    "<img onerror=alert(1)>.json · bbbbbbbbbbbb (200 bytes)",
  );
  expect(element.querySelector(".argus-detail")?.textContent).toContain(
    "Verify artifact cccccccccccc (size checked on open)",
  );
  expect(element.querySelector(".argus-detail img")).toBeNull();
});
