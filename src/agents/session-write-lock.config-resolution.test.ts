import { describe, expect, it } from "vitest";
import { resolveSessionWriteLockConfig } from "./session-write-lock.js";

describe("resolveSessionWriteLockConfig", () => {
  it("uses baked-in defaults when config is absent", () => {
    expect(resolveSessionWriteLockConfig()).toEqual({
      timeoutMs: 10_000,
      backoffBaseMs: 50,
      backoffCapMs: 1_000,
      backoffJitterMs: 0,
    });
  });

  it("reads configured lock tuning from session.writeLock", () => {
    expect(
      resolveSessionWriteLockConfig({
        session: {
          writeLock: {
            timeoutMs: 30_000,
            backoffBaseMs: 5,
            backoffCapMs: 50,
            backoffJitterMs: 10,
          },
        },
      }),
    ).toEqual({
      timeoutMs: 30_000,
      backoffBaseMs: 5,
      backoffCapMs: 50,
      backoffJitterMs: 10,
    });
  });

  it("clamps cap to at least the base and normalizes invalid jitter", () => {
    expect(
      resolveSessionWriteLockConfig({
        session: {
          writeLock: {
            backoffBaseMs: 200,
            backoffCapMs: 50,
            backoffJitterMs: -1,
          },
        },
      }),
    ).toEqual({
      timeoutMs: 10_000,
      backoffBaseMs: 200,
      backoffCapMs: 200,
      backoffJitterMs: 0,
    });
  });
});
