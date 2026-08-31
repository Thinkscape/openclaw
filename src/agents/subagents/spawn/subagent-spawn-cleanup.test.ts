import { MAX_TIMER_TIMEOUT_MS } from "@openclaw/normalization-core/number-coercion";
import { describe, expect, it, vi } from "vitest";
import {
  cleanupFailedSpawnBeforeAgentStart,
  cleanupProvisionalSession,
  resolveSubagentCleanupGatewayTimeoutMs,
  terminateAcceptedCollectorRun,
} from "./subagent-spawn-cleanup.js";

function sessionChangedError(): Error {
  return Object.assign(new Error("session changed"), {
    name: "GatewayClientRequestError",
    gatewayCode: "INVALID_REQUEST",
    details: { reason: "session-changed" },
  });
}

describe("subagent cleanup gateway timeout", () => {
  it("defaults to 60 seconds and clamps configured values to a timer-safe delay", () => {
    expect(resolveSubagentCleanupGatewayTimeoutMs(undefined)).toBe(60_000);
    expect(resolveSubagentCleanupGatewayTimeoutMs(300_000)).toBe(300_000);
    expect(resolveSubagentCleanupGatewayTimeoutMs(Number.MAX_SAFE_INTEGER)).toBe(
      MAX_TIMER_TIMEOUT_MS,
    );
  });

  it("forwards a configured timeout to cleanup control calls", async () => {
    const callGateway = vi.fn().mockResolvedValue({ deleted: true });

    await cleanupProvisionalSession("agent:main:subagent:child", {
      expectedSessionId: "session-id",
      expectedLifecycleRevision: "session-revision",
      callGateway,
      timeoutMs: 300_000,
    });

    expect(callGateway).toHaveBeenCalledWith(
      expect.objectContaining({ method: "sessions.delete", timeoutMs: 300_000 }),
    );
  });

  it("forwards a configured timeout through failed-spawn cleanup", async () => {
    const callGateway = vi.fn().mockResolvedValue({ deleted: true });

    await cleanupFailedSpawnBeforeAgentStart({
      childSessionKey: "agent:main:subagent:child",
      expectedSessionId: "session-id",
      expectedLifecycleRevision: "session-revision",
      callGateway,
      timeoutMs: 300_000,
    });

    expect(callGateway).toHaveBeenCalledWith(
      expect.objectContaining({ method: "sessions.delete", timeoutMs: 300_000 }),
    );
  });

  it("forwards a configured timeout through accepted collector termination", async () => {
    const callGateway = vi.fn().mockResolvedValue({
      aborted: true,
      runIds: ["gateway-run"],
    });

    await terminateAcceptedCollectorRun({
      childSessionKey: "agent:main:subagent:child",
      gatewayRunId: "gateway-run",
      callGateway,
      timeoutMs: 300_000,
    });

    expect(callGateway).toHaveBeenCalledWith(
      expect.objectContaining({ method: "chat.abort", timeoutMs: 300_000 }),
    );
  });
});

describe("subagent spawn cleanup identity", () => {
  it("requires both frozen session identities before deletion", async () => {
    const callGateway = vi.fn();

    await expect(
      cleanupProvisionalSession("agent:main:subagent:child", {
        expectedSessionId: "session-id",
        callGateway,
      }),
    ).resolves.toBe(false);

    expect(callGateway).not.toHaveBeenCalled();
  });

  it("accepts chat.abort only when it confirms the exact run", async () => {
    const callGateway = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, aborted: false, runIds: [] })
      .mockResolvedValueOnce({ deleted: true });

    await terminateAcceptedCollectorRun({
      childSessionKey: "agent:main:subagent:child",
      gatewayRunId: "gateway-run",
      expectedSessionId: "session-id",
      expectedLifecycleRevision: "session-revision",
      callGateway,
    });

    expect(callGateway).toHaveBeenNthCalledWith(2, {
      method: "sessions.delete",
      params: {
        key: "agent:main:subagent:child",
        emitLifecycleHooks: false,
        deleteTranscript: true,
        expectedSessionId: "session-id",
        expectedLifecycleRevision: "session-revision",
      },
      timeoutMs: 60_000,
    });
  });

  it("does not delete after chat.abort confirms the matching run", async () => {
    const callGateway = vi.fn(async () => ({
      ok: true,
      aborted: true,
      runIds: ["gateway-run"],
    }));

    await terminateAcceptedCollectorRun({
      childSessionKey: "agent:main:subagent:child",
      gatewayRunId: "gateway-run",
      expectedSessionId: "session-id",
      expectedLifecycleRevision: "session-revision",
      callGateway,
    });

    expect(callGateway).toHaveBeenCalledOnce();
  });

  it("stops cleanup when guarded deletion observes a successor lifecycle", async () => {
    const callGateway = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, aborted: true, runIds: ["different-run"] })
      .mockRejectedValueOnce(sessionChangedError());

    await expect(
      terminateAcceptedCollectorRun({
        childSessionKey: "agent:main:subagent:child",
        gatewayRunId: "gateway-run",
        expectedSessionId: "session-id",
        expectedLifecycleRevision: "session-revision",
        callGateway,
      }),
    ).resolves.toBeUndefined();

    expect(callGateway).toHaveBeenCalledTimes(2);
  });
});
