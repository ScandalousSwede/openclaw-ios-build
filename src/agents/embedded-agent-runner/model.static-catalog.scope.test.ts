import { expect, it, vi } from "vitest";
import { loadPluginManifestRegistry } from "../../plugins/manifest-registry.js";
import { withExplicitProviderRuntimeScope } from "../../plugins/provider-runtime-scope.js";
import { canonicalizeManifestModelCatalogProviderAlias } from "./model.static-catalog.js";
vi.mock("../../plugins/manifest-registry.js", () => ({
  loadPluginManifestRegistry: vi.fn(() => {
    throw new Error("global registry attempted");
  }),
}));
it("admitted provider alias uses the immutable descriptor without registry", () => {
  withExplicitProviderRuntimeScope(
    { config: {}, provider: { id: "anthropic", aliases: ["claude"] } },
    (admitted) => {
      for (const provider of ["anthropic", "claude"]) {
        expect(
          canonicalizeManifestModelCatalogProviderAlias({ provider, cfg: admitted.config }),
        ).toBe("anthropic");
      }
      expect(() =>
        canonicalizeManifestModelCatalogProviderAlias({ provider: "anthropic", cfg: {} }),
      ).toThrow("outside");
      expect(() =>
        canonicalizeManifestModelCatalogProviderAlias({ provider: "other", cfg: admitted.config }),
      ).toThrow("outside");
    },
  );
  expect(loadPluginManifestRegistry).not.toHaveBeenCalled();
});
it("ordinary alias resolution keeps its registry path", () => {
  expect(() =>
    canonicalizeManifestModelCatalogProviderAlias({ provider: "anthropic", cfg: {} }),
  ).toThrow("global registry attempted");
});
