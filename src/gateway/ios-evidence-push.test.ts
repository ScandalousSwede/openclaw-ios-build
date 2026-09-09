import { generateKeyPairSync } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import type { PairedDevice } from "../infra/device-pairing.js";
import {
  resolveApnsAuthConfigFromEnv,
  resolveApnsRelayConfigFromEnv,
  sendApnsEvidenceAlert,
  type ApnsAuthConfig,
  type ApnsRegistration,
} from "../infra/push-apns.js";
import { createIosEvidenceNotificationSender } from "./ios-evidence-push.js";

const providerId = "12345678-1234-1234-1234-123456789abc";
const input = { targetDeviceId: "ios-device", operationId: "operation-1", eventId: "event-1" };
const directPrivateKey = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({
  format: "pem",
  type: "pkcs8",
});
const relayKeys = generateKeyPairSync("ed25519");
const gatewayIdentity = {
  deviceId: "gateway-device",
  publicKeyPem: relayKeys.publicKey.export({ format: "pem", type: "spki" }),
  privateKeyPem: relayKeys.privateKey.export({ format: "pem", type: "pkcs8" }),
};

type SendParams = Parameters<typeof sendApnsEvidenceAlert>[0];
type DirectParams = Extract<SendParams, { auth: ApnsAuthConfig }>;
type RelayParams = Exclude<SendParams, DirectParams>;

function fixture(transport: "direct" | "relay" = "direct") {
  let paired: PairedDevice | null = {
    deviceId: input.targetDeviceId,
    publicKey: "paired-public-key",
    platform: "iOS 18",
    roles: ["operator"],
    createdAtMs: 1,
    approvedAtMs: 1,
    tokens: {
      operator: {
        token: "opaque-operator-token",
        role: "operator",
        scopes: ["operator.read"],
        createdAtMs: 1,
      },
    },
  };
  let registration: ApnsRegistration | null =
    transport === "direct"
      ? {
          transport: "direct",
          nodeId: input.targetDeviceId,
          token: "a".repeat(64),
          topic: "test.openclaw.ios",
          environment: "sandbox",
          updatedAtMs: 1,
        }
      : {
          transport: "relay",
          nodeId: input.targetDeviceId,
          relayHandle: "opaque-relay-handle",
          sendGrant: "opaque-relay-grant",
          installationId: "installation-1",
          topic: "test.openclaw.ios",
          environment: "sandbox",
          distribution: "official",
          relayOrigin: "https://relay.example.test",
          updatedAtMs: 1,
        };
  const directRequest = vi.fn<NonNullable<DirectParams["requestSender"]>>().mockResolvedValue({
    status: 200,
    apnsId: providerId,
    body: "",
  });
  const relayRequest = vi.fn<NonNullable<RelayParams["relayRequestSender"]>>().mockResolvedValue({
    ok: true,
    status: 200,
    apnsId: providerId,
  });
  const deps = {
    getPairedDevice: vi.fn(async () => structuredClone(paired)),
    loadApnsRegistration: vi.fn(async () => structuredClone(registration)),
    resolveDirectAuth: vi.fn<typeof resolveApnsAuthConfigFromEnv>(async () => ({
      ok: true as const,
      value: { teamId: "TESTTEAM", keyId: "TESTKEY", privateKey: directPrivateKey },
    })),
    resolveRelayConfig: vi.fn<typeof resolveApnsRelayConfigFromEnv>(() => ({
      ok: true as const,
      value: { baseUrl: "https://relay.example.test", timeoutMs: 1000 },
    })),
    getRuntimeConfig: vi.fn(() => ({ gateway: {} })),
    getGatewayIdentity: vi.fn(() => gatewayIdentity),
    sendAlert: vi.fn(async (params: SendParams) => {
      if (params.registration.transport === "relay") {
        return await sendApnsEvidenceAlert({
          ...(params as RelayParams),
          relayRequestSender: relayRequest,
        });
      }
      return await sendApnsEvidenceAlert({
        ...(params as DirectParams),
        requestSender: directRequest,
      });
    }),
  };
  const authorizeSend = vi.fn(async () => true);
  return {
    deps,
    send: createIosEvidenceNotificationSender(deps),
    options: { authorizeSend },
    directRequest,
    relayRequest,
    setPairing: (value: PairedDevice | null) => {
      paired = value;
    },
    getPairing: () => structuredClone(paired!),
    setRegistration: (value: ApnsRegistration | null) => {
      registration = value;
    },
    getRegistration: () => structuredClone(registration!),
  };
}

function firstRequest<T>(calls: readonly (readonly [T])[]): T {
  const call = calls[0];
  if (!call) {
    throw new Error("Expected one transport request");
  }
  return call[0];
}

function operatorToken(paired: PairedDevice) {
  const token = paired.tokens?.operator;
  if (!token) {
    throw new Error("Expected operator token in fixture");
  }
  return token;
}

const expectedPayload = {
  aps: {
    alert: {
      title: "Argus evidence available",
      body: "Open OpenClaw to inspect the recorded evidence.",
    },
  },
  openclaw: {
    kind: "argus.evidence",
    gatewayDeviceId: gatewayIdentity.deviceId,
    operationId: input.operationId,
    eventId: input.eventId,
  },
};

describe("sendIosEvidenceNotification", () => {
  it.each(["direct", "relay"] as const)(
    "sends exactly one strict pointer through the real %s transport",
    async (transport) => {
      const f = fixture(transport);
      const digest = "b".repeat(64);
      const result = await f.send({ ...input, artifactSha256: digest }, f.options);
      expect(result).toEqual({
        status: "provider_accepted",
        transport,
        providerId,
        httpStatus: 200,
      });
      const request = transport === "direct" ? f.directRequest : f.relayRequest;
      expect(request).toHaveBeenCalledTimes(1);
      const sent = request.mock.calls[0]?.[0];
      if (!sent) {
        throw new Error("Expected one transport request");
      }
      expect(sent).toMatchObject({
        payload: {
          ...expectedPayload,
          openclaw: { ...expectedPayload.openclaw, artifactSha256: digest },
        },
        pushType: "alert",
        priority: "10",
      });
      expect(sent.payload).toEqual({
        ...expectedPayload,
        openclaw: { ...expectedPayload.openclaw, artifactSha256: digest },
      });
      if (transport === "relay") {
        expect(f.directRequest).not.toHaveBeenCalled();
        expect(f.deps.resolveDirectAuth).not.toHaveBeenCalled();
        expect(f.deps.resolveRelayConfig.mock.calls[0]).toEqual([
          process.env,
          {},
          { registrationRelayOrigin: "https://relay.example.test" },
        ]);
        const relay = firstRequest(f.relayRequest.mock.calls);
        expect(relay.gatewayDeviceId).toBe(gatewayIdentity.deviceId);
        expect(relay.signature.length).toBeGreaterThan(0);
        expect(JSON.parse(relay.bodyJson).payload).toEqual(relay.payload);
      } else {
        expect(f.relayRequest).not.toHaveBeenCalled();
        expect(f.deps.resolveRelayConfig).not.toHaveBeenCalled();
        expect(firstRequest(f.directRequest.mock.calls).bearerToken.split(".")).toHaveLength(3);
      }
    },
  );

  it("accepts maximum scalar-count operation and event IDs without truncation", async () => {
    const f = fixture();
    const operationId = "😀".repeat(300);
    const eventId = "🚀".repeat(300);
    expect((await f.send({ ...input, operationId, eventId }, f.options)).status).toBe(
      "provider_accepted",
    );
    expect(firstRequest(f.directRequest.mock.calls).payload).toEqual({
      ...expectedPayload,
      openclaw: { ...expectedPayload.openclaw, operationId, eventId },
    });
  });

  it("accepts exact 128-scalar target and gateway identities", async () => {
    const f = fixture();
    const targetDeviceId = "😀".repeat(128);
    const gatewayDeviceId = "🚀".repeat(128);
    f.setPairing({ ...f.getPairing(), deviceId: targetDeviceId });
    f.setRegistration({ ...f.getRegistration(), nodeId: targetDeviceId });
    f.deps.getGatewayIdentity.mockReturnValue({ ...gatewayIdentity, deviceId: gatewayDeviceId });
    expect((await f.send({ ...input, targetDeviceId }, f.options)).status).toBe(
      "provider_accepted",
    );
    expect(firstRequest(f.directRequest.mock.calls).payload).toEqual({
      ...expectedPayload,
      openclaw: { ...expectedPayload.openclaw, gatewayDeviceId },
    });
  });

  it("rejects gateway identities outside the receiver's 128-scalar contract", async () => {
    const f = fixture();
    f.deps.getGatewayIdentity.mockReturnValue({ ...gatewayIdentity, deviceId: "😀".repeat(129) });
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
    expect(f.deps.sendAlert).not.toHaveBeenCalled();
  });

  it("omits the optional digest and drops arbitrary caller payload fields", async () => {
    const f = fixture();
    const extraInput = { ...input, body: "private", gatewayDeviceId: "forged", sound: "default" };
    await f.send(extraInput, f.options);
    expect(firstRequest(f.directRequest.mock.calls).payload).toEqual(expectedPayload);
  });

  it("validates and sends one snapshot of accessor-backed identifiers", async () => {
    const f = fixture();
    let reads = 0;
    const accessorInput = {
      ...input,
      get artifactSha256() {
        return reads++ === 0 ? undefined : "unvalidated private metadata";
      },
    };
    expect((await f.send(accessorInput, f.options)).status).toBe("provider_accepted");
    expect(firstRequest(f.directRequest.mock.calls).payload).toEqual(expectedPayload);
  });

  it("returns unavailable without exposing a throwing input accessor", async () => {
    const f = fixture();
    const accessorInput = {
      ...input,
      get artifactSha256(): string {
        throw new Error("private accessor detail");
      },
    };
    expect(await f.send(accessorInput, f.options)).toEqual({ status: "not_sent_unavailable" });
    expect(f.directRequest).not.toHaveBeenCalled();
    expect(f.deps.getPairedDevice).not.toHaveBeenCalled();
  });

  it.each([
    { targetDeviceId: " ios-device" },
    { targetDeviceId: "x".repeat(129) },
    { eventId: "format\u200dcontrol" },
    { eventId: "unpaired\ud800" },
    { eventId: "\u0085edge" },
    { operationId: "" },
    { eventId: "trailing " },
    { eventId: "control\nvalue" },
    { operationId: "x".repeat(301) },
    { artifactSha256: "A".repeat(64) },
    { artifactSha256: "b".repeat(63) },
  ])("rejects malformed exact identifiers before reading state: %j", async (change) => {
    const f = fixture();
    expect(await f.send({ ...input, ...change }, f.options)).toEqual({
      status: "not_sent_unavailable",
    });
    expect(f.deps.getPairedDevice).not.toHaveBeenCalled();
    expect(f.deps.sendAlert).not.toHaveBeenCalled();
  });

  it.each(["removed", "node-only", "revoked", "no-read", "not-ios", "no-token"])(
    "does not route from stale %s authorization",
    async (state) => {
      const f = fixture();
      const paired = f.getPairing();
      if (state === "node-only") {
        paired.roles = ["node"];
      }
      if (state === "revoked") {
        operatorToken(paired).revokedAtMs = 2;
      }
      if (state === "no-read") {
        operatorToken(paired).scopes = ["operator.approvals"];
      }
      if (state === "not-ios") {
        paired.platform = "macOS";
      }
      if (state === "no-token") {
        paired.tokens = {};
      }
      f.setPairing(state === "removed" ? null : paired);
      expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
      expect(f.deps.sendAlert).not.toHaveBeenCalled();
      expect(f.options.authorizeSend).not.toHaveBeenCalled();
    },
  );

  it("accepts iPadOS with current inherited operator.admin read scope", async () => {
    const f = fixture();
    const paired = f.getPairing();
    paired.platform = "iPadOS 18";
    operatorToken(paired).scopes = ["operator.admin"];
    f.setPairing(paired);
    expect((await f.send(input, f.options)).status).toBe("provider_accepted");
  });

  it.each(["removed", "revoked", "scope", "identity", "registration"])(
    "rechecks %s changed during caller authorization",
    async (change) => {
      const f = fixture();
      f.options.authorizeSend.mockImplementation(async () => {
        const paired = f.getPairing();
        if (change === "revoked") {
          operatorToken(paired).revokedAtMs = 2;
        }
        if (change === "scope") {
          operatorToken(paired).scopes = [];
        }
        if (change === "identity") {
          paired.publicKey = "replacement";
        }
        f.setPairing(change === "removed" ? null : paired);
        if (change === "registration") {
          f.setRegistration({ ...f.getRegistration(), updatedAtMs: 2 });
        }
        return true;
      });
      expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
      expect(f.deps.sendAlert).not.toHaveBeenCalled();
    },
  );

  it("rechecks pairing revoked while direct auth is loading", async () => {
    const f = fixture();
    f.deps.resolveDirectAuth.mockImplementation(async () => {
      f.setPairing(null);
      return {
        ok: true,
        value: { teamId: "TESTTEAM", keyId: "TESTKEY", privateKey: directPrivateKey },
      };
    });
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
    expect(f.deps.sendAlert).not.toHaveBeenCalled();
  });

  it("holds without a request when the caller's final deny check changes", async () => {
    const f = fixture();
    f.options.authorizeSend.mockResolvedValue(false);
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_held" });
    expect(f.deps.sendAlert).not.toHaveBeenCalled();
  });

  it("does not admit a malformed truthy result from a JavaScript plugin callback", async () => {
    const f = fixture();
    Reflect.set(f.options, "authorizeSend", async () => "true");
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_held" });
    expect(f.deps.sendAlert).not.toHaveBeenCalled();
    expect(f.directRequest).not.toHaveBeenCalled();
  });

  it("does not expose errors from failed policy or configuration preparation", async () => {
    const f = fixture();
    f.options.authorizeSend.mockRejectedValue(new Error("private-token-error"));
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
    expect(f.deps.sendAlert).not.toHaveBeenCalled();
    f.deps.resolveDirectAuth.mockRejectedValue(new Error("private-key-path"));
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
  });

  it("fails closed when direct authentication cannot be resolved", async () => {
    const f = fixture();
    f.deps.resolveDirectAuth.mockResolvedValue({
      ok: false,
      error: "private configuration detail",
    });
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
    expect(f.options.authorizeSend).not.toHaveBeenCalled();
    expect(f.directRequest).not.toHaveBeenCalled();
  });

  it("reports malformed direct signing material as unavailable before dispatch", async () => {
    const f = fixture();
    f.deps.resolveDirectAuth.mockResolvedValue({
      ok: true,
      value: { teamId: "TESTTEAM", keyId: "TESTKEY", privateKey: "invalid synthetic key" },
    });
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
    expect(f.directRequest).not.toHaveBeenCalled();
  });

  it("uses the actual relay origin guard before any send", async () => {
    const f = fixture("relay");
    f.deps.resolveRelayConfig.mockImplementation((_env, config, options) =>
      resolveApnsRelayConfigFromEnv(
        { OPENCLAW_APNS_RELAY_BASE_URL: "https://different-relay.example.test" },
        config,
        options,
      ),
    );
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
    expect(f.options.authorizeSend).not.toHaveBeenCalled();
    expect(f.relayRequest).not.toHaveBeenCalled();
  });

  it("does not send when the registration is missing", async () => {
    const f = fixture();
    f.setRegistration(null);
    expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
    expect(f.deps.sendAlert).not.toHaveBeenCalled();
  });

  it("returns a bounded explicit rejection without cleaning registration or retrying", async () => {
    const f = fixture();
    f.directRequest.mockResolvedValue({
      status: 410,
      apnsId: providerId,
      body: JSON.stringify({ reason: "Unregistered private-content" }),
    });
    expect(await f.send(input, f.options)).toEqual({
      status: "provider_rejected",
      transport: "direct",
      httpStatus: 410,
      providerId,
    });
    expect(f.directRequest).toHaveBeenCalledTimes(1);
    expect(f.getRegistration()).not.toBeNull();
  });

  it.each(["direct", "relay"] as const)(
    "preserves uncertain %s acceptance after an ambiguous transport failure",
    async (transport) => {
      const f = fixture(transport);
      const request = transport === "direct" ? f.directRequest : f.relayRequest;
      request.mockRejectedValue(new Error("timeout with private route"));
      expect(await f.send(input, f.options)).toEqual({ status: "acceptance_unknown", transport });
      expect(request).toHaveBeenCalledTimes(1);
    },
  );

  it("omits malformed provider identifiers and does not call an inconsistent reply accepted", async () => {
    const f = fixture("relay");
    f.relayRequest.mockResolvedValue({ ok: false, status: 200, apnsId: "private-body\n" });
    expect(await f.send(input, f.options)).toEqual({
      status: "acceptance_unknown",
      transport: "relay",
      httpStatus: 200,
    });
  });

  it("enforces the serialized UTF-8 byte limit before entering the low-level sender", async () => {
    const f = fixture();
    const registration = f.getRegistration();
    expect(registration.transport).toBe("direct");
    await expect(
      sendApnsEvidenceAlert({
        nodeId: input.targetDeviceId,
        registration: registration as DirectParams["registration"],
        auth: { teamId: "TESTTEAM", keyId: "TESTKEY", privateKey: directPrivateKey },
        gatewayDeviceId: "gateway",
        operationId: "😀".repeat(1100),
        eventId: "event",
        requestSender: f.directRequest,
      }),
    ).rejects.toThrow("4096 bytes");
    expect(f.directRequest).not.toHaveBeenCalled();
  });

  it.each(["direct", "relay"] as const)(
    "blocks %s transport when pairing changes after sender admission",
    async (transport) => {
      const f = fixture(transport);
      const admittedSend = f.deps.sendAlert.getMockImplementation()!;
      f.deps.sendAlert.mockImplementation(async (params) => {
        f.setPairing(null);
        return await admittedSend(params);
      });
      expect(await f.send(input, f.options)).toEqual({ status: "not_sent_unavailable" });
      expect(f.directRequest).not.toHaveBeenCalled();
      expect(f.relayRequest).not.toHaveBeenCalled();
    },
  );

  it.each(["direct", "relay"] as const)(
    "blocks %s transport when the repeatable caller deny check changes",
    async (transport) => {
      const f = fixture(transport);
      f.options.authorizeSend.mockResolvedValueOnce(true).mockResolvedValue(false);
      expect(await f.send(input, f.options)).toEqual({ status: "not_sent_held" });
      expect(f.directRequest).not.toHaveBeenCalled();
      expect(f.relayRequest).not.toHaveBeenCalled();
    },
  );
});
