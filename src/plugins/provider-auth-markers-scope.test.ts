import { expect, it, vi } from "vitest";
import {
  isKnownEnvApiKeyMarker,
  listKnownNonSecretApiKeyMarkers,
} from "../agents/model-auth-markers.js";
import { createBundledAnthropicAuthLookupMaps } from "../plugin-sdk/agent-core.js";
import { withExplicitProviderRuntimeScope } from "./provider-runtime-scope.js";
import { resolveProviderSyntheticAuthWithPlugin } from "./provider-runtime.js";
vi.mock("./manifest-metadata-scan.js", () => ({
  listOpenClawPluginManifestMetadata: () => {
    throw new Error("global metadata attempted");
  },
}));
const base = {
  config: {},
  provider: { id: "anthropic" },
  providerManifest: { id: "anthropic", providers: ["anthropic"] },
  authLookupMaps: createBundledAnthropicAuthLookupMaps(),
};
it("scoped markers preserve declared/core semantics without global caches", () => {
  withExplicitProviderRuntimeScope(
    {
      ...base,
      providerManifest: { ...base.providerManifest, nonSecretAuthMarkers: ["fixture-marker"] },
    },
    () => {
      expect(listKnownNonSecretApiKeyMarkers()).toContain("fixture-marker");
      expect(isKnownEnvApiKeyMarker("ANTHROPIC_API_KEY")).toBe(true);
      expect(isKnownEnvApiKeyMarker("ARBITRARY_SECRET")).toBe(false);
    },
  );
  withExplicitProviderRuntimeScope(base, () =>
    expect(listKnownNonSecretApiKeyMarkers()).not.toContain("fixture-marker"),
  );
});
it("synthetic auth uses actual scoped callback and absent hook stays absent", () => {
  let calls = 0;
  const context = { provider: "anthropic" };
  withExplicitProviderRuntimeScope(
    {
      ...base,
      provider: {
        id: "anthropic",
        resolveSyntheticAuth() {
          calls++;
          return undefined;
        },
      },
    },
    (a) => {
      expect(
        resolveProviderSyntheticAuthWithPlugin({
          provider: "anthropic",
          config: a.config,
          context,
        }),
      ).toBeUndefined();
      expect(() =>
        resolveProviderSyntheticAuthWithPlugin({ provider: "other", config: a.config, context }),
      ).toThrow("outside");
      expect(() =>
        resolveProviderSyntheticAuthWithPlugin({ provider: "anthropic", config: {}, context }),
      ).toThrow("outside");
    },
  );
  expect(calls).toBe(1);
  withExplicitProviderRuntimeScope(base, () =>
    expect(
      resolveProviderSyntheticAuthWithPlugin({ provider: "anthropic", context }),
    ).toBeUndefined(),
  );
});
