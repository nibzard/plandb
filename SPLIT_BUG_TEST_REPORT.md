# B+Tree Key Loss Bug - Test Attempt Report

## Summary
Attempted to create a targeted test to reproduce the B+tree key loss bug affecting keys like "c10", "c101", "c100" after leaf splits, as described in TODO.md.

## Test File Created
`/home/niko/plandb/test_split_bug.zig`

The test:
1. Opens a file-based database at `/tmp/test_split_bug.db`
2. Inserts keys "c1" through "c{num}" in a single transaction
3. Verifies ALL keys can be retrieved via point lookups
4. Reports which keys are missing with detailed analysis

## Blocking Issue Discovered

### Pager Bug: File Created Without Read Permission

**Location**: `/home/niko/plandb/src/pager.zig:1699`

**Bug**: The `Pager.create()` function creates a database file without read permission:

```zig
const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
```

According to Zig 0.15's `std.fs.File.CreateFlags`, the default `read` field is `false`. This means the file is opened write-only.

**Error**: When the B+tree implementation tries to perform a leaf split, it calls `updateMeta()` which attempts to read a page via `readPage()`. This fails with:
```
error: NotOpenForReading
```

**Fix Required**: Change line 1699 to:
```zig
const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = true });
```

### Test Status
Cannot reproduce the original B+tree key loss bug until the Pager bug is fixed.

## Test Implementation Details

### API Compatibility Issues Encountered
1. **Zig 0.15 ArrayList API Changes**: The new `std.ArrayList` API changed:
   - Initialize with `{}` instead of `.init(allocator)`
   - Pass `allocator` as first parameter to methods like `append()`, `deinit()`

2. **Transaction API**:
   - Use `beginWrite()` and `beginReadLatest()` instead of generic `begin()`
   - No `rollback()` method - just call `commit()` or let the transaction drop

### Next Steps
1. Fix the Pager.create() bug by adding `.read = true` to createFile flags
2. Re-run the split bug test to confirm it works
3. Verify if the original key loss bug exists or if it was related to this file handle issue

## Files Created
- `/home/niko/plandb/test_split_bug.zig` - Standalone test program
- `/home/niko/plandb/SPLIT_BUG_TEST_REPORT.md` - This report

## Recommended Fix

**File**: `/home/niko/plandb/src/pager.zig`
**Line**: 1699

```diff
- const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
+ const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = true });
```

This is a critical bug that prevents any file-based database operations that require reading during writes, including B+tree splits that need to update metadata pages.
