import fs from "node:fs/promises";
import path from "node:path";
import { inspect } from "node:util";
import { afterEach, expect, it, vi } from "vitest";
import { loadDotEnv, loadGlobalRuntimeDotEnvFiles } from "../infra/dotenv.js";
import { loadValidatedSourceConfigForProvider } from "../plugin-sdk/agent-core.js";
import { readSourceConfigStrict } from "./io.js";
import { withTempHome, writeOpenClawConfig } from "./test-helpers.js";
import { validateConfigObjectRaw } from "./validation.js";
vi.mock("./materialize.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./materialize.js")>()),
  materializeRuntimeConfig: () => {
    throw new Error("unrelated runtime defaults invoked");
  },
}));
vi.mock("../plugins/plugin-metadata-snapshot.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../plugins/plugin-metadata-snapshot.js")>()),
  loadPluginMetadataSnapshot: () => {
    throw new Error("registry discovery invoked");
  },
  resolvePluginMetadataSnapshot: () => {
    throw new Error("registry discovery invoked");
  },
}));
vi.mock("../infra/dotenv.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../infra/dotenv.js")>();
  return {
    ...actual,
    loadDotEnv: vi.fn(() => {
      throw new Error("workspace dotenv attempted");
    }),
    loadGlobalRuntimeDotEnvFiles: vi.fn(actual.loadGlobalRuntimeDotEnvFiles),
  };
});
afterEach(() => vi.unstubAllEnvs());
it("preserves authored includes/env/auth and avoids runtime defaults/registry", async () => {
  await withTempHome(async (home) => {
    vi.stubEnv("ARGUS_FIXTURE_MODEL", "anthropic/claude-sonnet-4-20250514");
    const configPath = await writeOpenClawConfig(home, { $include: "included.json" });
    await fs.writeFile(
      path.join(path.dirname(configPath), "included.json"),
      JSON.stringify({
        agents: {
          entries: { main: {} },
          defaults: { model: { primary: "${ARGUS_FIXTURE_MODEL}" } },
        },
        auth: { profiles: { "anthropic:fixture": { provider: "anthropic", mode: "api_key" } } },
      }),
    );
    const checked = validateConfigObjectRaw(await readSourceConfigStrict());
    expect(checked.ok, JSON.stringify(checked)).toBe(true);
    const cfg = await loadValidatedSourceConfigForProvider();
    expect(loadDotEnv).not.toHaveBeenCalled();
    expect(loadGlobalRuntimeDotEnvFiles).toHaveBeenCalled();
    expect(cfg.agents?.defaults?.model).toEqual({ primary: "anthropic/claude-sonnet-4-20250514" });
    expect(cfg.auth?.profiles?.["anthropic:fixture"]?.mode).toBe("api_key");
    expect(cfg.agents?.defaults?.compaction).toBeUndefined();
  });
});
it.each(["missing", "empty", "malformed", "broken-include", "invalid-core"])(
  "rejects %s source without fallback",
  async (kind) => {
    await withTempHome(async (home) => {
      if (kind !== "missing") {
        const configPath = await writeOpenClawConfig(
          home,
          kind === "broken-include"
            ? { $include: "missing.json" }
            : kind === "invalid-core"
              ? { agents: { defaults: { model: 42 } } }
              : {},
        );
        if (kind === "malformed") {
          await fs.writeFile(configPath, "{invalid");
        }
      }
      await expect(loadValidatedSourceConfigForProvider()).rejects.toThrow();
    });
  },
);
it.each(["missing", "malformed"])(
  "strict %s includes reject without exposing source details",
  async (kind) => {
    await withTempHome(async (home) => {
      const includeName = "fixture-sensitive-configuration.json";
      const configPath = await writeOpenClawConfig(home, {
        agents: { defaults: { model: "anthropic/claude-sonnet-4-20250514" } },
        $include: includeName,
      });
      if (kind === "malformed") {
        await fs.writeFile(
          path.join(path.dirname(configPath), includeName),
          "{fixture-sensitive-content",
        );
      }
      const failure: unknown = await readSourceConfigStrict().catch((error: unknown) => error);
      expect(failure).toBeInstanceOf(Error);
      expect(failure).toMatchObject({ message: "Strict source configuration read failed" });
      expect(failure).not.toHaveProperty("cause");
      expect(inspect(failure)).not.toContain(includeName);
      expect(inspect(failure)).not.toContain("fixture-sensitive-content");
    });
  },
);
