//! NorthstarDB API Documentation Generator
//!
//! This file exists solely to generate documentation for the public API.
//! Run: zig test gen_docs.zig -femit-docs=docs/public/api -fno-emit-bin

const std = @import("std");

// Public API exports
pub const db = @import("src/db.zig");
pub const txn = @import("src/txn.zig");
pub const pager = @import("src/pager.zig");
pub const wal = @import("src/wal.zig");
pub const snapshot = @import("src/snapshot.zig");
pub const ref_model = @import("src/ref_model.zig");

test {
    // Reference all modules to ensure docs are generated
    _ = db;
    _ = txn;
    _ = pager;
    _ = wal;
    _ = snapshot;
    _ = ref_model;
}
