import { afterEach, describe, expect, it, vi } from "vitest";
import { useAutoCleanupTempDirTracker } from "../../../test/helpers/temp-dir.js";
import {
  closeOpenClawAgentDatabasesForTest,
  openOpenClawAgentDatabase,
} from "../../state/openclaw-agent-db.js";
import { closeOpenClawStateDatabaseForTest } from "../../state/openclaw-state-db.js";
import {
  listSessionChildEntriesReadOnly,
  listSessionEntriesCore,
  listSessionEntriesReadOnly,
  loadExactSessionEntryReadOnly,
  loadExactSessionEntryCandidatesReadOnlyBatch,
  replaceSessionEntrySync,
} from "./session-accessor.js";
import { readSessionEntryCache } from "./session-accessor.sqlite-entry-cache.js";

const dirs = useAutoCleanupTempDirTracker(afterEach);
afterEach(() => {
  vi.restoreAllMocks();
  closeOpenClawAgentDatabasesForTest();
  closeOpenClawStateDatabaseForTest();
});

function fixture() {
  const scope = {
    agentId: "main",
    env: { OPENCLAW_STATE_DIR: dirs.make("openclaw-strict-metadata-") },
    sessionKey: "agent:main:metadata",
  };
  replaceSessionEntrySync(scope, {
    sessionId: "metadata",
    updatedAt: 1,
    label: "Operational metadata",
    visibility: "draft",
    createdActor: { type: "human", source: "profile", id: "synthetic-owner" },
    skillsSnapshot: { prompt: "PRIVATE_PROMPT_SENTINEL", skills: [] },
  });
  return scope;
}

function forbidPromptDecoding() {
  const parse = JSON.parse;
  return vi.spyOn(JSON, "parse").mockImplementation((value, reviver) => {
    if (typeof value === "string" && value.includes("PRIVATE_PROMPT_SENTINEL")) {
      throw new Error("protected prompt reached JavaScript decoder");
    }
    return parse(value, reviver);
  });
}

describe("strict session metadata projection", () => {
  it("retains visibility and lineage metadata through cold exact, child and list reads", () => {
    const scope = fixture();
    replaceSessionEntrySync(
      { ...scope, sessionKey: "agent:main:metadata-child" },
      {
        sessionId: "metadata-child",
        updatedAt: 2,
        parentSessionKey: scope.sessionKey,
        skillsSnapshot: { prompt: "PRIVATE_PROMPT_SENTINEL", skills: [] },
      },
    );
    closeOpenClawAgentDatabasesForTest();
    const parse = forbidPromptDecoding();
    const result = loadExactSessionEntryReadOnly({ ...scope, projection: "metadata" });
    expect(result?.entry).toMatchObject({
      sessionId: "metadata",
      visibility: "draft",
      createdActor: { type: "human", source: "profile", id: "synthetic-owner" },
    });
    expect(result?.entry.skillsSnapshot).toBeUndefined();
    expect(listSessionChildEntriesReadOnly({ ...scope, projection: "metadata" })).toMatchObject([
      { sessionKey: "agent:main:metadata-child", entry: { parentSessionKey: scope.sessionKey } },
    ]);
    expect(listSessionEntriesReadOnly({ ...scope, projection: "metadata" })).toHaveLength(2);
    expect(parse.mock.calls.every(([value]) => !value.includes("PRIVATE_PROMPT_SENTINEL"))).toBe(
      true,
    );
  });

  it("does not reuse warmed list or mixed full-row snapshots", () => {
    const scope = fixture();
    const full = listSessionEntriesCore({ ...scope, projection: "full" })[0]?.entry;
    expect(full?.skillsSnapshot?.prompt).toBe("PRIVATE_PROMPT_SENTINEL");
    const compatibility = listSessionEntriesCore({ ...scope, clone: false, projection: "list" })[0]
      ?.entry;
    expect(compatibility?.skillsSnapshot).toBeUndefined();
    if (!compatibility) {
      throw new Error("missing compatibility fixture");
    }
    compatibility.label = "borrowed cache mutation";
    const parse = forbidPromptDecoding();
    const database = openOpenClawAgentDatabase(scope);
    const strict = readSessionEntryCache(database, {
      cache: true,
      projection: "metadata",
      fullEntryKeys: [scope.sessionKey],
    }).entries.get(scope.sessionKey);
    expect(strict?.label).toBe("Operational metadata");
    expect(strict?.skillsSnapshot).toBeUndefined();
    expect(parse.mock.calls.every(([value]) => !value.includes("PRIVATE_PROMPT_SENTINEL"))).toBe(
      true,
    );
    parse.mockRestore();
    expect(
      listSessionEntriesCore({ ...scope, projection: "full" })[0]?.entry.skillsSnapshot?.prompt,
    ).toBe("PRIVATE_PROMPT_SENTINEL");
  });

  it.each(["cold", "warm"] as const)(
    "rejects unsafe JSON without prompt decoding on %s handles",
    (temperature) => {
      for (const unsafe of [
        '{"sessionId":"metadata","updatedAt":1,"skillsSnapshot":{"prompt":"PRIVATE_PROMPT_SENTINEL"',
        '{"sessionId":"metadata","updatedAt":1}\u0000PRIVATE_PROMPT_SENTINEL',
        `{"sessionId":"metadata","updatedAt":1,"skillsSnapshot":{"prompt":${"[".repeat(1001)}"PRIVATE_PROMPT_SENTINEL"${"]".repeat(1001)}}}`,
        '{"sessionId":"metadata","updatedAt":1,"skillsSnapshot":{},"skillsSnapshot":{"prompt":"PRIVATE_PROMPT_SENTINEL"}}',
      ]) {
        const scope = fixture();
        const database = openOpenClawAgentDatabase(scope);
        listSessionEntriesCore({ ...scope, projection: "list" });
        // Synthetic imported/corrupt rows exercise strict SQL, including cold canonical admission.
        database.db
          .prepare("UPDATE session_nodes SET entry_json = ? WHERE session_key = ?")
          .run(unsafe, scope.sessionKey);
        database.db
          .prepare("UPDATE session_nodes SET entry_valid = 1 WHERE session_key = ?")
          .run(scope.sessionKey);
        if (temperature === "cold") {
          closeOpenClawAgentDatabasesForTest();
        }
        const parse = forbidPromptDecoding();
        expect(() => loadExactSessionEntryReadOnly({ ...scope, projection: "metadata" })).toThrow(
          "openclaw doctor --fix",
        );
        const grouped = loadExactSessionEntryCandidatesReadOnlyBatch([
          { ...scope, sessionKeys: [scope.sessionKey], projection: "metadata" },
        ]);
        expect(grouped[0]?.ok).toBe(false);
        if (temperature === "cold") {
          expect(() => listSessionEntriesReadOnly({ ...scope, projection: "metadata" })).toThrow(
            "openclaw doctor --fix",
          );
        } else {
          expect(listSessionEntriesReadOnly({ ...scope, projection: "metadata" })).toEqual([]);
        }
        expect(
          parse.mock.calls.every(([value]) => !value.includes("PRIVATE_PROMPT_SENTINEL")),
        ).toBe(true);
        parse.mockRestore();
        closeOpenClawAgentDatabasesForTest();
      }
    },
  );
});
