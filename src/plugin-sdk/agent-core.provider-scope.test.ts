import { beforeEach, describe, expect, it, vi } from "vitest";

const owners = vi.hoisted(() => ({
  openai: vi.fn(() => ({ id: "openai", resolveDynamicModel: () => undefined })),
  anthropic: vi.fn(() => ({ id: "anthropic", resolveDynamicModel: () => undefined })),
}));
vi.mock("../../extensions/openai/api.js", () => ({ buildOpenAIProvider: owners.openai }));
vi.mock("../../extensions/anthropic/api.js", () => ({ buildAnthropicProvider: owners.anthropic }));
vi.mock("../plugins/plugin-metadata-snapshot.js", () => ({
  loadPluginMetadataSnapshot: () => {
    throw new Error("Unexpected registry discovery");
  },
}));
vi.mock("../plugins/current-plugin-metadata-snapshot.js", () => ({
  getCurrentPluginMetadataSnapshot: () => {
    throw new Error("Unexpected current registry");
  },
}));

import {
  createBundledProviderRuntimeScopeMetadata,
  withExplicitProviderRuntimeScope,
} from "./agent-core.js";

describe("explicit bundled provider metadata", () => {
  beforeEach(() => {
    owners.openai.mockClear();
    owners.anthropic.mockClear();
  });

  it("uses the shipped OpenAI owner and metadata with incumbent credential precedence", async () => {
    const config = { plugins: { allow: ["openai"], entries: { openai: { enabled: true } } } };
    const metadata = await createBundledProviderRuntimeScopeMetadata(config, "openai");
    expect(metadata.provider.id).toBe("openai");
    expect(metadata.provider.resolveDynamicModel).toBeTypeOf("function");
    expect(metadata.providerManifest?.id).toBe("openai");
    expect(metadata.authLookupMaps).toEqual({
      aliasMap: {},
      envCandidateMap: { openai: ["CODEX_API_KEY", "OPENAI_API_KEY"] },
      authEvidenceMap: {},
      setupProviderFallbackRefs: ["openai"],
    });
    expect(owners.openai).toHaveBeenCalledOnce();
    expect(owners.anthropic).not.toHaveBeenCalled();
  });

  it.each([
    { plugins: { enabled: false } },
    { plugins: { deny: ["openai"] } },
    { plugins: { allow: ["anthropic"] } },
    { plugins: { entries: { openai: { enabled: false } } } },
  ])("rejects denied provider before its owner is imported: %j", async (config) => {
    await expect(createBundledProviderRuntimeScopeMetadata(config, "openai")).rejects.toThrow(
      /disabled or denied/,
    );
    expect(owners.openai).not.toHaveBeenCalled();
    expect(owners.anthropic).not.toHaveBeenCalled();
  });

  it("rejects arbitrary provider paths without owner construction", async () => {
    await expect(
      createBundledProviderRuntimeScopeMetadata({}, "../unreviewed" as "openai"),
    ).rejects.toThrow(/Unsupported/);
    expect(owners.openai).not.toHaveBeenCalled();
  });

  it("preserves Anthropic declarations and immutable explicit-scope behavior", async () => {
    const config = { plugins: { allow: ["anthropic"] } };
    const metadata = await createBundledProviderRuntimeScopeMetadata(config, "anthropic");
    expect(metadata.authLookupMaps?.aliasMap["claude-cli"]).toBe("anthropic");
    expect(metadata.authLookupMaps?.envCandidateMap.anthropic).toEqual([
      "ANTHROPIC_OAUTH_TOKEN",
      "ANTHROPIC_API_KEY",
    ]);
    withExplicitProviderRuntimeScope({ config, ...metadata }, (scope) => {
      expect(scope.config).not.toBe(config);
      expect(Object.isFrozen(scope.authLookupMaps)).toBe(true);
      expect(Object.isFrozen(scope.authLookupMaps?.envCandidateMap.anthropic)).toBe(true);
      expect(scope.providerManifest?.id).toBe("anthropic");
    });
    expect(config.plugins.allow).toEqual(["anthropic"]);
  });
});
