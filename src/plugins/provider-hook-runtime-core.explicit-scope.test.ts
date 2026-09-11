import { beforeEach, describe, expect, it, vi } from "vitest";
import { createProviderHookRuntime } from "./provider-hook-runtime-core.js";
import { withExplicitProviderRuntimeScope } from "./provider-runtime-scope.js";
import type { ProviderPlugin } from "./types.js";

const ambient = vi.hoisted(() => ({
  registry: vi.fn(() => undefined),
  generation: vi.fn(() => undefined),
  request: vi.fn(() => undefined),
  workspace: vi.fn(() => undefined),
}));
vi.mock("./active-runtime-registry.js", () => ({
  getLoadedRuntimePluginRegistry: ambient.registry,
  registryContainsRuntimePluginIds: () => true,
}));
vi.mock("./runtime/generation-scope.js", () => ({
  getPluginRuntimeGenerationRegistry: ambient.generation,
}));
vi.mock("./runtime/gateway-request-scope.js", () => ({
  getPluginRuntimeGatewayRequestScope: ambient.request,
}));
vi.mock("./runtime-state.js", () => ({
  getActivePluginRegistryWorkspaceDirFromState: ambient.workspace,
}));

const provider: ProviderPlugin = {
  id: "scope-provider",
  label: "Scope provider",
  aliases: ["scope-alias"],
  auth: [],
};
function fixture() {
  const discovery = {
    isPluginProvidersLoadInFlight: vi.fn(() => false),
    resolvePluginProvidersCore: vi.fn(() => [provider]),
  };
  return { discovery, runtime: createProviderHookRuntime(discovery) };
}

beforeEach(() => vi.clearAllMocks());

describe("explicit provider scope at the runtime owner", () => {
  it("serves every loaded and discovery lookup from the admitted descriptor", () => {
    const { discovery, runtime } = fixture();
    withExplicitProviderRuntimeScope({ config: {}, provider }, (scope) => {
      const lookup = { config: scope.config, provider: "scope-alias", providerOwner: provider.id };
      expect(runtime.resolveProviderRuntimePlugin(lookup)).toBe(scope.provider);
      expect(runtime.resolveLoadedProviderRuntimePlugin(lookup)).toBe(scope.provider);
      expect(runtime.resolveProviderHookPlugin(lookup)).toBe(scope.provider);
      const query = {
        config: scope.config,
        providerRefs: ["scope-alias"],
        onlyPluginIds: [provider.id],
      };
      expect(runtime.resolveLoadedProviderPluginsForHooks(query)).toEqual([scope.provider]);
      expect(runtime.resolveProviderPluginsForHooks(query)).toEqual([scope.provider]);
      expect(runtime.resolveLoadedProviderPluginsForHooks({ ...query, onlyPluginIds: [] })).toEqual(
        [],
      );
      expect(runtime.resolveProviderPluginsForHooks({ ...query, onlyPluginIds: [] })).toEqual([]);
      const handle = runtime.resolveProviderRuntimePluginHandle(lookup);
      expect(
        runtime.ensureProviderRuntimePluginHandle({ ...lookup, runtimeHandle: handle }).plugin,
      ).toBe(scope.provider);
    });
    for (const read of Object.values(ambient)) {
      expect(read).not.toHaveBeenCalled();
    }
    expect(discovery.resolvePluginProvidersCore).not.toHaveBeenCalled();
    expect(discovery.isPluginProvidersLoadInFlight).not.toHaveBeenCalled();
  });

  it("rejects foreign configs, refs, owners and prebuilt handles before registry access", () => {
    const { discovery, runtime } = fixture();
    withExplicitProviderRuntimeScope({ config: {}, provider }, (scope) => {
      const lookup = { config: scope.config, provider: provider.id };
      for (const resolve of [
        runtime.resolveProviderRuntimePlugin,
        runtime.resolveLoadedProviderRuntimePlugin,
      ]) {
        expect(() => resolve({ ...lookup, config: {} })).toThrow(/explicit/);
        expect(() => resolve({ ...lookup, provider: "another-provider" })).toThrow(/explicit/);
        expect(() => resolve({ ...lookup, providerOwner: "another-owner" })).toThrow(/explicit/);
      }
      expect(() =>
        runtime.resolveProviderPluginsForHooks({
          config: scope.config,
          onlyPluginIds: ["another-owner"],
        }),
      ).toThrow(/explicit/);
      expect(() =>
        runtime.resolveLoadedProviderPluginsForHooks({
          config: scope.config,
          providerRefs: ["another-provider"],
        }),
      ).toThrow(/explicit/);
      expect(() =>
        runtime.ensureProviderRuntimePluginHandle({
          ...lookup,
          runtimeHandle: { ...lookup, plugin: provider },
        }),
      ).toThrow(/handle differs/);
      expect(() =>
        runtime.ensureProviderRuntimePluginHandle({
          ...lookup,
          runtimeHandle: { ...lookup, providerOwner: "another-owner", plugin: scope.provider },
        }),
      ).toThrow(/owner differs/);
    });
    expect(discovery.resolvePluginProvidersCore).not.toHaveBeenCalled();
    for (const read of Object.values(ambient)) {
      expect(read).not.toHaveBeenCalled();
    }
  });

  it("retains normal registry discovery outside the explicit scope", () => {
    const { discovery, runtime } = fixture();
    expect(runtime.resolveProviderPluginsForHooks({ config: {} })).toEqual([provider]);
    expect(discovery.resolvePluginProvidersCore).toHaveBeenCalledOnce();
  });
});
