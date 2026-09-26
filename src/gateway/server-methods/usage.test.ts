/**
 * Tests for usage-report gateway methods and aggregation responses.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { OpenClawConfig } from "../../config/config.js";
import { withEnvAsync } from "../../test-utils/env.js";

vi.mock("../../infra/session-cost-usage.js", async () => {
  const actual = await vi.importActual<typeof import("../../infra/session-cost-usage.js")>(
    "../../infra/session-cost-usage.js",
  );
  return {
    ...actual,
    loadCostUsageSummaryFromCache: vi.fn(async () => ({
      updatedAt: Date.now(),
      startDate: "2026-02-01",
      endDate: "2026-02-02",
      daily: [],
      totals: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 1,
        totalCost: 0,
        inputCost: 0,
        outputCost: 0,
        cacheReadCost: 0,
        cacheWriteCost: 0,
        missingCostEntries: 0,
      },
    })),
  };
});

import { loadCostUsageSummaryFromCache } from "../../infra/session-cost-usage.js";
import { testApi, usageHandlers } from "./usage.js";

describe("gateway usage helpers", () => {
  const dayMs = 24 * 60 * 60 * 1000;

  function expectUtcDateRange(
    range: ReturnType<typeof testApi.parseDateRange>,
    startDate: string,
    endDate: string,
  ) {
    expect(range.startMs).toBe(testApi.parseDateToMs(startDate));
    expect(range.endMs).toBe(testApi.parseDateToMs(endDate)! + dayMs - 1);
  }

  beforeEach(() => {
    testApi.costUsageCache.clear();
    vi.useRealTimers();
    vi.clearAllMocks();
  });

  it("parseDateToMs accepts YYYY-MM-DD and rejects invalid input", () => {
    expect(testApi.parseDateToMs("2026-02-05")).toBe(Date.UTC(2026, 1, 5));
    expect(testApi.parseDateToMs(" 2026-02-05 ")).toBe(Date.UTC(2026, 1, 5));
    expect(testApi.parseDateToMs("2026-2-5")).toBeUndefined();
    expect(testApi.parseDateToMs("nope")).toBeUndefined();
    expect(testApi.parseDateToMs(undefined)).toBeUndefined();
  });

  it("parseUtcOffsetToMinutes supports whole-hour and half-hour offsets", () => {
    expect(testApi.parseUtcOffsetToMinutes("UTC-4")).toBe(-240);
    expect(testApi.parseUtcOffsetToMinutes("UTC+5:30")).toBe(330);
    expect(testApi.parseUtcOffsetToMinutes(" UTC+14 ")).toBe(14 * 60);
  });

  it("parseUtcOffsetToMinutes rejects invalid offsets", () => {
    expect(testApi.parseUtcOffsetToMinutes("UTC+14:30")).toBeUndefined();
    expect(testApi.parseUtcOffsetToMinutes("UTC+5:99")).toBeUndefined();
    expect(testApi.parseUtcOffsetToMinutes("UTC+25")).toBeUndefined();
    expect(testApi.parseUtcOffsetToMinutes("GMT+5")).toBeUndefined();
    expect(testApi.parseUtcOffsetToMinutes(undefined)).toBeUndefined();
  });

  it("parseDays coerces strings/numbers to integers", () => {
    expect(testApi.parseDays(7.9)).toBe(7);
    expect(testApi.parseDays("30")).toBe(30);
    expect(testApi.parseDays("")).toBeUndefined();
    expect(testApi.parseDays("nope")).toBeUndefined();
  });

  it("parseDateRange uses explicit start/end as UTC when mode is missing (backward compatible)", () => {
    const range = testApi.parseDateRange({ startDate: "2026-02-01", endDate: "2026-02-02" });
    expectUtcDateRange(range, "2026-02-01", "2026-02-02");
  });

  it("parseDateRange uses explicit UTC mode", () => {
    const range = testApi.parseDateRange({
      startDate: "2026-02-01",
      endDate: "2026-02-02",
      mode: "utc",
    });
    expectUtcDateRange(range, "2026-02-01", "2026-02-02");
  });

  it("parseDateRange uses specific UTC offset for explicit dates", () => {
    const range = testApi.parseDateRange({
      startDate: "2026-02-01",
      endDate: "2026-02-02",
      mode: "specific",
      utcOffset: "UTC+5:30",
    });
    const start = Date.UTC(2026, 1, 1) - 5.5 * 60 * 60 * 1000;
    const endStart = Date.UTC(2026, 1, 2) - 5.5 * 60 * 60 * 1000;
    expect(range.startMs).toBe(start);
    expect(range.endMs).toBe(endStart + dayMs - 1);
  });

  it("parseDateRange falls back to UTC when specific mode offset is missing or invalid", () => {
    const missingOffset = testApi.parseDateRange({
      startDate: "2026-02-01",
      endDate: "2026-02-02",
      mode: "specific",
    });
    const invalidOffset = testApi.parseDateRange({
      startDate: "2026-02-01",
      endDate: "2026-02-02",
      mode: "specific",
      utcOffset: "bad-value",
    });
    expect(missingOffset.startMs).toBe(Date.UTC(2026, 1, 1));
    expect(missingOffset.endMs).toBe(Date.UTC(2026, 1, 2) + dayMs - 1);
    expect(invalidOffset.startMs).toBe(Date.UTC(2026, 1, 1));
    expect(invalidOffset.endMs).toBe(Date.UTC(2026, 1, 2) + dayMs - 1);
  });

  it("parseDateRange uses specific offset for today/day math after UTC midnight", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-02-17T03:57:00.000Z"));
    const range = testApi.parseDateRange({
      days: 1,
      mode: "specific",
      utcOffset: "UTC-5",
    });
    expect(range.startMs).toBe(Date.UTC(2026, 1, 16, 5, 0, 0, 0));
    expect(range.endMs).toBe(Date.UTC(2026, 1, 17, 4, 59, 59, 999));
  });

  it("parseDateRange uses gateway local day boundaries in gateway mode", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-02-05T12:34:56.000Z"));
    const range = testApi.parseDateRange({ days: 1, mode: "gateway" });
    const expectedStart = new Date(2026, 1, 5).getTime();
    expect(range.startMs).toBe(expectedStart);
    expect(range.endMs).toBe(expectedStart + dayMs - 1);
  });

  it.each([
    ["America/Edmonton", 2026, 2, 8],
    ["America/Edmonton", 2026, 2, 9],
    ["America/Edmonton", 2026, 10, 1],
    ["America/Edmonton", 2026, 10, 2],
  ])(
    "usage.cost selects %s calendar boundaries at %i/%i/%i",
    async (timezone, year, month, day) => {
      await withEnvAsync({ TZ: timezone }, async () => {
        vi.useFakeTimers();
        vi.setSystemTime(new Date(year, month, day, 12));
        const date = `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
        const cases = [
          [{ startDate: date, endDate: date }, new Date(year, month, day).getTime()],
          [{ days: 1 }, new Date(year, month, day).getTime()],
          [{ range: "7d" }, new Date(year, month, day - 6).getTime()],
          [{ days: 31 }, new Date(year, month, day - 30).getTime()],
          [{}, new Date(year, month, day - 29).getTime()],
          [{ range: "all" }, 0],
        ] as const;
        for (const [rangeParams, expectedStart] of cases) {
          testApi.costUsageCache.clear();
          vi.mocked(loadCostUsageSummaryFromCache).mockClear();
          const respond = vi.fn();
          await usageHandlers["usage.cost"]({
            respond,
            params: { ...rangeParams, mode: "gateway" },
            context: { getRuntimeConfig: () => ({}) },
          } as unknown as Parameters<(typeof usageHandlers)["usage.cost"]>[0]);
          expect(respond).toHaveBeenCalledWith(true, expect.any(Object), undefined);
          expect(loadCostUsageSummaryFromCache).toHaveBeenCalledExactlyOnceWith(
            expect.objectContaining({
              startMs: expectedStart,
              endMs: new Date(year, month, day + 1).getTime() - 1,
              dateInterpretation: { mode: "gateway" },
            }),
          );
        }
      });
    },
  );

  it("resolves skipped Santiago midnight in a process born in that timezone", async () => {
    // Changing TZ inside a Vitest worker need not change V8's timezone.
    // Start a real child in the target zone and import the production RPC helper.
    const source = new URL("./usage.ts", import.meta.url).href;
    const script = `
      const { testApi } = await import(process.argv[1]);
      console.log(JSON.stringify({
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        ranges: ["2026-09-06", "2026-09-07"].map(date =>
          testApi.parseDateRange({ startDate: date, endDate: date, mode: "gateway" })),
      }));
    `;
    const { stdout } = await promisify(execFile)(
      process.execPath,
      ["--import", "tsx", "--input-type=module", "-e", script, source],
      { env: { ...process.env, TZ: "America/Santiago" }, timeout: 10_000 },
    );
    expect(JSON.parse(stdout)).toEqual({
      timezone: "America/Santiago",
      ranges: [
        { startMs: Date.UTC(2026, 8, 6, 4), endMs: Date.UTC(2026, 8, 7, 3) - 1 },
        { startMs: Date.UTC(2026, 8, 7, 3), endMs: Date.UTC(2026, 8, 8, 3) - 1 },
      ],
    });
  }, 15_000);

  it("parseDateRange clamps days to at least 1 and defaults to 30 days", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-02-05T12:34:56.000Z"));
    const oneDay = testApi.parseDateRange({ days: 0 });
    expect(oneDay.endMs).toBe(Date.UTC(2026, 1, 5) + dayMs - 1);
    expect(oneDay.startMs).toBe(Date.UTC(2026, 1, 5));

    const def = testApi.parseDateRange({});
    expect(def.endMs).toBe(Date.UTC(2026, 1, 5) + dayMs - 1);
    expect(def.startMs).toBe(Date.UTC(2026, 1, 5) - 29 * dayMs);
  });

  it("loadCostUsageSummaryCached caches within TTL", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-02-05T00:00:00.000Z"));

    const config = {} as OpenClawConfig;
    const a = await testApi.loadCostUsageSummaryCached({
      startMs: 1,
      endMs: 2,
      config,
    });
    const b = await testApi.loadCostUsageSummaryCached({
      startMs: 1,
      endMs: 2,
      config,
    });

    expect(a.totals.totalTokens).toBe(1);
    expect(b.totals.totalTokens).toBe(1);
    expect(vi.mocked(loadCostUsageSummaryFromCache)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(loadCostUsageSummaryFromCache).mock.calls.at(0)?.[0]?.refreshMode).toBe(
      "background",
    );
  });

  it("keeps cost usage cache entries scoped by agentId", async () => {
    const config = {} as OpenClawConfig;

    await testApi.loadCostUsageSummaryCached({
      startMs: 1,
      endMs: 2,
      config,
      agentId: "main",
    });
    await testApi.loadCostUsageSummaryCached({
      startMs: 1,
      endMs: 2,
      config,
      agentId: "research",
    });
    await testApi.loadCostUsageSummaryCached({
      startMs: 1,
      endMs: 2,
      config,
      agentId: "research",
    });

    expect(vi.mocked(loadCostUsageSummaryFromCache)).toHaveBeenCalledTimes(2);
    expect(vi.mocked(loadCostUsageSummaryFromCache).mock.calls.at(0)?.[0]).toMatchObject({
      agentId: "main",
    });
    expect(vi.mocked(loadCostUsageSummaryFromCache).mock.calls.at(1)?.[0]).toMatchObject({
      agentId: "research",
    });
  });

  it.each([
    [{}, { mode: "utc" }],
    [{ mode: "gateway" }, { mode: "gateway" }],
    [
      { mode: "specific", utcOffset: "UTC+5:30" },
      { mode: "specific", utcOffsetMinutes: 330 },
    ],
  ])(
    "passes the usage.cost calendar interpretation %j through every agent",
    async (dateParams, dateInterpretation) => {
      await usageHandlers["usage.cost"]({
        respond: vi.fn(),
        params: { days: 31, agentScope: "all", ...dateParams },
        context: {
          getRuntimeConfig: () => ({ agents: { list: [{ id: "main" }, { id: "research" }] } }),
        },
      } as unknown as Parameters<(typeof usageHandlers)["usage.cost"]>[0]);
      expect(vi.mocked(loadCostUsageSummaryFromCache)).toHaveBeenCalledTimes(2);
      for (const [params] of vi.mocked(loadCostUsageSummaryFromCache).mock.calls) {
        expect(params.dateInterpretation).toEqual(dateInterpretation);
      }
    },
  );

  it("does not reuse a cost report from another calendar interpretation", async () => {
    const range = { startMs: Date.UTC(2026, 1, 5), endMs: Date.UTC(2026, 1, 6) - 1, config: {} };
    await testApi.loadCostUsageSummaryCached(range);
    await testApi.loadCostUsageSummaryCached({ ...range, dateInterpretation: { mode: "gateway" } });
    await testApi.loadCostUsageSummaryCached({
      ...range,
      dateInterpretation: { mode: "specific", utcOffsetMinutes: 330 },
    });
    expect(vi.mocked(loadCostUsageSummaryFromCache)).toHaveBeenCalledTimes(3);
    await testApi.loadCostUsageSummaryCached(range);
    expect(vi.mocked(loadCostUsageSummaryFromCache)).toHaveBeenCalledTimes(3);
  });

  it("passes usage.cost agentId through to the cost summary loader", async () => {
    const respond = vi.fn();

    await usageHandlers["usage.cost"]({
      respond,
      params: { startDate: "2026-02-01", endDate: "2026-02-02", agentId: "research" },
      context: { getRuntimeConfig: () => ({}) },
    } as unknown as Parameters<(typeof usageHandlers)["usage.cost"]>[0]);

    expect(respond).toHaveBeenCalledWith(true, expect.any(Object), undefined);
    expect(vi.mocked(loadCostUsageSummaryFromCache)).toHaveBeenCalledWith(
      expect.objectContaining({ agentId: "research" }),
    );
  });

  it("passes usage.cost all-agent scope through to all configured agent loaders", async () => {
    const respond = vi.fn();

    await usageHandlers["usage.cost"]({
      respond,
      params: { startDate: "2026-02-01", endDate: "2026-02-02", agentScope: "all" },
      context: {
        getRuntimeConfig: () => ({
          agents: { list: [{ id: "main" }, { id: "research" }] },
        }),
      },
    } as unknown as Parameters<(typeof usageHandlers)["usage.cost"]>[0]);

    expect(respond).toHaveBeenCalledWith(
      true,
      expect.objectContaining({
        totals: expect.objectContaining({ totalTokens: 2 }),
      }),
      undefined,
    );
    expect(vi.mocked(loadCostUsageSummaryFromCache)).toHaveBeenCalledWith(
      expect.objectContaining({ agentId: "main" }),
    );
    expect(vi.mocked(loadCostUsageSummaryFromCache)).toHaveBeenCalledWith(
      expect.objectContaining({ agentId: "research" }),
    );
  });
});
