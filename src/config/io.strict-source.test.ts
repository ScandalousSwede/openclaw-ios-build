import fs from "node:fs/promises";
import path from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { loadDotEnv, loadGlobalRuntimeDotEnvFiles } from "../infra/dotenv.js";
import { loadValidatedSourceConfigForProvider } from "../plugin-sdk/agent-core.js";
import { readSourceConfigStrict } from "./io.js";
import { withTempHome, writeOpenClawConfig } from "./test-helpers.js";
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
    vi.stubEnv("ARGUS_FIXTURE_MODEL", "anthropic/claude-sonnet-5");
    const configPath = await writeOpenClawConfig(home, { $include: "included.json" });
    await fs.writeFile(
      path.join(path.dirname(configPath), "included.json"),
      JSON.stringify({
        agents: { defaults: { model: { primary: "${ARGUS_FIXTURE_MODEL}" } } },
        auth: { profiles: { "anthropic:fixture": { provider: "anthropic", mode: "api_key" } } },
      }),
    );
    const cfg = await loadValidatedSourceConfigForProvider();
    expect(loadDotEnv).not.toHaveBeenCalled();
    expect(loadGlobalRuntimeDotEnvFiles).toHaveBeenCalled();
    expect(cfg.agents?.defaults?.model).toEqual({ primary: "anthropic/claude-sonnet-5" });
    expect(cfg.auth?.profiles?.["anthropic:fixture"].mode).toBe("api_key");
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
        if (kind === "malformed") await fs.writeFile(configPath, "{invalid");
      }
      await expect(loadValidatedSourceConfigForProvider()).rejects.toThrow();
    });
  },
);
it("strict includes never return unresolved root config", async () => {
  await withTempHome(async (home) => {
    await writeOpenClawConfig(home, {
      agents: { defaults: { model: "anthropic/claude-sonnet-5" } },
      $include: "missing.json",
    });
    await expect(readSourceConfigStrict()).rejects.toThrow(/Strict source/);
  });
});
