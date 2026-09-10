import {
  clearMemoryPluginState,
  registerMemoryCorpusSupplement,
} from "openclaw/plugin-sdk/memory-host-core";
// Search-result delivery and short-term tracking have separate outcomes.
import { readMemoryHostEventRecords } from "openclaw/plugin-sdk/memory-host-events";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  resetMemoryToolMockState,
  setMemorySearchImpl,
  setMemoryWorkspaceDir,
} from "./memory-tool-manager.test-mocks.js";
import { createMemoryCoreTestHarness } from "./test-helpers.js";
import { createMemorySearchTool } from "./tools.js";

const { createTempWorkspace } = createMemoryCoreTestHarness();

describe("memory_search result delivery versus recall tracking", () => {
  beforeEach(() => {
    clearMemoryPluginState();
    resetMemoryToolMockState();
  });
  afterEach(() => clearMemoryPluginState());

  it("returns the highest-ranked durable hit while the real tracker records it as ineligible", async () => {
    const workspaceDir = await createTempWorkspace("durable-result-delivery-");
    setMemoryWorkspaceDir(workspaceDir);
    const hits = [
      {
        path: "docs/investigations/widget-deployment.md",
        startLine: 3,
        endLine: 5,
        score: 0.96,
        snippet: "The synthetic widget deployment was qualified.",
        source: "memory" as const,
      },
      {
        path: "state/projects/widget-plan.md",
        startLine: 1,
        endLine: 2,
        score: 0.48,
        snippet: "The earlier synthetic widget deployment plan.",
        source: "memory" as const,
      },
    ];
    const original = structuredClone(hits);
    setMemorySearchImpl(async () => hits);
    const tool = createMemorySearchTool({
      config: {
        agents: { list: [{ id: "main", default: true }] },
        plugins: { entries: { "memory-core": { config: { dreaming: { enabled: true } } } } },
      },
    });
    expect(tool).not.toBeNull();
    if (!tool) {
      throw new Error("memory_search tool missing");
    }
    const result = await tool.execute("durable-result-delivery", { query: "synthetic widget" });
    const details = result.details as { results: Array<{ path: string; score: number }> };
    expect(details.results.map((hit) => hit.path)).toEqual(hits.map((hit) => hit.path));
    expect(details.results[0]?.score).toBe(0.96);
    // Only the search provider is synthetic: the tool and tracking writer are real.
    await vi.waitFor(async () => {
      const records = await readMemoryHostEventRecords({ workspaceDir });
      const skipped = records.find((record) => record.type === "memory.recall.skipped");
      expect(skipped).toMatchObject({
        reason: "non-short-term-memory-path",
        scope: "short-term-recall-tracking",
        searchResultEffect: "none",
        eligibleResultCount: 0,
        skippedResultCount: 2,
      });
      if (skipped?.type !== "memory.recall.skipped") {
        throw new Error("expected tracking diagnostic");
      }
      expect(skipped.results.map((hit) => hit.path)).toEqual(hits.map((hit) => hit.path));
    });
    expect(hits).toEqual(original);
    expect(details.results[0]?.path).toBe(original[0]?.path);
  });
  it("tracks only primary results retained by final combined-corpus selection", async () => {
    const workspaceDir = await createTempWorkspace("combined-result-selection-");
    setMemoryWorkspaceDir(workspaceDir);
    const memoryPath = "docs/investigations/synthetic-memory-candidate.md";
    setMemorySearchImpl(async () => [
      {
        path: memoryPath,
        startLine: 1,
        endLine: 2,
        score: 0.96,
        snippet: "Synthetic memory candidate.",
        source: "memory" as const,
      },
      {
        path: "docs/investigations/older-widget-plan.md",
        startLine: 1,
        endLine: 2,
        score: 0.2,
        snippet: "Earlier synthetic plan.",
        source: "memory" as const,
      },
    ]);
    registerMemoryCorpusSupplement("memory-wiki", {
      search: async () => [
        {
          corpus: "wiki",
          path: "entities/synthetic-widget.md",
          title: "Synthetic widget",
          kind: "entity",
          score: 4,
          snippet: "Synthetic wiki candidate.",
        },
      ],
      get: async () => null,
    });
    const tool = createMemorySearchTool({
      config: {
        agents: { list: [{ id: "main", default: true }] },
        plugins: { entries: { "memory-core": { config: { dreaming: { enabled: true } } } } },
      },
    });
    if (!tool) {
      throw new Error("memory_search tool missing");
    }
    const result = await tool.execute("combined-selection", {
      query: "synthetic widget",
      corpus: "all",
      maxResults: 2,
    });
    const details = result.details as { results: Array<{ path: string }> };
    expect(details.results.map((hit) => hit.path)).toEqual([
      "entities/synthetic-widget.md",
      memoryPath,
    ]);
    await vi.waitFor(async () => {
      const records = await readMemoryHostEventRecords({ workspaceDir });
      const skipped = records.find((record) => record.type === "memory.recall.skipped");
      expect(skipped).toMatchObject({
        reason: "non-short-term-memory-path",
        scope: "short-term-recall-tracking",
        searchResultEffect: "none",
        skippedResultCount: 1,
      });
      if (skipped?.type !== "memory.recall.skipped") {
        throw new Error("expected tracking diagnostic");
      }
      expect(skipped.results.map((hit) => hit.path)).toEqual([memoryPath]);
    });
  });
});
