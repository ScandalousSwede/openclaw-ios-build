import { describe, expect, it, vi } from "vitest";

vi.mock("../plugins/plugin-metadata-snapshot.js", () => ({
  loadPluginMetadataSnapshot: () => {
    throw new Error("Unexpected full discovery");
  },
}));
vi.mock("../plugins/current-plugin-metadata-snapshot.js", () => ({
  getCurrentPluginMetadataSnapshot: () => {
    throw new Error("Unexpected current registry");
  },
}));

import { buildProviderAuthAliasMapFromManifests } from "../agents/provider-auth-aliases.js";
import { buildAdmittedProviderAuthLookupMaps } from "./provider-env-vars.js";

type Manifest = Parameters<typeof buildAdmittedProviderAuthLookupMaps>[0]["manifests"][number];
const openai = {
  origin: "bundled",
  providers: ["openai"],
  cliBackends: [],
  setup: { providers: [{ id: "openai", envVars: ["OPENAI_API_KEY"] }] },
} satisfies Manifest;

describe("admitted provider auth reduction", () => {
  it("preserves OpenAI core precedence without unrelated auth candidates or discovery", () => {
    expect(
      buildAdmittedProviderAuthLookupMaps({ providerId: "openai", manifests: [openai] }),
    ).toEqual({
      aliasMap: {},
      envCandidateMap: { openai: ["CODEX_API_KEY", "OPENAI_API_KEY"] },
      authEvidenceMap: {},
      setupProviderFallbackRefs: ["openai"],
    });
  });
  it("derives credential aliases and deprecated choices while bounding the selected provider", () => {
    const manifest = {
      ...openai,
      providerAuthAliases: { " Legacy-Alias ": " OPENAI ", unrelated: "other" },
      providerAuthChoices: [
        {
          provider: "openai",
          method: "api-key",
          choiceId: "openai-api-key",
          choiceLabel: "API key",
          deprecatedChoiceIds: ["old-choice"],
        },
      ],
    } satisfies Manifest;
    const maps = buildAdmittedProviderAuthLookupMaps({
      providerId: "openai",
      manifests: [manifest],
    });
    expect(maps.aliasMap).toEqual({ "legacy-alias": "openai", "old-choice": "openai" });
    expect(maps.envCandidateMap["legacy-alias"]).toEqual(["OPENAI_API_KEY"]);
    expect(maps.envCandidateMap.openai).toEqual(["CODEX_API_KEY", "OPENAI_API_KEY"]);
    expect(maps.setupProviderFallbackRefs).toEqual(["legacy-alias", "old-choice", "openai"]);
    expect(maps.envCandidateMap.other).toBeUndefined();
  });
  it("reuses evidence deduplication and honors setup runtime exclusion", () => {
    const evidence = {
      type: "local-file-with-env",
      fileEnvVar: "SYNTHETIC_AUTH_FILE",
      credentialMarker: "synthetic",
    } as const;
    const manifest = {
      ...openai,
      setup: {
        requiresRuntime: false,
        providers: [
          { id: "openai", envVars: ["OPENAI_API_KEY"], authEvidence: [evidence, evidence] },
        ],
      },
    } satisfies Manifest;
    const maps = buildAdmittedProviderAuthLookupMaps({
      providerId: "openai",
      manifests: [manifest],
    });
    expect(maps.authEvidenceMap).toEqual({ openai: [evidence] });
    expect(maps.setupProviderFallbackRefs).toEqual([]);
  });
  it("keeps the shared alias reducer normalization and origin priority", () => {
    expect(
      buildProviderAuthAliasMapFromManifests([
        { origin: "workspace", providerAuthAliases: { old: "wrong" } },
        { origin: "bundled", providerAuthAliases: { " OLD ": " OPENAI " } },
        { origin: "global", providerAuthAliases: { old: "other" } },
      ]),
    ).toEqual({ old: "openai" });
  });
  it("rejects mismatched admission and noncanonical provider identity", () => {
    expect(() =>
      buildAdmittedProviderAuthLookupMaps({ providerId: "anthropic", manifests: [openai] }),
    ).toThrow(/do not own/);
    expect(() =>
      buildAdmittedProviderAuthLookupMaps({ providerId: " OPENAI ", manifests: [openai] }),
    ).toThrow(/do not own/);
  });
  it("does not mutate caller manifests or relax Anthropic core precedence", () => {
    const manifest = {
      origin: "bundled",
      providers: ["anthropic"],
      cliBackends: [],
      providerAuthAliases: { "claude-cli": "anthropic" },
      setup: { providers: [{ id: "anthropic", envVars: ["ANTHROPIC_API_KEY"] }] },
    } satisfies Manifest;
    const before = JSON.stringify(manifest);
    const maps = buildAdmittedProviderAuthLookupMaps({
      providerId: "anthropic",
      manifests: [manifest],
    });
    expect(maps.envCandidateMap.anthropic).toEqual(["ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]);
    expect(JSON.stringify(manifest)).toBe(before);
  });
});
