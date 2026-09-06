import { describe, expect, it, vi } from "vitest";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import { resolveProviderAuthLookupMaps } from "../secrets/provider-env-vars.js";
import { resolvePluginMetadataSnapshot } from "./plugin-metadata-snapshot.js";
import {
  resolveProviderRuntimePlugin,
  resolveProviderPluginsForHooks,
  wrapProviderSimpleCompletionStreamFn,
} from "./provider-hook-runtime.js";
import { resolveBundledProviderPolicySurface } from "./provider-public-artifacts.js";
import {
  withExplicitProviderRuntimeScope,
  assertExplicitProviderAdmission,
} from "./provider-runtime-scope.js";
import { prepareProviderRuntimeAuth } from "./provider-runtime.js";
import type { ProviderPlugin } from "./types.js";
vi.mock("./providers.runtime.js", () => ({
  isPluginProvidersLoadInFlight: () => {
    throw new Error("full registry attempted");
  },
  resolvePluginProviders: () => {
    throw new Error("full registry attempted");
  },
}));
const config: OpenClawConfig = { agents: { defaults: { model: "anthropic/claude-sonnet-5" } } };
const provider = { id: "anthropic" } as ProviderPlugin;
it("uses isolated config and descriptor without registry lookup", async () => {
  await withExplicitProviderRuntimeScope({ config, provider }, async (admitted) => {
    await Promise.resolve();
    expect(admitted.config).toEqual(config);
    expect(admitted.config).not.toBe(config);
    expect(resolveProviderRuntimePlugin({ provider: "anthropic", config: admitted.config })).toBe(
      admitted.provider,
    );
    expect(
      resolveProviderPluginsForHooks({ config: admitted.config, providerRefs: ["anthropic"] }),
    ).toEqual([admitted.provider]);
  });
});
it("preserves transport and runtime auth hooks with admitted config values", async () => {
  const wrapped = vi.fn(),
    transport = vi.fn(() => wrapped),
    auth = vi.fn(async () => ({ apiKey: "synthetic" }));
  const descriptor = {
    id: "anthropic",
    wrapSimpleCompletionStreamFn: transport,
    prepareRuntimeAuth: auth,
  } as unknown as ProviderPlugin;
  await withExplicitProviderRuntimeScope({ config, provider: descriptor }, async (admitted) => {
    const context = {
      config: admitted.config,
      provider: "anthropic",
      modelId: "claude-sonnet-5",
      model: {},
      streamFn: vi.fn(),
    };
    expect(
      wrapProviderSimpleCompletionStreamFn({
        provider: "anthropic",
        config: admitted.config,
        context: context as never,
      }),
    ).toBe(wrapped);
    await prepareProviderRuntimeAuth({
      provider: "anthropic",
      config: admitted.config,
      context: context as never,
    });
    expect(transport).toHaveBeenCalledWith(context);
    expect(auth).toHaveBeenCalledWith(context);
  });
});
it("rejects other provider/config and all metadata discovery", () => {
  withExplicitProviderRuntimeScope({ config, provider }, (admitted) => {
    expect(() =>
      resolveProviderRuntimePlugin({ provider: "other", config: admitted.config }),
    ).toThrow(/outside/);
    expect(() => resolveProviderRuntimePlugin({ provider: "anthropic", config })).toThrow(
      /outside/,
    );
    expect(() => resolvePluginMetadataSnapshot({ config: admitted.config })).toThrow(
      /metadata discovery/,
    );
  });
});
it("does not leak invocation scope", () => {
  withExplicitProviderRuntimeScope({ config, provider }, () => {});
  expect(() => resolveProviderRuntimePlugin({ provider: "anthropic", config })).toThrow(
    /full registry/,
  );
});
it("preserves auth metadata and policy hooks without discovery", () => {
  const maps = {
    aliasMap: {},
    envCandidateMap: { anthropic: ["ANTHROPIC_API_KEY"] },
    authEvidenceMap: {},
    setupProviderFallbackRefs: [],
  };
  const normalizeConfig = vi.fn();
  withExplicitProviderRuntimeScope(
    {
      config,
      provider: { id: "anthropic", normalizeConfig } as unknown as ProviderPlugin,
      authLookupMaps: maps,
    },
    (admitted) => {
      expect(resolveProviderAuthLookupMaps({ config: admitted.config })).toEqual(maps);
      expect(resolveBundledProviderPolicySurface("anthropic")?.normalizeConfig).toBe(
        normalizeConfig,
      );
      expect(() => resolveBundledProviderPolicySurface("other")).toThrow(/outside/);
    },
  );
});
it.each([
  { enabled: false },
  { entries: { anthropic: { enabled: false } } },
  { deny: ["anthropic"] },
  { allow: ["other"] },
])("denial prevents callback: %j", (plugins) => {
  const run = vi.fn();
  expect(() => withExplicitProviderRuntimeScope({ config: { plugins }, provider }, run)).toThrow(
    /disabled or denied/,
  );
  expect(run).not.toHaveBeenCalled();
});
it("operational plugin deny overrides enabled entry and explicit allow", () => {
  expect(() =>
    assertExplicitProviderAdmission(
      {
        plugins: {
          allow: ["argus-operational-view"],
          deny: ["argus-operational-view"],
          entries: { "argus-operational-view": { enabled: true } },
        },
      },
      "argus-operational-view",
    ),
  ).toThrow(/disabled or denied/);
});
it("async mutation of caller-owned config, aliases and auth maps cannot alter admission", async () => {
  const cfg: OpenClawConfig = { plugins: { allow: ["anthropic"] } };
  const descriptor = { id: "anthropic", aliases: ["original"] } as ProviderPlugin;
  const maps = {
    aliasMap: {},
    envCandidateMap: { anthropic: ["ORIGINAL"] },
    authEvidenceMap: {},
    setupProviderFallbackRefs: [],
  };
  await withExplicitProviderRuntimeScope(
    { config: cfg, provider: descriptor, authLookupMaps: maps },
    async (admitted) => {
      cfg.plugins!.allow!.push("evil");
      descriptor.aliases!.push("evil");
      maps.envCandidateMap.anthropic.push("EVIL");
      await Promise.resolve();
      expect(admitted.config.plugins!.allow).toEqual(["anthropic"]);
      expect(() =>
        resolveProviderRuntimePlugin({ config: admitted.config, provider: "evil" }),
      ).toThrow(/outside/);
      expect(
        resolveProviderAuthLookupMaps({ config: admitted.config }).envCandidateMap.anthropic,
      ).toEqual(["ORIGINAL"]);
      expect(() => admitted.config.plugins!.allow!.push("evil")).toThrow();
      expect(() => admitted.provider.aliases!.push("evil")).toThrow();
    },
  );
  expect(Object.isFrozen(cfg)).toBe(false);
  expect(Object.isFrozen(descriptor)).toBe(false);
});
