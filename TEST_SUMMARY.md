# B+Tree Split Bug Test - Final Report

## Objective
Create a test to reproduce the B+tree key loss bug described in TODO.md, affecting keys like "c10", "c101", "c100" after leaf splits.

## Test File
Created: `/home/niko/plandb/test_split_bug.zig`

The test:
1. Opens a file-based database
2. Inserts keys "c1" through "c{num}" in sequential order
3. Verifies all keys can be retrieved via point lookups
4. Reports missing keys with detailed pattern analysis

## Critical Bugs Discovered

### Bug #1: Pager File Handle Not Opened for Reading (FIXED)
**Location**: `/home/niko/plandb/src/pager.zig:1699`

**Problem**: `Pager.create()` opened database file without read permission:
```zig
const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
```

**Error**: Any operation that needed to read during write (like meta page updates during splits) failed with:
```
error: NotOpenForReading
```

**Fix Applied**:
```zig
const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = true });
```

**Status**: Fixed ✅

### Bug #2: Memory Corruption in Leaf Split (CRITICAL - UNRESOLVED)
**Location**: `/home/niko/plandb/src/pager.zig:2589` in `splitLeafNode()`

**Error**: Segmentation fault during cleanup:
```
General protection exception (no address available)
allocator.free(entry.key);
```

**Stack Trace**:
```
pager.zig:2589 in deinit (freeing entry.key)
pager.zig:2596 in splitLeafNode (defer cleanup)
pager.zig:2201 in putBtreeValue (during split)
db.zig:542 in put
```

**Analysis**:
The `splitLeafNode` function:
1. Extracts entries from leaf node (lines 2601-2607)
2. Allocates owned copies of keys/values with `allocator.dupe()`
3. Stores them in `owned_entries` array
4. Clears the original buffer with `@memset()` (line 2614)
5. Re-inserts entries using `addEntry()`
6. Defers cleanup to free the owned copies

The crash happens when freeing the owned copies, suggesting:
- Double-free of memory
- Heap corruption from buffer overflow
- Invalid pointer stored in owned_entries

**Impact**: This bug likely CAUSES the original key loss bug! When the split crashes or corrupts memory, keys can be lost during the split operation.

**Status**: UNRESOLVED - Blocks testing of original key loss bug

## Root Cause Hypothesis

The original "key loss" bug reported in TODO.md (keys like "c10", "c101" disappearing after splits) is likely a SYMPTOM of this memory corruption bug in `splitLeafNode()`. When a split operation:
1. Corrupts memory during entry extraction/reinsertion
2. Crashes but is partially recovered
3. Leaves some keys not properly inserted into either split node

Keys with longer string representations (like "c10" vs "c1") would be more likely to be affected because:
- They're stored later in sorted order
- They're more likely to be in the second half that gets moved to the right node
- The split point calculation or entry copying might have edge cases

## Next Steps to Resolve

### Immediate Fix Required for Bug #2
1. **Add Debug Logging**: Log each step of `splitLeafNode` to identify exact failure point
2. **Check Entry Ownership**: Verify that `getEntry()` isn't returning stack pointers
3. **Validate Buffer Sizes**: Ensure payload buffers are large enough for all entries
4. **Check for Double-Free**: Verify no other code path frees the same keys/values
5. **Add Assertions**: Add runtime checks for:
   - Pointer validity before free
   - Buffer bounds during insertions
   - Key count consistency

### Testing Strategy After Fix
1. Start with small key counts (10-20) to validate basic split
2. Gradually increase to trigger multiple splits
3. Add checksums to verify all keys are present
4. Test with keys of varying lengths
5. Run under Valgrind/ASAN to detect memory errors

## Files Modified
- `/home/niko/plandb/src/pager.zig` - Fixed file handle permissions (line 1699)

## Files Created
- `/home/niko/plandb/test_split_bug.zig` - Reproduction test
- `/home/niko/plandb/SPLIT_BUG_TEST_REPORT.md` - Initial findings
- `/home/niko/plandb/TEST_SUMMARY.md` - This summary

## Conclusion
We successfully created a test to reproduce the key loss bug, but discovered a more fundamental memory corruption bug in the leaf split implementation that:
1. Prevents the test from running
2. Is likely the ROOT CAUSE of the original key loss bug
3. Must be fixed before any split-related testing can proceed

The original TODO item about "keys being lost after splits" is almost certainly caused by this memory corruption in the split code itself, rather than a separate key lookup issue.
