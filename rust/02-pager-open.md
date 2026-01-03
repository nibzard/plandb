# Pager Open Operation

## Purpose

The Pager open operation is responsible for opening an existing database file, validating its integrity, recovering from crashes, and initializing the Pager state for use. This operation handles meta page validation (choosing the valid copy from dual meta pages), free list rebuilding, page cache initialization, and storage backend setup. The open process must handle various error conditions gracefully, including corrupted files, version mismatches, and I/O failures.

## File Opening Sequence

### Step 1: Path Parsing and Special Case Handling

**Parse Path**: Examine the provided path string to detect special cases

**Special Case Detection**:
- Check if path equals the magic string ":memory:" (case-sensitive)
- If memory database requested, delegate to create operation instead
- Memory databases are always created fresh (no persistence)

**Behavior for :memory:**:
- Return result equivalent to create() operation
- Initialize empty in-memory storage
- No file I/O is performed
- Database is temporary and lost when Pager is closed

**Rationale**: Matches SQLite behavior for in-memory databases, provides convenient testing mode

### Step 2: Open File Handle

**Open File**: Open the database file with read-write access

**File Open Parameters**:
- Path from parameter
- Mode: Read and write access required
- Create: Do not create if does not exist (only open existing)
- Share mode: Platform-dependent (typically allow sharing)

**Error Conditions**:
- File does not exist: Return file not found error
- Permission denied: Return permission error
- Directory instead of file: Return inappropriate file type error
- Already open by exclusive process: Return sharing violation

**Success**: File handle is valid and positioned at start of file

**Temporary Handle**: This initial file handle is used only for reading meta pages
- Will be closed after meta pages are read
- Permanent file handle opened later after validation succeeds

### Step 3: Read First Page

**Read Operation**: Read the first page (page 0, META_A_PAGE_ID) from the file

**Buffer Allocation**: Allocate buffer exactly one page size (16384 bytes for V0)

**Read Parameters**:
- Offset: 0 (start of file)
- Length: Exactly one page size
- Destination: Buffer for page contents

**Validation: File Size Check**
- Check if bytes read equals page size
- If fewer bytes read, file is too small to contain even one page
- Return "file too small" error

**Rationale**: Database file must contain at least one complete page to be valid

### Step 4: Decode Meta Page A

**Parse Meta Page A**: Attempt to decode page 0 as a meta page

**Decoding Process**:
- Parse PageHeader from first 40 bytes
- Validate magic number equals PAGE_MAGIC
- Validate format version is supported
- Validate page type equals meta
- Validate header checksum
- Parse MetaPayload from bytes after PageHeader
- Validate meta magic number equals META_MAGIC
- Validate meta checksum
- Validate page ID in header equals META_A_PAGE_ID (0)

**Error Handling**:
- Treat validation failures as "corrupt meta page A" (soft error)
- Specifically handle: InvalidMagic, InvalidHeaderChecksum, InvalidMetaChecksum, InvalidPageType, UnexpectedPageId
- Other errors (I/O errors, allocation failures) are hard errors (return immediately)
- If meta page A is corrupt, set meta_a to null (not an error yet)

**Success**: meta_a contains valid MetaState if page is valid

### Step 5: Read Second Page

**Read Operation**: Read the second page (page 1, META_B_PAGE_ID) from the file

**Buffer Allocation**: Allocate buffer exactly one page size

**Read Parameters**:
- Offset: Page size (16384 bytes for V0)
- Length: Exactly one page size
- Destination: Buffer for page contents

**Validation: File Size Check**
- Check if bytes read equals page size
- If fewer bytes read, file ends before second meta page
- This is acceptable (second meta page may not exist)
- Set meta_b to null in this case

**Rationale**: Very new databases might only have one meta page written

### Step 6: Decode Meta Page B

**Parse Meta Page B**: Attempt to decode page 1 as a meta page

**Decoding Process**: Same as meta page A decoding
- Validate PageHeader (magic, version, type, checksum, page_id)
- Validate MetaPayload (magic, checksum)
- Page ID must equal META_B_PAGE_ID (1)

**Error Handling**:
- Treat validation failures as "corrupt meta page B" (soft error)
- Same specific error handling as meta page A
- Other errors are hard errors
- If page does not exist or is corrupt, set meta_b to null

**Success**: meta_b contains valid MetaState if page is valid

### Step 7: Get File Size

**Query File Size**: Get total size of database file in bytes

**Purpose**: Used for torn write detection and validation

**Operation**: Query file end position (seek to end, tell position)

**Validation**: File size must be reasonable
- Must be at least page size (already validated)
- Used for torn write detection heuristics

### Step 8: Choose Best Meta Page

**Meta Selection**: Choose the valid meta page with highest committed transaction ID

**Selection Algorithm**:
- If both meta_a and meta_b are null: Return corrupt error (no valid meta)
- If only meta_a is valid: Use meta_a
- If only meta_b is valid: Use meta_b
- If both are valid: Choose the one with higher committed_txn_id

**Torn Write Detection**: For each candidate meta page
- Check file size (skip torn write detection for very small test files)
- Validate page size matches expected size
- Check transaction ID is reasonable (not impossibly large)
- Check root page ID is within file bounds
- Check freelist head page ID is reasonable
- A page failing these checks is considered torn write

**Torn Write Rollback**: If chosen meta page shows signs of torn write
- Fall back to the other meta page if it is valid
- If both show torn writes, return corrupt error

**Success**: best_meta contains the chosen MetaState

**Error Condition**: If no valid meta page exists after all checks, return corrupt database error

### Step 9: Validate Page Size

**Page Size Check**: Ensure the page size in meta matches supported page size

**Validation**: Compare meta page page_size field with expected page size

**Expected Value**: 16384 bytes for V0 format (DEFAULT_PAGE_SIZE)

**Error Condition**: If page size does not match, return unsupported page size error

**Rationale**: Different page sizes are incompatible formats. Pager only supports one page size (V0 is 16KB)

### Step 10: Reopen File Handle

**Permanent File Open**: Open file again for long-term use by Pager

**Why Reopen**: First file handle was closed after reading meta pages (defer close in Zig)

**File Open Parameters**: Same as Step 2
- Path from parameter
- Mode: Read and write access
- File kept open for Pager lifetime

**Success**: Valid file handle ready for read and write operations

### Step 11: Construct Pager Instance

**Initialize Struct**: Create Pager struct with all fields

**Field Initialization**:
- storage: Set to file variant with permanent file handle
- page_size: Set from meta page (should be DEFAULT_PAGE_SIZE)
- current_meta: Set to chosen best_meta from Step 8
- allocator: Set from parameter
- page_allocator: Set to null (initialized in next step)
- cache: Set to null (initialized in next step)

**Invariants**: All fields are valid and consistent at this point

### Step 12: Initialize Page Allocator

**Create Allocator**: Initialize PageAllocator with Pager reference

**Initialization Process**:
- Create PageAllocator instance
- Pass reference to Pager (for I/O operations)
- Pass memory allocator from Pager
- Trigger free list rebuild by scanning B+tree

**Free List Rebuild**:
- Scan all allocated pages in the database
- Determine which pages are in use by B+tree
- Mark pages not in use as free
- Sort free list for efficient allocation
- Store in page_allocator.free_pages

**Success**: page_allocator field points to initialized PageAllocator

### Step 13: Initialize Page Cache

**Create Cache**: Initialize PageCache for buffering pages

**Allocation**: Allocate PageCache instance on heap

**Cache Configuration**:
- Capacity: 1024 entries (configurable)
- Memory limit: 16 megabytes (configurable)
- Eviction policy: LRU (least recently used)

**Initialization**: Set up empty cache data structures

**Success**: cache field points to initialized PageCache

### Step 14: Return Pager

**Complete**: Return fully initialized Pager instance to caller

**State**: Pager is ready for use
- Meta page is cached in current_meta
- Free list is rebuilt and available
- Page cache is ready to buffer I/O
- File handle is open for read/write operations

## Validation Checks

### File Existence and Accessibility

**Check**: File must exist at specified path

**Validation**:
- File open operation succeeds
- Path refers to a regular file (not directory)
- File has read permission
- File has write permission

**Failure**: Return appropriate file system error

### File Size Validation

**Check**: File must contain at least one complete page

**Validation**:
- File size is greater than or equal to page size
- First page can be read completely

**Failure**: Return "file too small" error

### Magic Number Validation

**Check**: Page headers must contain correct magic number

**Validation**:
- First 4 bytes of page equal PAGE_MAGIC (0x4E534442)
- Spells "NSDB" in ASCII

**Failure**: Treat page as corrupt, try other meta page if available

### Format Version Validation

**Check**: Page format version must be supported

**Validation**:
- Format version field equals 0 for V0 format
- Other versions indicate incompatible format

**Failure**: Return unsupported format error

### Page Type Validation

**Check**: Page type must be meta for meta pages

**Validation**:
- Page type field in header equals 0 (meta type)
- Other page types in meta page location indicate corruption

**Failure**: Treat page as corrupt, try other meta page if available

### Checksum Validation

**Check**: Page header and payload checksums must be valid

**Validation**:
- Header checksum recalculated and matches stored value
- Payload checksum recalculated and matches stored value
- Both checksums use CRC32C algorithm

**Failure**: Treat page as corrupt, try other meta page if available

### Page ID Validation

**Check**: Page ID in header must match expected page ID

**Validation**:
- Meta page A (page 0) has page_id field equal to 0
- Meta page B (page 1) has page_id field equal to 1
- Mismatch indicates wrong page in wrong location

**Failure**: Treat page as corrupt, try other meta page if available

### Meta Magic Validation

**Check**: Meta payload must contain correct meta magic number

**Validation**:
- First 4 bytes of MetaPayload equal META_MAGIC (0x4D455441)
- Spells "META" in ASCII

**Failure**: Treat page as corrupt, try other meta page if available

### Torn Write Detection

**Check**: Meta page must show signs of consistent completion

**Validations**:
- Transaction ID is reasonable (not impossibly large like 1 trillion)
- Root page ID is within file bounds
- Freelist head page ID is within reasonable range
- Page size matches expected value
- Internal consistency checks pass

**Failure**: Consider page torn, try other meta page if available

### Page Size Compatibility

**Check**: Page size from meta must match supported page size

**Validation**:
- Page size field equals DEFAULT_PAGE_SIZE (16384)
- Only V0 page size supported currently

**Failure**: Return unsupported page size error

## Error Conditions

### File System Errors

**File Not Found**: Database file does not exist at specified path
- **Cause**: File was deleted, never created, or wrong path
- **Error**: File not found error from OS
- **Recovery**: User must create database first or correct path

**Permission Denied**: Insufficient permissions to access file
- **Cause**: Read or write permission not granted
- **Error**: Permission denied error from OS
- **Recovery**: User must fix file permissions

**Inappropriate File Type**: Path refers to directory or special file
- **Cause**: Path is a directory, symbolic link, or device file
- **Error**: Inappropriate file type error from OS
- **Recovery**: User must provide correct file path

**File Too Small**: Database file is smaller than one page
- **Cause**: File was truncated or is not a valid database
- **Error**: Specific "file too small" error
- **Recovery**: Database is corrupt, cannot recover

**Sharing Violation**: File is locked exclusively by another process
- **Cause**: Another process has exclusive access
- **Error**: Platform-specific sharing violation error
- **Recovery**: Close other process or open in shared mode

### Corruption Errors

**Corrupt Database**: Both meta pages are invalid or corrupt
- **Cause**: Disk corruption, software bug, or incomplete write
- **Detection**: Both meta pages fail validation or show torn writes
- **Error**: Specific "corrupt database" error
- **Recovery**: Database is unrecoverable, user must restore from backup

**Invalid Magic Number**: Page header magic number is wrong
- **Cause**: File is not a NorthstarDB database or is corrupted
- **Detection**: First 4 bytes don't match PAGE_MAGIC
- **Error**: Invalid magic error
- **Recovery**: Try other meta page if available; if both fail, database is corrupt

**Invalid Header Checksum**: Page header checksum doesn't match
- **Cause**: Page header was corrupted after write
- **Detection**: Recalculated checksum differs from stored value
- **Error**: Invalid header checksum error
- **Recovery**: Try other meta page if available; if both fail, database is corrupt

**Invalid Payload Checksum**: Page payload checksum doesn't match
- **Cause**: Page payload was corrupted after write
- **Detection**: Recalculated checksum differs from stored value
- **Error**: Invalid payload checksum error
- **Recovery**: Try other meta page if available; if both fail, database is corrupt

**Unexpected Page Type**: Meta page location contains wrong page type
- **Cause**: File corruption or wrong page in wrong location
- **Detection**: Page type is not meta (0)
- **Error**: Invalid page type error
- **Recovery**: Try other meta page if available; if both fail, database is corrupt

### Version Errors

**Unsupported Format Version**: Page format version is not supported
- **Cause**: Database file created by newer or incompatible version
- **Detection**: Format version field is not 0
- **Error**: Unsupported format error
- **Recovery**: User must upgrade database software or use correct version

**Unsupported Page Size**: Page size in meta is not supported
- **Cause**: Database created with different page size than V0 default
- **Detection**: Page size field is not 16384
- **Error**: Unsupported page size error
- **Recovery**: Database is incompatible, cannot be opened

### Torn Write Detection

**Torn Write Detected**: Meta page shows signs of incomplete write
- **Cause**: System crashed during meta page write
- **Detection**: Transaction ID impossibly large, fields out of range
- **Error**: Handled by trying other meta page
- **Recovery**: Use the other meta page if it is valid; if both are torn, database is corrupt

## Function Signature

### Parameters

**path**: Reference to path string or bytes
- **Type**: String slice or byte slice
- **Purpose**: Specifies database file location or ":memory:" for in-memory database
- **Constraints**: Must be valid file path or ":memory:" magic string
- **Ownership**: Borrowed from caller (not copied)

**allocator**: Memory allocator for internal allocations
- **Type**: Memory allocator (Allocator in Zig, lifetime/bounds in Rust)
- **Purpose**: Used for allocating internal data structures (free list, cache, buffers)
- **Constraints**: Must be valid and usable for Pager lifetime
- **Ownership**: Borrowed reference

### Return Type

**Success**: Returns initialized Pager instance
- **Type**: Result<Pager, Error> in Rust
- **Value**: Fully initialized Pager ready for use
- **State**: All fields valid, meta page cached, allocator and cache initialized

**Error**: Returns appropriate error type
- **Type**: Error enum variant
- **Value**: Specific error indicating what went wrong
- **Categories**:
  - File system errors (not found, permission denied)
  - Corruption errors (invalid magic, checksums, torn writes)
  - Version errors (unsupported format or page size)

### Method Signature (Prose)

The open function is typically a static method or associated function on the Pager type. It takes a path reference and an allocator reference as parameters. It returns a result type containing either the initialized Pager or an error. The function does not take self as a parameter (it constructs new Pager instances).

## Rust Implementation Guidance

### Function Definition

**Static Method**: Define as associated function on Pager

**Signature Pattern**:
- Takes &str or &[u8] for path
- Takes allocator parameter (either lifetime parameter or generic bound)
- Returns Result<Pager, Error>

**Naming**: Use conventional Rust naming (open not Open)

### Error Type Definition

**Pager Error Enum**: Define comprehensive error types

**Error Categories**:
- File system errors (NotFound, PermissionDenied, InappropriateFileType)
- Size errors (FileTooSmall)
- Corruption errors (Corrupt, InvalidMagic, InvalidChecksum)
- Version errors (UnsupportedFormat, UnsupportedPageSize)

**Implementation**: Use thiserror crate for clean error definitions

### Path Handling

**String Type**: Use std::path::PathBuf or AsRef<Path>

**Special Case Detection**: Check for ":memory:" string

**File Opening**: Use std::fs::OpenOptions with read().write() (no create())

### Buffer Management

**Fixed Size Buffers**: Use arrays of exact page size
- Let mut buffer: [u8; PAGE_SIZE] = [0; PAGE_SIZE]

**Heap Allocation**: Use boxed slices if needed for large buffers
- Let mut buffer = vec![0u8; PAGE_SIZE];

### Meta Page Parsing

**Helper Functions**: Extract into separate module or functions
- parse_meta_page(buffer: &[u8], page_id: u64) -> Result<MetaState, Error>
- validate_meta_page(state: &MetaState, file_size: u64) -> bool

**Error Conversion**: Convert parsing errors to appropriate Pager errors

### Dual Meta Page Handling

**Pattern**: Read both meta pages independently, then choose

**Storage**: Store both as Option<MetaState>

**Selection Logic**: Implement choose_best_meta function
- Prefer page with higher committed_txn_id
- Implement torn write detection
- Fallback logic if chosen page is torn

### Allocator Integration

**Generic Allocator**: Use allocator parameter for PageAllocator and PageCache

**Lifetime**: Allocator must live as long as Pager
- Use lifetime parameter: Pager<'a>
- Or use owned allocator with Arc

### Cache Initialization

**Default Configuration**: Provide sensible defaults
- Cache size: 1024 entries
- Memory limit: 16MB

**Customization**: Allow caller to configure via options if needed

### Resource Cleanup

**RAII Pattern**: Ensure proper cleanup on error paths
- Use Drop trait or explicit close method
- Defer file close if initialization fails after file open

**Error Path Cleanup**: If initialization fails partway through
- Close file handle if opened
- Deallocate any allocated memory
- Release resources in reverse order of acquisition