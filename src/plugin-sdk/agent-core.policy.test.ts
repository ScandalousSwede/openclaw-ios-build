import { describe, expect, it } from "vitest";
import type { AnyAgentTool } from "../agents/agent-tools.types.js";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import { filterConfiguredPluginTools } from "./agent-core.js";

const names = ["evidence_list", "evidence_detail", "evidence_artifact"];
const tools = names.map((name) => ({ name })) as AnyAgentTool[];
const filter = (config: OpenClawConfig) =>
  filterConfiguredPluginTools({
    config,
    agentId: "main",
    modelProvider: "provider",
    modelId: "model",
    pluginId: "evidence",
    tools,
  });
describe("configured supplied plugin tool policy", () => {
  it("preserves exact supplied objects through explicitly extended coding profile", async () => {
    const result = await filter({ tools: { profile: "coding", alsoAllow: names } });
    expect(result).toEqual(tools);
    expect(result[0]).toBe(tools[0]);
  });
  it("global denial wins over explicit admission", async () => {
    expect(
      (await filter({ tools: { alsoAllow: names, deny: [names[0]] } })).map((t) => t.name),
    ).toEqual(names.slice(1));
  });
  it("provider denial is applied", async () => {
    expect(
      (
        await filter({
          tools: { alsoAllow: names, byProvider: { provider: { deny: [names[1]] } } },
        })
      ).map((t) => t.name),
    ).toEqual([names[0], names[2]]);
  });
  it("agent denial is applied", async () => {
    expect(
      (
        await filter({
          tools: { alsoAllow: names },
          agents: { list: [{ id: "main", tools: { deny: [names[2]] } }] },
        })
      ).map((t) => t.name),
    ).toEqual(names.slice(0, 2));
  });
});
