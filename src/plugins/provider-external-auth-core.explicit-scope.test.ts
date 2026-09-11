import { beforeEach, describe, expect, it, vi } from "vitest";
import { createProviderExternalAuthResolver } from "./provider-external-auth-core.js";
import type { ProviderExternalAuthProfile } from "./provider-external-auth.types.js";
import { withExplicitProviderRuntimeScope } from "./provider-runtime-scope.js";
import type { ProviderPlugin } from "./types.js";

const ambient = vi.hoisted(() => ({
  current: vi.fn(() => undefined),
  snapshot: vi.fn(() => {
    throw new Error("unexpected metadata discovery");
  }),
  owners: vi.fn(() => []),
  workspace: vi.fn(() => undefined),
}));
vi.mock("./current-plugin-metadata-snapshot.js", () => ({
  getCurrentPluginMetadataSnapshot: ambient.current,
}));
vi.mock("./plugin-metadata-snapshot.js", () => ({
  resolvePluginMetadataSnapshot: ambient.snapshot,
}));
vi.mock("./providers.js", () => ({ resolveExternalAuthProfileProviderPluginIds: ambient.owners }));
vi.mock("./runtime-state.js", () => ({
  getActivePluginRegistryWorkspaceDirFromState: ambient.workspace,
}));

const profile: ProviderExternalAuthProfile = {
  profileId: "scope-provider:fixture",
  credential: {
    type: "oauth",
    provider: "scope-provider",
    access: "synthetic-access",
    refresh: "synthetic-refresh",
    expires: 1,
  },
  persistence: "runtime-only",
};
const context = { env: {}, store: { version: 1, profiles: {} } };

beforeEach(() => vi.clearAllMocks());

describe("explicit provider external auth", () => {
  it("uses only the admitted external auth hook and immutable admitted config", () => {
    const resolveExternalAuthProfiles = vi.fn(() => [profile]);
    const provider: ProviderPlugin = {
      id: "scope-provider",
      label: "Scope provider",
      auth: [],
      resolveExternalAuthProfiles,
    };
    const resolveProviderPluginsForHooks = vi.fn(() => []);
    const resolver = createProviderExternalAuthResolver({ resolveProviderPluginsForHooks });
    withExplicitProviderRuntimeScope({ config: {}, provider }, (scope) => {
      expect(resolver.resolveExternalAuthProfilesWithPlugins({ context })).toEqual([profile]);
      expect(resolveExternalAuthProfiles).toHaveBeenCalledWith({
        ...context,
        config: scope.config,
      });
    });
    expect(resolveProviderPluginsForHooks).not.toHaveBeenCalled();
    for (const read of Object.values(ambient)) {
      expect(read).not.toHaveBeenCalled();
    }
  });

  it("rejects either conflicting config before invoking the provider", () => {
    const resolveExternalAuthProfiles = vi.fn(() => [profile]);
    const provider: ProviderPlugin = {
      id: "scope-provider",
      label: "Scope provider",
      auth: [],
      resolveExternalAuthProfiles,
    };
    const resolver = createProviderExternalAuthResolver({
      resolveProviderPluginsForHooks: vi.fn(() => []),
    });
    withExplicitProviderRuntimeScope({ config: {}, provider }, () => {
      expect(() =>
        resolver.resolveExternalAuthProfilesWithPlugins({ config: {}, context }),
      ).toThrow(/explicit/);
      expect(() =>
        resolver.resolveExternalAuthProfilesWithPlugins({ context: { ...context, config: {} } }),
      ).toThrow(/explicit/);
    });
    expect(resolveExternalAuthProfiles).not.toHaveBeenCalled();
    for (const read of Object.values(ambient)) {
      expect(read).not.toHaveBeenCalled();
    }
  });

  it("returns no profiles without discovering alternate providers when the admitted hook is absent", () => {
    const provider: ProviderPlugin = { id: "scope-provider", label: "Scope provider", auth: [] };
    const resolver = createProviderExternalAuthResolver({
      resolveProviderPluginsForHooks: vi.fn(() => []),
    });
    withExplicitProviderRuntimeScope({ config: {}, provider }, () => {
      expect(resolver.resolveExternalAuthProfilesWithPlugins({ context })).toEqual([]);
    });
    for (const read of Object.values(ambient)) {
      expect(read).not.toHaveBeenCalled();
    }
  });
});
