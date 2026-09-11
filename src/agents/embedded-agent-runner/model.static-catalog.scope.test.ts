import { expect, it, vi } from "vitest";
import { loadPluginManifestRegistryCore } from "../../plugins/manifest-registry.js";
import { withExplicitProviderRuntimeScope } from "../../plugins/provider-runtime-scope.js";
import { resolveManifestModelCatalogProviderAliasMetadata } from "./model.static-catalog.js";
vi.mock("../../plugins/manifest-registry.js", () => ({
  loadPluginManifestRegistryCore: vi.fn(() => {
    throw new Error("global registry attempted");
  }),
}));
vi.mock("../../plugins/current-plugin-metadata-snapshot.js", () => ({
  getCurrentPluginMetadataSnapshot: () => undefined,
}));
it("admitted provider alias uses the immutable descriptor without registry", () => {
  withExplicitProviderRuntimeScope(
    {
      config: {},
      provider: { id: "anthropic", label: "Anthropic", auth: [], aliases: ["claude"] },
    },
    (admitted) => {
      for (const provider of ["anthropic", "claude"]) {
        expect(
          resolveManifestModelCatalogProviderAliasMetadata({ provider, cfg: admitted.config }),
        ).toEqual({ provider: "anthropic" });
      }
      expect(() =>
        resolveManifestModelCatalogProviderAliasMetadata({ provider: "anthropic", cfg: {} }),
      ).toThrow("outside");
      expect(() =>
        resolveManifestModelCatalogProviderAliasMetadata({
          provider: "other",
          cfg: admitted.config,
        }),
      ).toThrow("outside");
    },
  );
  expect(loadPluginManifestRegistryCore).not.toHaveBeenCalled();
});
it("ordinary alias resolution keeps its registry path", () => {
  expect(() =>
    resolveManifestModelCatalogProviderAliasMetadata({ provider: "anthropic", cfg: {} }),
  ).toThrow("global registry attempted");
});
