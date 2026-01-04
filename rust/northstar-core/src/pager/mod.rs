//! Pager module - page-based storage management.
//!
//! The Pager is the fundamental storage abstraction layer in NorthstarDB,
//! responsible for managing page-based I/O, page allocation, caching, and
//! file handle management.

mod allocator;
mod cache;
mod meta;
mod pager;
mod storage;

// Re-export main types
pub use pager::Pager;

// Re-export storage types
pub use storage::{FileStorage, MemoryStorage, Storage};

// Re-export meta types
pub use meta::{choose_best_meta, MetaPayload, MetaState, META_MAGIC, META_PAYLOAD_SIZE};

// Re-export cache types
pub use cache::{CacheStats, PageCache};

// Re-export allocator types
pub use allocator::PageAllocator;
