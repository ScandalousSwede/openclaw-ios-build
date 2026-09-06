import { expect, it, vi } from "vitest";
import manifest from "../../extensions/anthropic/openclaw.plugin.json";
import {
  resolveProviderAuthAliasMap,
  resolveProviderIdForAuth,
} from "../agents/provider-auth-aliases.js";
import { createBundledAnthropicAuthLookupMaps } from "../plugin-sdk/agent-core.js";
import { withExplicitProviderRuntimeScope } from "./provider-runtime-scope.js";
vi.mock("./plugin-metadata-snapshot.js", () => ({
  loadPluginMetadataSnapshot: () => {
    throw new Error("global metadata attempted");
  },
}));
it("preserves exact shipped auth alias metadata with no registry and no shared mutable map", () => {
  const authLookupMaps = createBundledAnthropicAuthLookupMaps();
  expect(
    manifest.providerAuthChoices.find((c) => c.deprecatedChoiceIds?.includes("claude-cli"))
      ?.provider,
  ).toBe(authLookupMaps.aliasMap["claude-cli"]);
  withExplicitProviderRuntimeScope(
    { config: {}, provider: { id: "anthropic" }, authLookupMaps },
    (a) => {
      expect(resolveProviderIdForAuth("CLAUDE-CLI", { config: a.config })).toBe("anthropic");
      expect(resolveProviderIdForAuth("anthropic")).toBe("anthropic");
      const map = resolveProviderAuthAliasMap({ config: a.config });
      map["claude-cli"] = "other";
      expect(resolveProviderIdForAuth("claude-cli", { config: a.config })).toBe("anthropic");
      expect(() => resolveProviderAuthAliasMap({ config: {} })).toThrow("outside");
      expect(() => resolveProviderAuthAliasMap({ metadataSnapshot: { plugins: [] } })).toThrow(
        "outside",
      );
    },
  );
});
