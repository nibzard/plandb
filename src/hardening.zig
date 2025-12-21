//! Hardening/fault-injection stubs.
//!
//! Placeholders for crash/fault simulation; real torn-write/short-write
//! injectors and crash harness logic are not implemented yet.

pub const FaultInjector = struct {
    pub fn simulateTornWrite() !void {
        return error.NotImplemented;
    }

    pub fn simulateShortWrite() !void {
        return error.NotImplemented;
    }
};

pub const CrashHarness = struct {
    pub fn killDuringWorkload() !void {
        return error.NotImplemented;
    }
};
