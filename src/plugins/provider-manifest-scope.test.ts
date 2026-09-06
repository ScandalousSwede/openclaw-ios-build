import { expect, it, vi } from "vitest";
import {
  shouldUnconditionallySuppress,
  shouldSuppressBuiltInModel,
} from "../agents/model-suppression.js";
import {
  resolveProviderEndpoint,
  resolveProviderRequestCapabilities,
} from "../agents/provider-attribution.js";
import { listOpenClawPluginManifestMetadata } from "./manifest-metadata-scan.js";
import { withExplicitProviderRuntimeScope } from "./provider-runtime-scope.js";
vi.mock("./manifest-metadata-scan.js", () => ({
  listOpenClawPluginManifestMetadata: vi.fn(() => {
    throw new Error("unrelated manifests attempted");
  }),
}));
vi.mock("./manifest-contract-eligibility.js", () => ({
  loadManifestMetadataSnapshot: () => {
    throw new Error("global suppression attempted");
  },
  isManifestPluginAvailableForControlPlane: () => {
    throw new Error("global eligibility attempted");
  },
}));
const manifest = {
  id: "anthropic",
  providers: ["anthropic"],
  providerEndpoints: [{ endpointClass: "anthropic-public", hosts: ["api.anthropic.com"] }],
  providerRequest: { providers: { anthropic: { family: "anthropic" } } },
  modelCatalog: {
    suppressions: [
      { provider: "anthropic", model: "blocked", reason: "blocked by owner" },
      { provider: "anthropic", model: "conditional", when: { baseUrlHosts: ["blocked.example"] } },
      { provider: "other", model: "blocked" },
    ],
  },
};
const scope = { config: {}, provider: { id: "anthropic" }, providerManifest: manifest };
it("uses exact attribution metadata without global scanning", () => {
  withExplicitProviderRuntimeScope(scope, () => {
    expect(resolveProviderEndpoint("https://api.anthropic.com").endpointClass).toBe(
      "anthropic-public",
    );
    expect(resolveProviderEndpoint("https://unknown.example").endpointClass).toBe("custom");
    expect(
      resolveProviderRequestCapabilities({
        provider: "anthropic",
        api: "anthropic-messages",
        baseUrl: "https://api.anthropic.com",
      }).endpointClass,
    ).toBe("anthropic-public");
  });
  expect(listOpenClawPluginManifestMetadata).not.toHaveBeenCalled();
});
it("retains unconditional, conditional and ownership suppression semantics", () => {
  withExplicitProviderRuntimeScope(scope, (admitted) => {
    const base = { provider: "anthropic", config: admitted.config };
    expect(shouldUnconditionallySuppress({ ...base, id: "blocked" })).toBe(true);
    expect(shouldUnconditionallySuppress({ ...base, id: "conditional" })).toBe(false);
    expect(
      shouldSuppressBuiltInModel({
        ...base,
        id: "conditional",
        baseUrl: "https://blocked.example",
      }),
    ).toBe(true);
    expect(
      shouldSuppressBuiltInModel({
        ...base,
        id: "conditional",
        baseUrl: "https://api.anthropic.com",
      }),
    ).toBe(false);
    expect(shouldSuppressBuiltInModel({ ...base, provider: "other", id: "blocked" })).toBe(false);
    expect(() => shouldUnconditionallySuppress({ ...base, config: {}, id: "blocked" })).toThrow(
      "outside",
    );
  });
});
it("never reuses suppression or endpoint caches across scopes", () => {
  withExplicitProviderRuntimeScope(scope, (a) =>
    expect(
      shouldUnconditionallySuppress({ provider: "anthropic", id: "blocked", config: a.config }),
    ).toBe(true),
  );
  withExplicitProviderRuntimeScope(
    {
      ...scope,
      providerManifest: { ...manifest, modelCatalog: { suppressions: [] }, providerEndpoints: [] },
    },
    (a) => {
      expect(
        shouldUnconditionallySuppress({ provider: "anthropic", id: "blocked", config: a.config }),
      ).toBe(false);
      expect(resolveProviderEndpoint("https://api.anthropic.com").endpointClass).toBe("custom");
    },
  );
});
it("rejects manifest identity or ownership mismatch before callback", () => {
  for (const providerManifest of [
    { ...manifest, id: "other" },
    { ...manifest, providers: ["other"] },
  ]) {
    expect(() =>
      withExplicitProviderRuntimeScope({ ...scope, providerManifest }, () => {
        throw new Error("callback reached");
      }),
    ).toThrow("does not own");
  }
});
