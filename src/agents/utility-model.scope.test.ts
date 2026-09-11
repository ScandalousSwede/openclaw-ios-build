import { expect, it, vi } from "vitest";
import { withExplicitProviderRuntimeScope } from "../plugins/provider-runtime-scope.js";
vi.mock("../plugins/current-plugin-metadata-snapshot.js", () => ({
  getCurrentPluginMetadataSnapshot: () => {
    throw new Error("Ambient metadata was read");
  },
}));
import { resolveUtilityModelRefForAgent } from "./utility-model.js";
it("derives utility selection from admitted facts without current metadata", () => {
  withExplicitProviderRuntimeScope(
    {
      config: { agents: { entries: { main: {} } } },
      provider: { id: "anthropic", label: "Anthropic", auth: [], aliases: ["claude"] },
      providerManifest: {
        id: "anthropic",
        providers: ["anthropic"],
        modelCatalog: {
          providers: {
            anthropic: {
              defaultUtilityModel: "reviewed-small",
              models: [{ id: "reviewed-small", name: "Reviewed small" }],
            },
          },
        },
      },
    },
    (scope) => {
      expect(
        resolveUtilityModelRefForAgent({
          cfg: scope.config,
          agentId: "main",
          primaryProvider: "anthropic",
        }),
      ).toBe("anthropic/reviewed-small");
      expect(
        resolveUtilityModelRefForAgent({
          cfg: scope.config,
          agentId: "main",
          primaryProvider: "claude",
        }),
      ).toBe("anthropic/reviewed-small");
      expect(() =>
        resolveUtilityModelRefForAgent({ cfg: {}, agentId: "main", primaryProvider: "anthropic" }),
      ).toThrow(/outside/);
    },
  );
});
