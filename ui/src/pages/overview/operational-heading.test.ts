import { assert, describe, it, expect } from "vitest";
import { parsePage } from "./operational-contract.ts";
import { operationHeading } from "./operational-heading.ts";
const item = {
  operation_id: "op",
  task_id: "task",
  event_id: "event",
  title: "Full producer narrative with exact limitations",
  source: "producer",
  kind: "result.proposed",
  state: "observed",
  occurred_at: "2026-09-07T09:00:00Z",
  observed_at: "2026-09-07T09:00:00Z",
  artifacts: [],
  owner_accepted: false as const,
  project: "MiKobots" as const,
};
const native = {
  adapter: "codex-app-server",
  native_event: "turn/started",
  outcome: "in_progress",
  session_id: "thread-1",
  turn_id: "turn-1",
  item_id: null,
};
describe("native observation headings", () => {
  it("rejects prototype properties as unknown outcomes in both native mappings", () => {
    for (const outcome of ["constructor", "toString", "__proto__"]) {
      expect(
        operationHeading({
          ...item,
          native: { ...native, native_event: "turn/completed", outcome },
        }),
      ).toBe(item.title);
      expect(
        operationHeading({
          ...item,
          native: {
            ...native,
            adapter: "github-actions",
            native_event: "workflow_run.completed",
            session_id: "org/repo:123",
            outcome,
          },
        }),
      ).toBe(item.title);
    }
  });

  it("labels dated active turns as observed and preserves source title", () => {
    const op = { ...item, native };
    expect(operationHeading(op)).toBe("MiKobots · Codex turn observed running");
    expect(op.title).toBe(item.title);
  });
  it("never promotes item or thread creation to whole-turn completion", () => {
    for (const event of ["item/completed", "thread/started"]) {
      expect(
        operationHeading({
          ...item,
          native: { ...native, native_event: event, outcome: "completed" },
        }),
      ).toBe(item.title);
    }
  });
  it("uses only validated GitHub session run identity, never parses prose build labels", () => {
    expect(
      operationHeading({
        ...item,
        native: {
          ...native,
          adapter: "github-actions",
          native_event: "workflow_run.completed",
          outcome: "success",
          session_id: "org/repo:34101979510",
        },
      }),
    ).toBe("GitHub run 34101979510 · Run succeeded");
    for (const session_id of [
      "repo:34101979510",
      "org/repo:0",
      "org/repo:123\n",
      "org/repo:1/extra",
    ]) {
      expect(
        operationHeading({
          ...item,
          native: {
            ...native,
            adapter: "github-actions",
            native_event: "workflow_run.completed",
            outcome: "success",
            session_id,
          },
        }),
      ).toBe(item.title);
    }
  });
  it("says observed running for GitHub and never uses canonical state as native success", () => {
    const op = {
      ...item,
      state: "verified",
      native: {
        ...native,
        adapter: "github-actions",
        native_event: "workflow_run.in_progress",
        outcome: "in_progress",
        session_id: "org/repo:34101979510",
      },
    };
    expect(operationHeading(op)).toBe("GitHub run 34101979510 · Observed running");
  });
  it("retains unknown outcomes and ordinary metadata/fallback", () => {
    expect(operationHeading({ ...item, native: { ...native, outcome: "unknown" } })).toBe(
      item.title,
    );
    expect(operationHeading(item)).toBe(item.title);
    expect(
      operationHeading({ ...item, native, display: { label: "Admitted human heading" } }),
    ).toBe("Admitted human heading");
  });
  it("retains existing native fields through actual shared parser", () => {
    const page = parsePage({
      items: [{ ...item, native }],
      coverage: {
        scope: { corpus: "canonical_federation_observations", project: "MiKobots" },
        complete: true,
        has_more: false,
        snapshot_sequence: 1,
        observed_at: item.observed_at,
      },
      next_cursor: null,
    });
    const parsed = page.items[0];
    assert.isDefined(parsed);
    expect(parsed.native?.turn_id).toBe("turn-1");
    expect(operationHeading(parsed)).toContain("observed running");
  });
});
