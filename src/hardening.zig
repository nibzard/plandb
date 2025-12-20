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
