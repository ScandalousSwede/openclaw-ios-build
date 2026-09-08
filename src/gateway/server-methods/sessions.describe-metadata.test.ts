import { beforeEach, describe, expect, it, vi } from "vitest";
import type { GatewayRequestContext, RespondFn } from "./types.js";

const fixture = vi.hoisted(() => ({
  entry: { sessionId: "synthetic-recon-session", updatedAt: 123 } as
    | Record<string, unknown>
    | undefined,
  usage: vi.fn(),
  titles: vi.fn(),
}));
vi.mock("../session-utils.js", async () => {
  const actual = await vi.importActual<typeof import("../session-utils.js")>("../session-utils.js");
  return {
    ...actual,
    resolveGatewaySessionStoreTargetWithStore: () => ({
      agentId: "main",
      canonicalKey: "agent:main:cron:recon:run:1",
      storePath: "/tmp/synthetic-recon/sessions.json",
      storeKeys: ["agent:main:cron:recon:run:1"],
      store: fixture.entry ? { "agent:main:cron:recon:run:1": fixture.entry } : {},
    }),
  };
});
vi.mock("../session-transcript-readers.js", async () => {
  const actual = await vi.importActual<typeof import("../session-transcript-readers.js")>(
    "../session-transcript-readers.js",
  );
  return {
    ...actual,
    readRecentSessionUsageFromTranscript: (...args: unknown[]) => fixture.usage(...args),
    readSessionTitleFieldsFromTranscript: (...args: unknown[]) => fixture.titles(...args),
    readSessionTitleFieldsFromTranscriptAsync: (...args: unknown[]) => fixture.titles(...args),
  };
});
import { sessionsHandlers } from "./sessions.js";

async function describeSession(params: Record<string, unknown>) {
  const respond = vi.fn<RespondFn>();
  await sessionsHandlers["sessions.describe"]({
    req: { type: "req", id: "test", method: "sessions.describe", params },
    params,
    respond,
    context: { getRuntimeConfig: () => ({}) } as GatewayRequestContext,
    client: null,
    isWebchatConnect: () => false,
  });
  return respond;
}
describe("sessions.describe metadata-only contract", () => {
  beforeEach(() => {
    fixture.entry = { sessionId: "synthetic-recon-session", updatedAt: 123 };
    fixture.usage.mockReset().mockReturnValue(null);
    fixture.titles
      .mockReset()
      .mockReturnValue({
        firstUserMessage: "synthetic title",
        lastMessagePreview: "synthetic preview",
      });
  });
  it.each([
    {},
    { includeDerivedTitles: true },
    { includeLastMessage: true },
    { includeDerivedTitles: true, includeLastMessage: true },
  ])("never reads a transcript for metadataOnly even with preview options %j", async (previews) => {
    fixture.usage.mockImplementation(() => {
      throw new Error("Transcript usage read forbidden");
    });
    fixture.titles.mockImplementation(() => {
      throw new Error("Transcript title read forbidden");
    });
    const respond = await describeSession({
      key: "agent:main:cron:recon:run:1",
      metadataOnly: true,
      ...previews,
    });
    expect(respond).toHaveBeenCalledWith(
      true,
      {
        session: expect.objectContaining({
          key: "agent:main:cron:recon:run:1",
          sessionId: "synthetic-recon-session",
        }),
      },
      undefined,
    );
    expect(fixture.usage).not.toHaveBeenCalled();
    expect(fixture.titles).not.toHaveBeenCalled();
    const row = (respond.mock.calls[0][1] as { session: Record<string, unknown> }).session;
    expect(row.lastMessagePreview).toBeUndefined();
    expect(row.derivedTitle).toBeUndefined();
    expect(row.totalTokens).toBeUndefined();
  });
  it.each([{}, { metadataOnly: false }])(
    "preserves existing usage fallback by default %j",
    async (options) => {
      const respond = await describeSession({ key: "agent:main:cron:recon:run:1", ...options });
      expect(respond.mock.calls[0][0]).toBe(true);
      expect(fixture.usage).toHaveBeenCalledOnce();
    },
  );
  it("preserves explicitly requested previews without metadataOnly", async () => {
    const respond = await describeSession({
      key: "agent:main:cron:recon:run:1",
      includeDerivedTitles: true,
      includeLastMessage: true,
    });
    expect(respond.mock.calls[0][0]).toBe(true);
    expect(fixture.titles).toHaveBeenCalledOnce();
  });
  it("returns missing metadata without transcript access", async () => {
    fixture.entry = undefined;
    const respond = await describeSession({
      key: "agent:main:cron:recon:run:1",
      metadataOnly: true,
    });
    expect(respond).toHaveBeenCalledWith(true, { session: null }, undefined);
    expect(fixture.usage).not.toHaveBeenCalled();
    expect(fixture.titles).not.toHaveBeenCalled();
  });
  it("rejects non-boolean metadataOnly at the actual RPC schema", async () => {
    const respond = await describeSession({
      key: "agent:main:cron:recon:run:1",
      metadataOnly: "true",
    });
    expect(respond.mock.calls[0][0]).toBe(false);
    expect(fixture.usage).not.toHaveBeenCalled();
  });
});
