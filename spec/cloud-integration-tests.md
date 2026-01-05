# Cloud Adapter Integration Tests Specification

**Phase**: Cloud Integration Testing
**Status**: Specification
**Last Updated**: 2026-01-05
**Author**: Claude Code

## Overview

This specification defines comprehensive integration tests for the cloud adapter implementations (AWS S3, Google Cloud Storage, Azure Blob Storage) added in Phase 16. These tests ensure production-ready cloud backup and restore functionality.

## Goals

1. **Validate cloud adapter correctness** - Ensure backup/restore operations work correctly
2. **Test error handling** - Verify retry logic, timeouts, and failure scenarios
3. **Measure performance** - Benchmark upload/download speeds for large files
4. **Ensure data integrity** - Validate checksums and encryption/decryption
5. **Test encryption at rest** - Verify AES-256-GCM encryption works correctly

## Test Scope

### Test Categories

#### 1. Basic Operations Tests
- Single file upload/download
- Directory upload/download
- File existence checks
- File deletion
- List operations

#### 2. Error Handling Tests
- Invalid credentials
- Network timeouts
- Non-existent files
- Permission denied
- Retry logic verification
- Exponential backoff behavior

#### 3. Data Integrity Tests
- Checksum validation (SHA-256)
- Encryption/decryption round-trip
- Multipart upload integrity
- Concurrent upload/download

#### 4. Performance Tests
- Upload speed for various file sizes (1MB, 10MB, 100MB, 1GB)
- Download speed benchmarks
- Multipart upload performance (5MB, 50MB, 500MB files)
- Concurrent operation throughput

#### 5. Encryption Tests
- AES-256-GCM encryption/decryption
- Key derivation from master key
- Authentication tag validation
- Tamper detection (modified ciphertext)

## Test Infrastructure

### Mock Servers

For CI/CD and local development, use mock servers:

1. **S3 Mock**: MinIO or LocalStack
2. **GCS Mock**: fake-gcs-server
3. **Azure Mock**: Azurite

### Test Data

Generate test databases of various sizes:
- Small: 1MB (1000 keys)
- Medium: 10MB (10K keys)
- Large: 100MB (100K keys)
- XLarge: 1GB (1M keys)

### Test Configuration

```toml
[cloud_test]
test_bucket = "northstar-test-12345"
region = "us-east-1"
endpoint = "http://localhost:9000"  # For mock servers

[encryption]
master_key = "test-master-key-32-bytes-long-key!!"
```

## Test Cases

### TC1: Single File Upload/Download (AWS S3)

**Purpose**: Verify basic S3 upload/download functionality

**Steps**:
1. Create 10MB test database file
2. Upload to S3 test bucket
3. Verify file exists in bucket
4. Download to local temporary file
5. Compare checksums (original vs downloaded)
6. Delete from S3

**Expected Results**:
- Upload succeeds
- File exists check returns true
- Downloaded file matches original (SHA-256)
- Delete succeeds
- File exists check returns false after delete

**Success Criteria**: All steps pass within 30 seconds

### TC2: Multipart Upload (AWS S3)

**Purpose**: Verify multipart upload for large files

**Steps**:
1. Create 500MB test database file
2. Upload using multipart (5MB chunks)
3. Track upload progress and timing
4. Download complete file
5. Compare checksums
6. Verify multipart upload completed atomically

**Expected Results**:
- Upload succeeds with progress reporting
- Atomic operation (no partial files on failure)
- Downloaded file matches original
- Upload time < 60 seconds on 100Mbps connection

**Success Criteria**: Multipart upload completes with data integrity

### TC3: Encryption/Decryption (All Providers)

**Purpose**: Verify AES-256-GCM encryption at rest

**Steps**:
1. Create test database with known content
2. Encrypt with master key
3. Upload encrypted file
4. Download encrypted file
5. Decrypt with master key
6. Verify content matches original
7. Attempt decryption with wrong key (should fail)
8. Modify ciphertext and attempt decrypt (should fail)

**Expected Results**:
- Encryption succeeds
- Decrypted content matches original
- Wrong key fails with authentication error
- Modified ciphertext fails with tamper detection
- Encryption overhead < 5% file size increase

**Success Criteria**: Encryption protects data and detects tampering

### TC4: Retry Logic (All Providers)

**Purpose**: Verify exponential backoff retry behavior

**Steps**:
1. Configure mock server to fail first 2 requests
2. Initiate upload operation
4. Verify retry attempts with exponential backoff
5. Verify request succeeds on 3rd attempt
6. Measure total time with retries

**Expected Results**:
- First attempt fails (simulated)
- Second attempt fails with longer delay
- Third attempt succeeds
- Backoff pattern: ~100ms, ~200ms, ~400ms (exponential)
- Total time < 5 seconds

**Success Criteria**: Retry logic handles transient failures gracefully

### TC5: Concurrent Uploads (All Providers)

**Purpose**: Verify thread-safe concurrent operations

**Steps**:
1. Create 10 test files (10MB each)
2. Upload concurrently using 5 threads
3. Verify all uploads succeed
4. Download all files concurrently
5. Verify all downloads match originals
6. Verify no data corruption or race conditions

**Expected Results**:
- All uploads succeed
- All downloads match originals
- No deadlocks or race conditions
- Concurrent operations faster than sequential

**Success Criteria**: Concurrent operations work correctly and improve throughput

### TC6: Network Timeout Handling (All Providers)

**Purpose**: Verify timeout and error handling

**Steps**:
1. Configure short timeout (5 seconds)
2. Create slow mock server (10s response time)
3. Attempt upload
4. Verify timeout error
5. Configure longer timeout (30 seconds)
6. Retry upload
7. Verify success

**Expected Results**:
- First attempt times out with clear error
- Retry with longer timeout succeeds
- Error messages are informative
- No resource leaks

**Success Criteria**: Timeouts are handled gracefully with clear errors

### TC7: Cross-Provider Integrity (GCS, Azure)

**Purpose**: Verify non-AWS providers work correctly

**Steps**:
1. Repeat TC1-TC4 for Google Cloud Storage
2. Repeat TC1-TC4 for Azure Blob Storage
3. Compare performance across providers
4. Verify encryption works identically across providers

**Expected Results**:
- All operations work identically across providers
- Encryption/decryption provider-agnostic
- Performance within 2x of AWS S3
- All checksums match

**Success Criteria**: GCS and Azure work as well as S3

### TC8: Disaster Recovery (All Providers)

**Purpose**: Verify backup/restore for disaster recovery

**Steps**:
1. Create production database with 1M records
2. Create cloud backup
3. Simulate disaster (delete local database)
4. Restore from cloud backup
5. Verify all records present
6. Verify database is consistent (snapshots, WAL)
7. Measure recovery time

**Expected Results**:
- Backup completes successfully
- All records restored
- Database is consistent and queryable
- Recovery time < 5 minutes for 1GB database
- No data loss

**Success Criteria**: Disaster recovery works end-to-end

## Performance Benchmarks

### Baseline Targets (100Mbps connection)

| Operation | File Size | Target Time |
|-----------|-----------|-------------|
| Upload | 10MB | < 5s |
| Upload | 100MB | < 30s |
| Upload | 1GB | < 5min |
| Download | 10MB | < 5s |
| Download | 100MB | < 30s |
| Download | 1GB | < 5min |
| Multipart Upload | 500MB | < 60s |
| Encrypt | 100MB | < 2s |
| Decrypt | 100MB | < 2s |

### Regression Detection

- Upload throughput: ±10% from baseline
- Download throughput: ±10% from baseline
- Encryption overhead: < 5% file size
- Retry success rate: > 95%

## Test Implementation

### File Structure

```
rust/northstar-test/src/integration/
├── cloud_aws.rs        # AWS S3 tests
├── cloud_gcs.rs        # Google Cloud Storage tests
├── cloud_azure.rs      # Azure Blob Storage tests
├── cloud_common.rs     # Shared test utilities
└── cloud_mod.rs        # Test module exports
```

### Test Utilities

```rust
// cloud_common.rs
pub struct CloudTestHarness {
    pub provider: CloudProvider,
    pub config: CloudConfig,
    pub test_data: Vec<TestFile>,
}

impl CloudTestHarness {
    pub async fn setup(provider: CloudProvider) -> Self;
    pub async fn create_test_db(size_mb: usize) -> PathBuf;
    pub async fn verify_checksum(file1: &Path, file2: &Path) -> bool;
    pub async fn measure_time<F, T>(f: F) -> (T, Duration)
    where
        F: Future<Output = T>;
    pub async fn cleanup(&self);
}

pub struct MockServer {
    pub s3: Option<MinIOContainer>,
    pub gcs: Option<FakeGCSServer>,
    pub azure: Option<AzuriteContainer>,
}
```

## Continuous Integration

### GitHub Actions Workflow

```yaml
name: Cloud Integration Tests

on: [push, pull_request]

jobs:
  cloud-tests:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        provider: [aws, gcs, azure]
    services:
      minio:
        image: minio/minio
        ports:
          - 9000:9000
        env:
          MINIO_ROOT_USER: testkey
          MINIO_ROOT_PASSWORD: testsecret
    steps:
      - uses: actions/checkout@v3
      - name: Run cloud tests
        run: |
          cargo test --package northstar-test \
            --test cloud_${{ matrix.provider }}
        env:
          AWS_ACCESS_KEY_ID: testkey
          AWS_SECRET_ACCESS_KEY: testsecret
          AWS_ENDPOINT: http://localhost:9000
```

## Success Criteria

### All Tests Must Pass
- ✅ Basic operations: 8/8 tests passing
- ✅ Error handling: 6/6 tests passing
- ✅ Data integrity: 5/5 tests passing
- ✅ Performance: All benchmarks within target
- ✅ Encryption: 4/4 tests passing

### Code Coverage
- Cloud adapters: > 90% coverage
- Error paths: > 80% coverage
- Retry logic: 100% coverage

### Documentation
- All test cases documented
- Performance baselines recorded
- CI/CD pipeline operational

## Deliverables

1. ✅ This specification document
2. ⏳ Test implementation (cloud_aws.rs, cloud_gcs.rs, cloud_azure.rs)
3. ⏳ Mock server setup scripts
4. ⏳ CI/CD workflow configuration
5. ⏳ Performance benchmark baselines
6. ⏳ Test results documentation

## Timeline

- Day 1: Specification (this document)
- Day 1-2: Test utilities and infrastructure
- Day 2-3: AWS S3 tests (TC1-TC8)
- Day 3-4: GCS and Azure tests
- Day 4-5: Performance benchmarks and CI/CD setup
- Day 5: Documentation and final verification

## References

- Phase 16 commits: 70c1a25, 921bcf6, 5fc9ec8, 9aa9395, 561146b, 7422551
- Cloud adapter implementations: `rust/northstar-core/src/cloud/`
- Encryption implementation: `rust/northstar-core/src/cloud/encrypt.rs`
- Retry logic: `rust/northstar-core/src/cloud/retry.rs`
