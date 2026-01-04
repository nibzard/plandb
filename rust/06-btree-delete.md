# B+Tree Delete Operation

## Purpose

The delete operation removes keys from the B+Tree while maintaining structural integrity and occupancy invariants. Deletion is more complex than insertion because removing entries can cause nodes to become underfull, triggering merge or borrow operations to rebalance the tree. This specification covers delete algorithms for both leaf and internal nodes, underflow detection and handling, tombstone management for MVCC, cascade operations for maintaining tree balance, and comprehensive error handling strategies.

## Types

### DeleteResult

**Description**: Result type returned by delete operations indicating outcome

**Fields**:
- **status**: DeleteStatus - Whether key was found, deleted, or not found
- **key_deleted**: bool - True if key was present and removed
- **node_underflow**: bool - True if delete caused node to become underfull
- **merged_page_id**: Option<PageId> - Page ID of node merged into neighbor (if merge occurred)
- **borrowed_from**: Option<PageId> - Page ID of sibling borrowed from (if borrow occurred)
- **entries_remaining**: u16 - Number of entries remaining in node after delete

**Rationale**: Encapsulates delete outcome and indicates whether rebalancing (merge/borrow) is needed

### DeleteStatus

**Description**: Enumeration of possible delete operation outcomes

**Values**:
- **Deleted**: Key found and removed successfully
- **NotFound**: Key not present in tree (no-op)
- **AlreadyDeleted**: Key marked as deleted (tombstone exists)
- **Underflow**: Key deleted but node now underfull (needs merge/borrow)
- **Merged**: Key deleted and node merged with sibling
- **Borrowed**: Key deleted and node borrowed from sibling

**Rationale**: Different outcomes require different follow-up actions

### DeleteContext

**Description**: Context structure tracking state during delete operation

**Fields**:
- **key**: Vec<u8> - Key being deleted
- **target_page_id**: PageId - Page ID containing the key (leaf node)
- **parent_page_id**: PageId - Parent node that may need separator update
- **path**: Vec<PageId> - Traversal path from root to leaf (for merge/borrow propagation)
- **level**: u16 - Tree level of delete operation (0 for leaf deletes)
- **has_tombstone**: bool - True if key has tombstone marker (MVCC delete)

**Rationale**: Captures traversal state for potential merge/borrow cascade

### TombstoneRecord

**Description**: MVCC tombstone marker for deleted keys

**Fields**:
- **key**: Vec<u8> - Deleted key
- **delete_lsn**: Lsn - LSN when delete occurred
- **deleting_txn_id**: TransactionId - Transaction performing delete
- **previous_version_lsn**: Option<Lsn> - LSN of previous value (for undelete)
- **is_visible**: bool - Whether tombstone is visible to current snapshot

**Rationale**: MVCC requires tracking deletes for historical snapshots

## Algorithms

### Leaf Node Delete (Simple Case)

**Purpose**: Remove key from leaf node without triggering underflow

**Context**: Key found in leaf node, deletion leaves node with sufficient entries (>= MIN_OCCUPANCY)

**Algorithm**:

1. **Input**: Leaf node with entries array, target key to delete
2. **Locate Entry**:
   - Execute binary search in leaf.entries for target key
   - If key not found: return DeleteResult with status NotFound (no-op)
   - If key found: record entry_index
3. **Check for Existing Tombstone**:
   - If entries[entry_index].value is tombstone:
     - Return DeleteResult with status AlreadyDeleted
     - No modification needed
4. **Create Tombstone Record**:
   - Create TombstoneRecord:
     - key = target_key
     - delete_lsn = allocate new LSN from WAL
     - deleting_txn_id = current transaction ID
     - previous_version_lsn = entries[entry_index].lsn
     - is_visible = true
5. **Replace Entry with Tombstone**:
   - Set entries[entry_index].value = tombstone marker
   - Set entries[entry_index].lsn = tombstone.delete_lsn
   - Set entries[entry_index].txn_id = tombstone.deleting_txn_id
   - Mark entry as deleted (set deletion flag)
6. **Update Node Metadata**:
   - Decrement leaf.header.num_keys (optional: some designs keep count with tombstones)
   - Recalculate leaf.header.free_space (tombstone uses less space than value)
   - Set leaf.header.dirty flag
   - Increment leaf.header.generation counter
7. **Check Underflow**:
   - Calculate active_entry_count (excluding tombstones)
   - If active_entry_count < MINIMUM_OCCUPANCY:
     - Set node_underflow = true
   - Else:
     - Set node_underflow = false
8. **Recalculate Checksum**:
   - leaf.header.checksum = calculate_checksum(leaf)
9. **Write Node**:
   - Write leaf node to Pager
   - Sync page to disk (if immediate durability required)
10. **Construct DeleteResult**:
    - Return DeleteResult with:
      - status = Deleted
      - key_deleted = true
      - node_underflow = calculated_underflow_flag
      - merged_page_id = None
      - borrowed_from = None
      - entries_remaining = active_entry_count

**Time Complexity**:
- Binary search: O(log n) where n is entries in leaf
- Entry removal: O(1) with tombstone
- Total: O(log n)

**Space Complexity**: O(1) (tombstone marker is small)

**Returns**: DeleteResult indicating outcome

**Error Conditions**:
- **KeyNotFound**: Binary search completes without finding key
- **IOError**: Pager write operation fails
- **CorruptNode**: Node header validation fails (checksum, magic)
- **LsnAllocationFailed**: WAL cannot allocate new LSN

**Concurrency**: Exclusive access required (blocks all operations on this leaf)

**Edge Cases**:
- **Delete with existing tombstone**: Key already deleted, return AlreadyDeleted
- **Delete from underfull node**: Node becomes underfull, triggers merge/borrow
- **Delete last entry**: Node becomes empty, may trigger tree shrink
- **Delete with overflow pages**: Deallocate overflow pages referenced by deleted value

### Leaf Node Delete with Underflow Detection

**Purpose**: Detect when leaf node becomes underfull after delete

**Context**: Delete operation completed, need to determine if merge or borrow is required

**Algorithm**:

1. **Input**: Leaf node after delete operation
2. **Count Active Entries**:
   - active_count = 0
   - For each entry in leaf.entries:
     - If entry.value is not tombstone:
       - active_count += 1
3. **Check Minimum Occupancy**:
   - min_occupancy = calculate_min_occupancy(leaf.capacity)
   - If active_count < min_occupancy:
     - Return UnderflowDetected
   - Else:
     - Return NodeValid
4. **Check Root Exception**:
   - If leaf.is_root == true:
     - Root can have 0-1 entries (exception to occupancy rule)
     - Return NodeValid regardless of active_count
5. **Check Merge Eligibility**:
   - If UnderflowDetected:
     - Read leaf.left_sibling (if exists)
     - Read leaf.right_sibling (if exists)
     - Check if sibling has space to accommodate merge
     - Return MergeCandidates(left_sibling_id, right_sibling_id)
6. **Return**: UnderflowStatus

**Time Complexity**: O(n) where n is total entries in leaf (must scan for tombstones)

**Space Complexity**: O(1)

**Returns**: UnderflowStatus indicating if merge/borrow needed

**Error Conditions**:
- **InvalidSibling**: Sibling page ID is invalid
- **CorruptSibling**: Sibling node validation fails

**Concurrency**: Shared read access to siblings

### Internal Node Delete

**Purpose**: Remove separator from internal node after child merge/borrow

**Context**: Child node merged or borrowed, requiring parent separator update

**Algorithm**:

1. **Input**: Internal node with separators array, separator to delete
2. **Locate Separator**:
   - Execute binary search in internal.separators for target separator
   - separator_index = search result
3. **Delete Separator**:
   - Remove separators[separator_index] from array
   - Shift separators[separator_index+1..] left by one position
4. **Delete Corresponding Child Pointer**:
   - Remove child_pointers[separator_index+1] from array
   - Shift child_pointers[separator_index+2..] left by one position
   - Note: Delete child pointer to right of separator (not left)
5. **Update Node Metadata**:
   - internal.header.num_keys -= 1
   - Recalculate internal.header.free_space
   - Set internal.header.dirty flag
   - Increment internal.header.generation counter
6. **Check Underflow**:
   - If internal.header.num_keys < MINIMUM_OCCUPANCY:
     - Set node_underflow = true
     - May trigger merge/borrow at this level
7. **Recalculate Checksum**:
   - internal.header.checksum = calculate_checksum(internal)
8. **Write Node**:
   - Write internal node to Pager
9. **Return**: DeleteResult with status Deleted and underflow flag

**Time Complexity**:
- Binary search: O(log n) where n is separators in internal node
- Array shift: O(n) for shifting separators and child pointers
- Total: O(n)

**Space Complexity**: O(1)

**Returns**: DeleteResult

**Error Conditions**:
- **SeparatorNotFound**: Separator not present in internal node
- **IOError**: Pager write operation fails
- **CorruptNode**: Node header validation fails

**Concurrency**: Exclusive access required

**Edge Cases**:
- **Delete last separator**: Internal node becomes empty, may trigger tree shrink
- **Delete from root internal**: Root with 1 separator becomes leaf (tree height decreases)
- **Cascade delete**: Delete at this level triggers underflow, propagates upward

### Tombstone Management

**Purpose**: Manage MVCC tombstones for deleted keys

**Context**: Deletes create tombstones for historical snapshot visibility

**Algorithm - Create Tombstone**:

1. **Input**: Key being deleted, current LSN, current transaction ID
2. **Allocate LSN**:
   - delete_lsn = wal.allocate_lsn()
3. **Create Tombstone Record**:
   - tombstone = TombstoneRecord {
       key: target_key,
       delete_lsn: allocated_lsn,
       deleting_txn_id: current_txn_id,
       previous_version_lsn: entry.lsn,
       is_visible: true
     }
4. **Write Tombstone to WAL**:
   - wal.append_delete_record(tombstone)
   - Sync WAL (if durability required)
5. **Replace Entry**:
   - entry.value = TOMBSTONE_MARKER
   - entry.lsn = delete_lsn
   - entry.txn_id = deleting_txn_id
   - entry.is_tombstone = true
6. **Return**: tombstone

**Algorithm - Check Tombstone Visibility**:

1. **Input**: Tombstone record, snapshot LSN
2. **Compare LSNs**:
   - If tombstone.delete_lsn > snapshot_lsn:
     - Return NotVisible (delete occurred after snapshot)
   - Else:
     - Return Visible (delete visible to snapshot)
3. **Check Transaction State**:
   - If tombstone.deleting_txn_id == snapshot_txn_id:
     - Return NotVisible (delete in same transaction, key not yet deleted)
4. **Return**: Visibility status

**Algorithm - Reclaim Old Tombstones**:

1. **Input**: Leaf node with tombstone entries, oldest active snapshot LSN
2. **Identify Reclaimable Tombstones**:
   - reclaimable = []
   - For each entry in leaf.entries:
     - If entry.is_tombstone && entry.lsn < oldest_snapshot_lsn:
       - reclaimable.push(entry_index)
3. **Remove Reclaimable Tombstones**:
   - For each index in reclaimable (in descending order):
     - Remove entries[index] from array
     - Shift subsequent entries left
4. **Update Metadata**:
   - leaf.header.num_keys -= reclaimable.len()
   - Recalculate leaf.header.free_space
   - Mark node as dirty
5. **Write Node**:
   - Write leaf node to Pager
6. **Return**: Number of tombstones reclaimed

**Time Complexity**: O(n) where n is entries in leaf

**Space Complexity**: O(1)

**Returns**: Number of tombstones reclaimed

**Rationale**: Old tombstones waste space and slow down scans. Reclaim when no active snapshots need them.

### Delete Operation Flow

**Purpose**: Orchestrate complete delete operation from root to leaf

**Context**: High-level delete algorithm handling search, delete, underflow detection

**Algorithm**:

1. **Input**: Key to delete, tree root page ID, Pager reference
2. **Search for Key**:
   - Execute search algorithm from root
   - Traverse from root to leaf containing key
   - Record traversal path (path_stack = [root, ..., parent, leaf])
   - leaf_page_id = destination node
3. **Read Leaf Node**:
   - leaf = pager.read_page(leaf_page_id)
   - Validate leaf (checksum, magic)
4. **Locate Entry**:
   - Execute binary search in leaf.entries for key
   - If key not found:
     - Return DeleteResult with status NotFound
5. **Delete Entry**:
   - Execute leaf node delete algorithm
   - Create tombstone for MVCC
   - Remove or mark entry as deleted
6. **Check Underflow**:
   - Execute underflow detection algorithm
   - If underflow_detected == false:
     - Write leaf, return DeleteResult (done)
   - Else (underflow detected):
     - Proceed to merge or borrow logic
7. **Attempt Borrow**:
   - Check left sibling for available entries
   - Check right sibling for available entries
   - If either sibling has excess entries:
     - Execute borrow operation (see 06-btree-borrow.md)
     - Return DeleteResult with status Borrowed
8. **Attempt Merge**:
   - If borrow not possible (both siblings at minimum occupancy)
   - Execute merge operation (see 06-btree-merge.md)
   - Merge node with sibling
   - Delete separator from parent
   - Propagate upward if parent becomes underfull
9. **Handle Tree Shrink**:
   - If root has only 1 child after deletes:
     - Make child the new root
     - Decrease tree height
     - Update database metadata
10. **Return**: Final DeleteResult

**Time Complexity**:
- Search: O(log n) where n is total keys in tree
- Delete: O(1) with tombstone
- Borrow: O(n) where n is entries in sibling
- Merge: O(n) where n is entries in merged node
- Cascade: O(h * n) where h is tree height, n is node size
- Total: O(log n) average, O(h * n) worst case (cascade merge)

**Space Complexity**: O(h) for traversal path stack

**Returns**: DeleteResult

**Error Conditions**:
- **KeyNotFound**: Key not present in tree
- **IOError**: Pager operation fails
- **CorruptNode**: Node validation fails
- **MergeFailed**: Merge operation fails (recovery needed)
- **BorrowFailed**: Borrow operation fails

**Concurrency**: Exclusive access required (blocks entire tree during cascade operations)

## Error Handling

### Key Not Found

**KeyNotFound**:
- **Detection**: Binary search completes without finding key
- **Handling**:
  - Return DeleteResult with status NotFound
  - No modification to tree structure
  - No error returned (delete is idempotent)
- **Recovery**: No recovery needed (tree unchanged)
- **User Action**: Key may have been deleted already or never existed

### I/O Errors

**ReadFailure**:
- **Detection**: Pager.read_page() fails during delete traversal
- **Handling**:
  - Abort delete operation
  - Return error to caller
  - No rollback needed (no modifications made yet)
- **Recovery**: Retry operation or abort transaction
- **User Action**: Check disk health, retry delete

**WriteFailure**:
- **Detection**: Pager.write_page() fails after tombstone creation
- **Handling**:
  - Abort delete operation
  - Mark node as corrupted (tombstone created but not written)
  - Return error to caller
- **Recovery**:
  - Recovery process checks WAL for tombstone record
  - If WAL has tombstone but page doesn't: replay tombstone
  - If page has tombstone but WAL doesn't: rollback tombstone
- **User Action**: Run database recovery

### Structural Errors

**NodeCorruption**:
- **Detection**: Node checksum validation fails during traversal
- **Handling**:
  - Abort delete operation
  - Mark tree as corrupted
  - Return fatal error
- **Recovery**: Run database repair from WAL/checkpoint
- **User Action**: Initiate database recovery

**UnderflowCascadeFailure**:
- **Detection**: Merge/borrow operation fails during cascade
- **Handling**:
  - Abort cascade operation
  - Tree may have inconsistent state (node underfull)
  - Mark tree as needing repair
  - Return error
- **Recovery**:
  - Repair process rebuilds tree structure
  - Fixes underfull nodes via merge/borrow
- **User Action**: Run database verification and repair

**EmptyRootError**:
- **Detection**: Root node becomes empty after deletes (should have at least 1 entry unless tree empty)
- **Handling**:
  - If tree is truly empty (no keys), valid state
  - If tree has keys but root empty: structural corruption
  - Return error or create new root
- **Recovery**: Rebuild tree from leaf nodes

### MVCC Errors

**TombstoneCreationFailed**:
- **Detection**: WAL cannot allocate LSN or write tombstone record
- **Handling**:
  - Abort delete operation
  - No tombstone created, no entry deleted
  - Return error to caller
- **Recovery**: No recovery needed (tree unchanged)

**SnapshotConflict**:
- **Detection**: Delete conflicts with active snapshot (e.g., deleting key being read by snapshot)
- **Handling**:
  - V0 design: Allow delete, create tombstone (MVCC handles visibility)
  - Alternative: Block delete until snapshot releases (not in V0)
- **Recovery**: MVCC ensures snapshot sees old value, new transactions see tombstone

## Invariants

### Delete Invariants

1. **Key Ordering**: Key ordering maintained after delete (no gaps in ordering)
2. **Entry Count**: leaf.num_keys reflects total entries (including tombstones)
3. **Active Entry Count**: Active entries (non-tombstones) >= MINIMUM_OCCUPANCY (except root)
4. **Tombstone LSN**: Tombstone LSN > previous value LSN
5. **Delete Transaction ID**: Tombstone txn_id recorded for MVCC visibility

### Underflow Invariants

1. **Detection**: Underflow detected when active entries < MINIMUM_OCCUPANCY
2. **Root Exception**: Root can have 0-1 entries (never underflow by this rule)
3. **Merge Trigger**: Underflow triggers merge if both siblings at minimum
4. **Borrow Trigger**: Underflow triggers borrow if sibling has excess entries
5. **Cascade**: Parent separator delete may trigger parent underflow

### Tombstone Invariants

1. **Uniqueness**: One tombstone per key per delete
2. **LSN Ordering**: Tombstone LSN monotonic (later deletes have higher LSNs)
3. **Visibility**: Tombstone visible to snapshots with LSN >= delete_lsn
4. **Reclamation**: Tombstones reclaimable when LSN < oldest_active_snapshot_lsn
5. **Version Chain**: Tombstone points to previous value LSN (for undo/visibility)

### Cascade Delete Invariants

1. **Path Tracking**: Traversal path recorded for merge/borrow propagation
2. **Separator Delete**: Parent separator deleted when children merge
3. **Parent Underflow**: Parent may become underfull after separator delete
4. **Termination**: Cascade terminates at root (root can have 1 separator)
5. **Tree Height**: Tree height decreases only when root has 1 child

## Rust Implementation Guidance

### Module Structure

The delete functionality should be organized as:
- `northstar_core::tree::delete::delete_leaf_entry` - Leaf entry deletion with tombstones
- `northstar_core::tree::delete::delete_internal_separator` - Internal separator deletion
- `northstar_core::tree::delete::detect_underflow` - Underflow detection after delete
- `northstar_core::tree::delete::create_tombstone` - Tombstone creation and WAL logging
- `northstar_core::tree::delete::check_tombstone_visibility` - MVCC visibility check
- `northstar_core::tree::delete::reclaim_tombstones` - Old tombstone cleanup
- `northstar_core::tree::delete::execute_delete` - High-level delete orchestration

### Type Definitions

**DeleteResult**: Implement as struct with DeleteStatus enum:
```rust
#[derive(Debug, Clone, PartialEq)]
pub enum DeleteStatus {
    Deleted,
    NotFound,
    AlreadyDeleted,
    Underflow,
    Merged { merged_page_id: PageId },
    Borrowed { borrowed_from: PageId },
}

pub struct DeleteResult {
    pub status: DeleteStatus,
    pub key_deleted: bool,
    pub node_underflow: bool,
    pub merged_page_id: Option<PageId>,
    pub borrowed_from: Option<PageId>,
    pub entries_remaining: u16,
}
```

**DeleteContext**: Implement as struct:
```rust
pub struct DeleteContext {
    pub key: Vec<u8>,
    pub target_page_id: PageId,
    pub parent_page_id: PageId,
    pub path: Vec<PageId>,
    pub level: u16,
    pub has_tombstone: bool,
}
```

**TombstoneRecord**: Implement as struct:
```rust
pub struct TombstoneRecord {
    pub key: Vec<u8>,
    pub delete_lsn: Lsn,
    pub deleting_txn_id: TransactionId,
    pub previous_version_lsn: Option<Lsn>,
    pub is_visible: bool,
}

pub const TOMBSTONE_MARKER: &[u8] = &[0xFF, 0xFF, 0xFF, 0xFF]; // Special marker
```

### Leaf Delete Implementation

Delete entry from leaf with tombstone:
```rust
pub fn delete_leaf_entry(
    leaf: &mut LeafNode,
    key: &[u8],
    wal: &mut Wal,
    current_txn_id: TransactionId,
) -> Result<DeleteResult, DeleteError> {
    // Binary search for key
    let entry_index = leaf.entries.binary_search_by_key(key, |e| &e.key);

    let entry_index = match entry_index {
        Ok(idx) => idx,
        Err(_) => {
            return Ok(DeleteResult {
                status: DeleteStatus::NotFound,
                key_deleted: false,
                node_underflow: false,
                merged_page_id: None,
                borrowed_from: None,
                entries_remaining: leaf.header.num_keys,
            });
        }
    };

    // Check for existing tombstone
    if leaf.entries[entry_index].is_tombstone {
        return Ok(DeleteResult {
            status: DeleteStatus::AlreadyDeleted,
            key_deleted: false,
            node_underflow: false,
            merged_page_id: None,
            borrowed_from: None,
            entries_remaining: count_active_entries(&leaf.entries),
        });
    }

    // Create tombstone
    let tombstone = create_tombstone(
        &leaf.entries[entry_index],
        wal,
        current_txn_id,
    )?;

    // Replace entry with tombstone
    leaf.entries[entry_index].value = TOMBSTONE_MARKER.to_vec();
    leaf.entries[entry_index].lsn = tombstone.delete_lsn;
    leaf.entries[entry_index].txn_id = tombstone.deleting_txn_id;
    leaf.entries[entry_index].is_tombstone = true;

    // Update metadata
    leaf.header.free_space = calculate_free_space(leaf);
    leaf.header.set_flag(NodeFlags::DIRTY);
    leaf.header.generation += 1;
    leaf.header.checksum = calculate_checksum(leaf);

    // Check underflow
    let active_count = count_active_entries(&leaf.entries);
    let node_underflow = active_count < MINIMUM_OCCUPANCY && !leaf.header.is_root;

    Ok(DeleteResult {
        status: DeleteStatus::Deleted,
        key_deleted: true,
        node_underflow,
        merged_page_id: None,
        borrowed_from: None,
        entries_remaining: active_count,
    })
}
```

### Tombstone Creation

Create tombstone and write to WAL:
```rust
pub fn create_tombstone(
    entry: &LeafEntry,
    wal: &mut Wal,
    current_txn_id: TransactionId,
) -> Result<TombstoneRecord, DeleteError> {
    // Allocate LSN for tombstone
    let delete_lsn = wal.allocate_lsn()?;

    // Create tombstone record
    let tombstone = TombstoneRecord {
        key: entry.key.clone(),
        delete_lsn,
        deleting_txn_id: current_txn_id,
        previous_version_lsn: Some(entry.lsn),
        is_visible: true,
    };

    // Write tombstone to WAL
    wal.append_delete_record(&tombstone)?;

    Ok(tombstone)
}

pub fn check_tombstone_visibility(
    tombstone: &TombstoneRecord,
    snapshot_lsn: Lsn,
    snapshot_txn_id: TransactionId,
) -> bool {
    // Delete occurred after snapshot
    if tombstone.delete_lsn > snapshot_lsn {
        return false;
    }

    // Delete in same transaction (not yet committed)
    if tombstone.deleting_txn_id == snapshot_txn_id {
        return false;
    }

    true
}
```

### Tombstone Reclamation

Reclaim old tombstones:
```rust
pub fn reclaim_tombstones(
    leaf: &mut LeafNode,
    oldest_snapshot_lsn: Lsn,
    pager: &mut Pager,
) -> Result<usize, DeleteError> {
    let mut reclaimable = Vec::new();

    // Identify reclaimable tombstones
    for (i, entry) in leaf.entries.iter().enumerate() {
        if entry.is_tombstone && entry.lsn < oldest_snapshot_lsn {
            reclaimable.push(i);
        }
    }

    // Remove tombstones (in descending order to maintain indices)
    for &index in reclaimable.iter().rev() {
        leaf.entries.remove(index);
    }

    // Update metadata
    leaf.header.num_keys -= reclaimable.len() as u16;
    leaf.header.free_space = calculate_free_space(leaf);
    leaf.header.set_flag(NodeFlags::DIRTY);
    leaf.header.generation += 1;
    leaf.header.checksum = calculate_checksum(leaf);

    // Write node
    pager.write_page(leaf.header.node_id, leaf)?;

    Ok(reclaimable.len())
}
```

### Internal Node Delete

Delete separator from internal node:
```rust
pub fn delete_internal_separator(
    internal: &mut InternalNode,
    separator: &[u8],
) -> Result<DeleteResult, DeleteError> {
    // Binary search for separator
    let sep_index = internal.separators.binary_search_by_key(separator, |s| s);

    let sep_index = match sep_index {
        Ok(idx) => idx,
        Err(_) => {
            return Err(DeleteError::SeparatorNotFound);
        }
    };

    // Remove separator
    internal.separators.remove(sep_index);

    // Remove child pointer to right of separator
    internal.children.remove(sep_index + 1);

    // Update metadata
    internal.header.num_keys -= 1;
    internal.header.free_space = calculate_free_space(internal);
    internal.header.set_flag(NodeFlags::DIRTY);
    internal.header.generation += 1;
    internal.header.checksum = calculate_checksum(internal);

    // Check underflow
    let node_underflow = internal.header.num_keys < MINIMUM_OCCUPANCY
        && !internal.header.is_root;

    Ok(DeleteResult {
        status: DeleteStatus::Deleted,
        key_deleted: true,
        node_underflow,
        merged_page_id: None,
        borrowed_from: None,
        entries_remaining: internal.header.num_keys,
    })
}
```

### High-Level Delete Orchestration

Execute complete delete operation:
```rust
pub fn execute_delete(
    root_page_id: PageId,
    key: &[u8],
    pager: &mut Pager,
    wal: &mut Wal,
    current_txn_id: TransactionId,
) -> Result<DeleteResult, DeleteError> {
    // Search for key (record path)
    let (leaf_page_id, path) = search_with_path(root_page_id, key, pager)?;

    // Read leaf
    let mut leaf = pager.read_page::<LeafNode>(leaf_page_id)?;

    // Delete entry
    let delete_result = delete_leaf_entry(&mut leaf, key, wal, current_txn_id)?;

    // Write leaf
    pager.write_page(leaf_page_id, &leaf)?;

    // Check underflow
    if delete_result.node_underflow {
        // Attempt borrow (see 06-btree-borrow.md)
        if let Ok(borrow_result) = attempt_borrow(&mut leaf, &path, pager) {
            return Ok(borrow_result);
        }

        // Attempt merge (see 06-btree-merge.md)
        if let Ok(merge_result) = attempt_merge(&mut leaf, &path, pager) {
            return Ok(merge_result);
        }
    }

    Ok(delete_result)
}
```

### Key Decisions

**Tombstone vs Physical Delete**: Use tombstones for MVCC support. Physical delete would break snapshot isolation. Alternative: Physical delete + version chain in separate storage (more complex).

**Tombstone Reclamation**: Reclaim tombstones when LSN < oldest_active_snapshot_lsn. Alternative: Keep all tombstones until vacuum operation (simpler but wastes space).

**Underflow Handling**: Prefer borrow over merge (borrow moves fewer entries). Alternative: Always merge (simpler but causes more operations).

**Root Exception**: Root can have 0-1 entries (special case). Alternative: Enforce minimum occupancy on root (complicates logic).

**Delete Idempotency**: Delete of non-existent key returns NotFound, not error. Alternative: Return error (less user-friendly).

**Cascade Strategy**: Propagate merges/borrows upward immediately. Alternative: Deferred rebalancing (mark nodes underfull, fix later). Immediate propagation maintains invariants but has worst-case O(h * n) cost.

### Implementation Notes

1. **Tombstone Marker**: Use special value marker (e.g., 0xFFFFFFFF):
   ```rust
   pub const TOMBSTONE_MARKER: &[u8] = &[0xFF, 0xFF, 0xFF, 0xFF];
   ```

2. **Active Entry Count**: Count non-tombstone entries:
   ```rust
   fn count_active_entries(entries: &[LeafEntry]) -> u16 {
       entries.iter()
           .filter(|e| !e.is_tombstone)
           .count() as u16
   }
   ```

3. **Binary Search**: Use standard library binary search:
   ```rust
   let index = entries.binary_search_by_key(key, |e| &e.key)?;
   ```

4. **Underflow Detection**: Check active count vs minimum:
   ```rust
   let is_underfull = count_active_entries(&entries) < MIN_OCCUPANCY;
   ```

5. **Path Tracking**: Record traversal for cascade operations:
   ```rust
   let mut path = Vec::new();
   path.push(root_page_id);
   // ... during traversal ...
   path.push(child_page_id);
   ```

6. **Error Handling**: Use question mark operator:
   ```rust
   let tombstone = create_tombstone(entry, wal, txn_id)?;
   ```

7. **Validation**: Assert invariants after delete:
   ```rust
   assert!(count_active_entries(&leaf.entries) >= MIN_OCCUPANCY || leaf.is_root);
   ```

8. **Testing**: Test delete with various scenarios:
   ```rust
   // Delete existing key
   // Delete non-existent key
   // Delete with existing tombstone
   // Delete causing underflow
   // Delete from root
   ```

### Testing Strategy

**Unit tests needed for**:
- Leaf delete (key found, key not found, existing tombstone)
- Leaf delete causing underflow
- Internal separator delete
- Tombstone creation and WAL logging
- Tombstone visibility check (various LSN combinations)
- Tombstone reclamation (old, recent)
- Underflow detection (various occupancy levels)
- Active entry count calculation

**Property tests for**:
- Delete maintains key ordering
- Delete preserves total entry count (with tombstones)
- Tombstone LSN > previous value LSN
- Underflow detected correctly for all occupancy levels
- Tombstone visibility respects LSN ordering
- Reclamation only removes old tombstones

**Integration scenarios**:
- Delete 1K keys, verify tree valid
- Delete causing merge (trigger rebalancing)
- Delete causing borrow (trigger redistribution)
- Delete with concurrent readers (MVCC correctness)
- Delete, crash during delete, recover, verify consistency
- Delete all keys from tree, verify empty tree valid
- Delete with overflow page references (verify deallocation)

**Fuzzing targets**:
- Delete with non-existent keys
- Delete with malformed keys
- Rapid deletes (stress test reclamation)
- Delete during concurrent operations
- Delete with I/O errors injected
- Delete causing cascade failures

**Performance benchmarks**:
- Leaf delete cost (time per delete)
- Internal separator delete cost
- Tombstone creation overhead
- Underflow detection cost
- Cascade delete cost (multiple levels)
- Delete impact on read latency

## Related Specifications

- **06-btree-overview.md**: High-level B+Tree design and delete overview
- **06-btree-node.md**: Internal and leaf node structures for delete targets
- **06-btree-header.md**: Node header fields updated during delete
- **06-btree-search.md**: Search algorithm for finding keys to delete
- **06-btree-merge.md**: Merge operation for underflow nodes
- **06-btree-borrow.md**: Borrow operation for underflow nodes
- **06-btree-key.md**: Key encoding and comparison for search
- **02-pager-*.md**: Pager integration for node I/O
- **03-wal-*.md**: WAL integration for tombstone logging
- **04-txn-*.md**: Transaction system integration for MVCC
- **05-mvcc-*.md**: MVCC snapshot management for tombstone visibility
