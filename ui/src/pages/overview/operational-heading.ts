import type { Operation } from "./operational-contract.ts";

/** Presentation only: observed native status is not canonical/owner acceptance. */
export function operationHeading(item: Operation): string {
  if (item.display?.label) return item.display.label;
  const native = item.native;
  if (!native) return item.title;
  if (native.adapter === "github-actions") {
    // Incumbent normalizer session identity is owner/repository:decimal-run-id.
    const match = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+:([1-9][0-9]{0,19})$/.exec(native.session_id);
    const run = match?.[0] === native.session_id ? match?.[1] : undefined;
    if (!run) return item.title;
    if (native.native_event === "workflow_run.in_progress" && native.outcome === "in_progress") {
      return `GitHub run ${run} · Observed running`;
    }
    if (native.native_event === "workflow_run.completed") {
      const status = new Map(
        Object.entries({
          success: "Run succeeded",
          failure: "Run failed",
          cancelled: "Run cancelled",
          timed_out: "Run timed out",
          skipped: "Run skipped",
          neutral: "Run completed (neutral)",
          action_required: "Run requires action",
          stale: "Run marked stale",
        }),
      ).get(native.outcome ?? "");
      if (status) return `GitHub run ${run} · ${status}`;
    }
  }
  if (native.adapter === "codex-app-server" && item.project && native.turn_id) {
    if (native.native_event === "turn/started" && native.outcome === "in_progress") {
      return `${item.project} · Codex turn observed running`;
    }
    if (native.native_event === "turn/completed") {
      const status = new Map(
        Object.entries({
          completed: "completed",
          failed: "failed",
          interrupted: "interrupted",
          cancelled: "cancelled",
        }),
      ).get(native.outcome ?? "");
      if (status) return `${item.project} · Codex turn ${status}`;
    }
    // Item completion is deliberately not whole-turn completion.
  }
  return item.title;
}
