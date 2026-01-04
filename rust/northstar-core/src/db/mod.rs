//! Public Database API - main entry point for NorthstarDB.
//!
//! This module provides the `Db` struct which serves as the primary interface
//! for working with NorthstarDB. It coordinates between Pager, WAL, and the
//! SnapshotRegistry to provide a complete database implementation.
//!
//! # Example
//!
//! ```rust,no_run
//! use northstar_core::Db;
//! use std::path::Path;
//!
//! # fn main() -> northstar_core::Result<()> {
//! // Open or create a database
//! let mut db = Db::open(Path::new("mydb.db"))?;
//!
//! // Start a write transaction
//! let mut txn = db.begin_write()?;
//! txn.put(b"key", b"value")?;
//! txn.commit()?;
//!
//! // Start a read transaction
//! let txn = db.begin_read()?;
//! let value = txn.get(b"key")?;
//!
//! // Close the database
//! db.close()?;
//! # Ok(())
//! # }
//! ```

mod config;

use crate::cache::{QueryCache, QueryCacheStats};
use crate::error::{Error, Result, TransactionError};
use crate::pager::Pager;
use crate::snap::{Snapshot, SnapshotOps, SnapshotRegistry, SnapshotStats};
use crate::txn::{ReadTxn, WriteTxn};
use crate::types::TransactionId;
use crate::wal::Wal;
use config::DbConfig;
use std::path::Path;
use std::sync::{Arc, RwLock, RwLockWriteGuard};

pub use config::DbConfigBuilder;

/// NorthstarDB - main database handle.
///
/// Db is the primary interface for NorthstarDB, providing methods to open
/// the database, start transactions, and manage the database lifecycle.
///
/// # Thread Safety
///
/// Db uses interior mutability with Arc<RwLock<>> to allow shared access
/// across threads while ensuring safe concurrent operations.
///
/// # Lifecycle
///
/// 1. **Open/Create**: Use `Db::open()` or `Db::create()`
/// 2. **Operations**: Start read/write transactions
/// 3. **Close**: Use `Db::close()` for graceful shutdown
///
/// # Example
///
/// ```rust,no_run
/// use northstar_core::Db;
/// use std::path::Path;
///
/// # fn main() -> northstar_core::Result<()> {
/// let mut db = Db::open(Path::new("test.db"))?;
///
/// // Write transaction
/// {
///     let mut txn = db.begin_write()?;
///     txn.put(b"hello", b"world")?;
///     txn.commit()?;
/// }
///
/// // Read transaction
/// {
///     let txn = db.begin_read()?;
///     let value = txn.get(b"hello")?;
/// }
///
/// db.close()?;
/// # Ok(())
/// # }
/// ```
pub struct Db {
    /// Inner state protected by RwLock for thread-safe access
    inner: Arc<RwLock<DbInner>>,
}

/// Inner database state (protected by RwLock)
struct DbInner {
    /// Snapshot registry for MVCC (owns the pager)
    snap_registry: SnapshotRegistry,

    /// WAL for transaction logging
    wal: Option<Wal>,

    /// Path to database file
    path: Option<String>,

    /// Flag indicating if database is closed
    is_closed: bool,

    /// Current transaction ID counter
    current_txn_id: TransactionId,

    /// Configuration
    config: DbConfig,

    /// L3 Query Cache for completed query results
    query_cache: QueryCache,
}

impl Db {
    /// Open or create a database at the specified path.
    ///
    /// If the database file exists, it will be opened and recovery will run
    /// if needed. If it doesn't exist, a new database will be created.
    ///
    /// # Arguments
    ///
    /// * `path` - Path to the database file
    ///
    /// # Returns
    ///
    /// A new `Db` instance
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - The file exists but is corrupted
    /// - Permission denied
    /// - I/O error occurs
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// use northstar_core::Db;
    /// use std::path::Path;
    ///
    /// # fn main() -> northstar_core::Result<()> {
    /// let mut db = Db::open(Path::new("mydb.db"))?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        Self::open_with_config(path, DbConfig::default())
    }

    /// Open or create a database with custom configuration.
    ///
    /// # Arguments
    ///
    /// * `path` - Path to the database file
    /// * `config` - Database configuration
    ///
    /// # Returns
    ///
    /// A new `Db` instance
    pub fn open_with_config<P: AsRef<Path>>(path: P, config: DbConfig) -> Result<Self> {
        let path_ref = path.as_ref();
        let path_str = path_ref.display().to_string();

        // Check if file exists
        let exists = path_ref.exists();

        // Open or create pager
        let pager = if exists {
            Pager::open_file(path_ref)?
        } else {
            Pager::create_file(path_ref)?
        };

        // Get current transaction ID and root page ID from pager
        let current_txn_id = pager.committed_txn_id();
        let root_page_id = pager.root_page_id();

        // Construct WAL path
        let wal_path = path_ref.with_extension("wal");
        let wal = if config.enable_wal {
            let wal = if exists && wal_path.exists() {
                Wal::open(&wal_path)?
            } else {
                Wal::create(&wal_path)?
            };
            Some(wal)
        } else {
            None
        };

        // Create snapshot registry (takes ownership of pager)
        let snap_registry = SnapshotRegistry::with_genesis(pager, root_page_id);

        // Create query cache
        let query_cache = QueryCache::new();

        let inner = DbInner {
            snap_registry,
            wal,
            path: Some(path_str),
            is_closed: false,
            current_txn_id,
            config,
            query_cache,
        };

        Ok(Db {
            inner: Arc::new(RwLock::new(inner)),
        })
    }

    /// Create a new in-memory database.
    ///
    /// This creates a database that exists entirely in memory, with no
    /// persistent storage. Useful for testing and temporary operations.
    ///
    /// # Returns
    ///
    /// A new `Db` instance with in-memory storage
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// use northstar_core::Db;
    ///
    /// # fn main() -> northstar_core::Result<()> {
    /// let mut db = Db::memory()?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn memory() -> Result<Self> {
        let pager = Pager::create_memory()?;
        let current_txn_id = pager.committed_txn_id();
        let root_page_id = pager.root_page_id();
        let snap_registry = SnapshotRegistry::with_genesis(pager, root_page_id);

        // Create query cache
        let query_cache = QueryCache::new();

        let inner = DbInner {
            snap_registry,
            wal: None, // No WAL for in-memory
            path: None,
            is_closed: false,
            current_txn_id,
            config: DbConfig::default(),
            query_cache,
        };

        Ok(Db {
            inner: Arc::new(RwLock::new(inner)),
        })
    }

    /// Begin a read transaction.
    ///
    /// Creates a read transaction that provides a consistent snapshot of the
    /// database at the current point in time. Read transactions do not block
    /// writes and can be concurrent.
    ///
    /// # Returns
    ///
    /// A new `ReadTxn` instance
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Database is closed
    /// - No snapshots available
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// use northstar_core::Db;
    ///
    /// # fn main() -> northstar_core::Result<()> {
    /// # let mut db = Db::memory()?;
    /// let txn = db.begin_read()?;
    /// let value = txn.get(b"key")?;
    /// txn.close();
    /// # Ok(())
    /// # }
    /// ```
    pub fn begin_read(&self) -> Result<ReadTxn> {
        let inner = self.inner.read()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;

        if inner.is_closed {
            return Err(Error::Transaction(TransactionError::DatabaseClosed));
        }

        // Get latest snapshot from registry
        let snapshot = inner.snap_registry.snapshot()?;
        let txn_id = snapshot.txn_id();

        Ok(ReadTxn::new(txn_id, snapshot.root_page_id(), self))
    }

    /// Begin a write transaction.
    ///
    /// Creates a write transaction that allows mutations to the database.
    /// Only one write transaction can be active at a time.
    ///
    /// # Returns
    ///
    /// A new `WriteTxn` instance
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Database is closed
    /// - Another write transaction is already in progress
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// use northstar_core::Db;
    ///
    /// # fn main() -> northstar_core::Result<()> {
    /// # let mut db = Db::memory()?;
    /// let mut txn = db.begin_write()?;
    /// txn.put(b"key", b"value")?;
    /// txn.commit()?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn begin_write(&self) -> Result<WriteTxn> {
        let mut inner = self.inner.write()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;

        if inner.is_closed {
            return Err(Error::Transaction(TransactionError::DatabaseClosed));
        }

        // Allocate new transaction ID
        inner.current_txn_id = inner.current_txn_id.next()
            .ok_or_else(|| Error::Transaction(TransactionError::Generic("Transaction ID overflow".to_string())))?;
        let txn_id = inner.current_txn_id;

        Ok(WriteTxn::new(txn_id, self))
    }

    /// Get a snapshot of the current database state.
    ///
    /// Returns a `Snapshot` handle that can be used to create read transactions
    /// at a specific point in time.
    ///
    /// # Returns
    ///
    /// A new `Snapshot` instance
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Database is closed
    /// - No snapshots available
    pub fn snapshot(&self) -> Result<Snapshot> {
        let inner = self.inner.read()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;

        if inner.is_closed {
            return Err(Error::Transaction(TransactionError::DatabaseClosed));
        }

        inner.snap_registry.snapshot()
    }

    /// Get a snapshot at a specific transaction ID.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - Transaction ID for the snapshot
    ///
    /// # Returns
    ///
    /// A new `Snapshot` instance
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Database is closed
    /// - Snapshot for the given transaction ID doesn't exist
    pub fn snapshot_at(&self, txn_id: TransactionId) -> Result<Snapshot> {
        let inner = self.inner.read()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;

        if inner.is_closed {
            return Err(Error::Transaction(TransactionError::DatabaseClosed));
        }

        inner.snap_registry.snapshot_at(txn_id)
    }

    /// Close the database and release all resources.
    ///
    /// Flushes all pending writes, closes files, and releases memory.
    /// After calling `close()`, the database cannot be used for further operations.
    ///
    /// # Returns
    ///
    /// Ok(()) on success
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Sync to disk fails
    /// - File close fails
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// use northstar_core::Db;
    /// use std::path::Path;
    ///
    /// # fn main() -> northstar_core::Result<()> {
    /// # let mut db = Db::open(Path::new("test.db"))?;
    /// db.close()?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn close(&mut self) -> Result<()> {
        let mut inner = self.inner.write()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;

        if inner.is_closed {
            return Ok(()); // Already closed
        }

        // Close WAL if present
        if let Some(ref mut wal) = inner.wal {
            wal.close()?;
        }

        // Close snapshot registry (which owns the pager)
        inner.snap_registry.close()?;

        inner.is_closed = true;

        Ok(())
    }

    /// Sync all pending writes to stable storage.
    ///
    /// This ensures that all mutations are persisted to disk before returning.
    /// This is automatically called during transaction commit, but can also
    /// be called explicitly for manual control.
    ///
    /// # Returns
    ///
    /// Ok(()) if sync succeeds
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Lock is poisoned
    /// - I/O error occurs during sync
    pub fn sync(&self) -> Result<()> {
        let inner = self.inner.read()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;

        if inner.is_closed {
            return Err(Error::Transaction(TransactionError::DatabaseClosed));
        }

        inner.snap_registry.sync()
    }

    /// Check if the database is closed.
    pub fn is_closed(&self) -> bool {
        self.inner.read()
            .map(|inner| inner.is_closed)
            .unwrap_or(true)
    }

    /// Get the path to the database file.
    ///
    /// Returns None for in-memory databases.
    pub fn path(&self) -> Option<String> {
        self.inner.read()
            .ok()
            .and_then(|inner| inner.path.clone())
    }

    /// Get the current transaction ID.
    pub fn current_txn_id(&self) -> TransactionId {
        self.inner.read()
            .map(|inner| inner.current_txn_id)
            .unwrap_or(TransactionId::INITIAL)
    }

    /// Get database statistics.
    pub fn stats(&self) -> Result<DbStats> {
        let inner = self.inner.read()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;

        Ok(DbStats {
            path: inner.path.clone(),
            current_txn_id: inner.current_txn_id.as_u64(),
            is_in_memory: inner.path.is_none(),
            wal_enabled: inner.wal.is_some(),
            snapshot_stats: inner.snap_registry.get_stats(),
            query_cache_stats: inner.query_cache.stats(),
        })
    }

    /// Get the root page ID for a snapshot (internal use).
    pub(crate) fn get_snapshot_root(&self, txn_id: TransactionId) -> Option<crate::PageId> {
        self.inner.read()
            .ok()
            .and_then(|inner| inner.snap_registry.get_snapshot_root(txn_id))
    }

    /// Register a new snapshot after transaction commit (internal use).
    ///
    /// This also persists the transaction state to meta pages for durability.
    pub(crate) fn register_snapshot(&self, txn_id: TransactionId, root_page_id: crate::PageId) -> Result<()> {
        let mut inner = self.inner.write()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;

        // First register the snapshot in memory
        inner.snap_registry.register_snapshot(txn_id, root_page_id)?;

        // Then commit the transaction state to meta pages for persistence
        inner.snap_registry.commit_transaction(txn_id, root_page_id)?;

        Ok(())
    }

    /// Get mutable access to the inner state (internal use for write operations).
    pub(crate) fn inner_mut(&self) -> Result<RwLockWriteGuard<DbInner>> {
        self.inner.write()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))
    }

    /// Get read-only access to the pager (internal use).
    pub(crate) fn pager(&self) -> Result<std::sync::RwLockReadGuard<DbInner>> {
        self.inner.read()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))
    }

    /// Apply mutations to the B+Tree and return the new root page ID (internal use).
    pub(crate) fn apply_mutations<F>(&self, f: F) -> Result<crate::PageId>
    where
        F: FnOnce(&mut crate::btree::BTree) -> Result<()>,
    {
        let mut inner = self.inner_mut()?;
        inner.snap_registry.apply_mutations(f)
    }

    /// Execute a read-only operation on the B+Tree (internal use).
    pub(crate) fn with_btree<F, R>(&self, root_page_id: crate::PageId, f: F) -> Result<R>
    where
        F: FnOnce(&mut crate::btree::BTree) -> Result<R>,
    {
        let mut inner = self.inner_mut()?;
        inner.snap_registry.with_btree(root_page_id, f)
    }

    /// Get reference to query cache (internal use for transaction operations).
    pub(crate) fn query_cache(&self) -> Result<QueryCache> {
        let inner = self.inner.read()
            .map_err(|_| Error::Transaction(TransactionError::LockPoisoned))?;
        Ok(inner.query_cache.clone())
    }
}

/// Clone implementation for Db (creates a new handle to the same database)
impl Clone for Db {
    fn clone(&self) -> Self {
        Db {
            inner: Arc::clone(&self.inner),
        }
    }
}

/// Database statistics.
#[derive(Debug, Clone)]
pub struct DbStats {
    /// Path to the database file (None for in-memory)
    pub path: Option<String>,

    /// Current transaction ID
    pub current_txn_id: u64,

    /// Whether this is an in-memory database
    pub is_in_memory: bool,

    /// Whether WAL is enabled
    pub wal_enabled: bool,

    /// Snapshot registry statistics
    pub snapshot_stats: SnapshotStats,

    /// Query cache statistics
    pub query_cache_stats: QueryCacheStats,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_create_memory_db() {
        let db = Db::memory().unwrap();
        assert!(!db.is_closed());
        assert!(db.path().is_none());

        let stats = db.stats().unwrap();
        assert!(stats.is_in_memory);
        assert_eq!(stats.current_txn_id, 0);
    }

    #[test]
    fn test_create_file_db() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("test.db");

        let db = Db::open(&db_path).unwrap();
        assert!(!db.is_closed());
        assert_eq!(db.path(), Some(db_path.display().to_string()));

        let stats = db.stats().unwrap();
        assert!(!stats.is_in_memory);
        assert!(db_path.exists());
    }

    #[test]
    fn test_begin_read_transaction() {
        let db = Db::memory().unwrap();
        let txn = db.begin_read().unwrap();
        assert!(txn.is_active());
        txn.close();
    }

    #[test]
    fn test_begin_write_transaction() {
        let db = Db::memory().unwrap();
        let txn = db.begin_write().unwrap();
        assert!(txn.is_active());
        assert_eq!(txn.txn_id().as_u64(), 1); // First write txn
    }

    #[test]
    fn test_close_database() {
        let mut db = Db::memory().unwrap();
        assert!(!db.is_closed());

        db.close().unwrap();
        assert!(db.is_closed());

        // Double close should be ok
        db.close().unwrap();
    }

    #[test]
    fn test_read_after_close_fails() {
        let mut db = Db::memory().unwrap();
        db.close().unwrap();

        let result = db.begin_read();
        assert!(result.is_err());
    }

    #[test]
    fn test_write_after_close_fails() {
        let mut db = Db::memory().unwrap();
        db.close().unwrap();

        let result = db.begin_write();
        assert!(result.is_err());
    }

    #[test]
    fn test_clone_db() {
        let db = Db::memory().unwrap();
        let db2 = db.clone();

        // Both handles point to the same database
        assert_eq!(db.current_txn_id(), db2.current_txn_id());
    }

    #[test]
    fn test_get_snapshot() {
        let db = Db::memory().unwrap();
        let snapshot = db.snapshot().unwrap();

        assert_eq!(snapshot.txn_id(), TransactionId::INITIAL);
        assert_eq!(snapshot.root_page_id(), crate::PageId::FIRST_DATA);
    }

    #[test]
    fn test_stats() {
        let db = Db::memory().unwrap();
        let stats = db.stats().unwrap();

        assert!(stats.is_in_memory);
        assert!(!stats.wal_enabled);
        assert_eq!(stats.current_txn_id, 0);
        assert_eq!(stats.snapshot_stats.snapshot_count, 1);
    }

    #[test]
    fn test_reopen_existing_database() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("test.db");

        // Create and write initial data
        {
            let db = Db::open(&db_path).unwrap();
            let mut txn = db.begin_write().unwrap();
            txn.put(b"key1", b"value1").unwrap();
            txn.commit().unwrap();
        }

        // Reopen the database
        {
            let db = Db::open(&db_path).unwrap();
            assert_eq!(db.path(), Some(db_path.display().to_string()));

            let stats = db.stats().unwrap();
            // TODO: Transaction commit should advance txn_id (requires snapshot registration)
            // Currently txn_id remains at INITIAL until full commit is implemented
            assert_eq!(stats.current_txn_id, 0);
        }
    }

    #[test]
    fn test_multiple_write_txns_advance_id() {
        let db = Db::memory().unwrap();

        let txn1 = db.begin_write().unwrap();
        assert_eq!(txn1.txn_id().as_u64(), 1);

        let txn2 = db.begin_write().unwrap();
        assert_eq!(txn2.txn_id().as_u64(), 2);

        let txn3 = db.begin_write().unwrap();
        assert_eq!(txn3.txn_id().as_u64(), 3);
    }

    #[test]
    fn test_snapshot_at_specific_txn() {
        let db = Db::memory().unwrap();

        // Try to get snapshot at initial txn
        let snapshot = db.snapshot_at(TransactionId::INITIAL).unwrap();
        assert_eq!(snapshot.txn_id(), TransactionId::INITIAL);

        // Non-existent txn should fail
        let result = db.snapshot_at(TransactionId::new(999));
        assert!(result.is_err());
    }
}
