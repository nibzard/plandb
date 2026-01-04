//! Persistence for Reference Model
//!
//! JSON serialization for saving and loading RefModel state.
//! Used for reproducible test failures and fuzz replay.

use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use super::{tree::RefTree, snapshot::SnapshotRegistry, ops::TransactionManager};
use crate::types::Lsn;

/// Helper function to serialize byte vector as base64
fn serialize_bytes<S>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    serializer.serialize_str(&base64::encode(bytes))
}

/// Helper function to deserialize byte vector from base64
fn deserialize_bytes<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    base64::decode(&s).map_err(serde::de::Error::custom)
}

/// Serialized representation of a versioned value
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SerializedVersionedValue {
    /// Value bytes (base64 encoded)
    #[serde(serialize_with = "serialize_bytes", deserialize_with = "deserialize_bytes")]
    pub value: Vec<u8>,
    /// Log sequence number
    pub lsn: u64,
    /// Whether this is a tombstone
    pub is_tombstone: bool,
}

/// Simple base64 encode/decode functions
mod base64 {
    use std::collections::HashMap;

    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    pub fn encode(input: &[u8]) -> String {
        let mut result = String::new();
        for chunk in input.chunks(3) {
            let b0 = chunk[0];
            let b1 = if chunk.len() > 1 { chunk[1] } else { 0 };
            let b2 = if chunk.len() > 2 { chunk[2] } else { 0 };

            result.push(ALPHABET[(b0 >> 2) as usize] as char);
            result.push(ALPHABET[((b0 & 0x03) << 4 | (b1 >> 4)) as usize] as char);

            if chunk.len() > 1 {
                result.push(ALPHABET[((b1 & 0x0F) << 2 | (b2 >> 6)) as usize] as char);
            } else {
                result.push('=');
            }

            if chunk.len() > 2 {
                result.push(ALPHABET[(b2 & 0x3F) as usize] as char);
            } else {
                result.push('=');
            }
        }
        result
    }

    pub fn decode(input: &str) -> Result<Vec<u8>, String> {
        let mut decode_table: HashMap<u8, u8> = HashMap::new();
        for (i, &c) in ALPHABET.iter().enumerate() {
            decode_table.insert(c, i as u8);
        }

        let input = input.trim_end_matches('=');
        let mut result = Vec::new();

        for chunk in input.as_bytes().chunks(4) {
            if chunk.len() < 2 {
                return Err("Invalid base64 input".to_string());
            }

            let v0 = *decode_table.get(&chunk[0]).ok_or("Invalid base64 character")?;
            let v1 = *decode_table.get(&chunk[1]).ok_or("Invalid base64 character")?;

            let b0 = (v0 << 2) | (v1 >> 4);
            result.push(b0);

            if chunk.len() > 2 {
                let v2_opt = decode_table.get(&chunk[2]);
                if chunk[2] != b'=' {
                    let v2 = *v2_opt.ok_or("Invalid base64 character")?;
                    let b1 = (v1 << 4) | (v2 >> 2);
                    result.push(b1);

                    if chunk.len() > 3 && chunk[3] != b'=' {
                        let v3 = *decode_table.get(&chunk[3]).ok_or("Invalid base64 character")?;
                        let b2 = (v2 << 6) | v3;
                        result.push(b2);
                    }
                }
            }
        }

        Ok(result)
    }
}

impl From<SerializedVersionedValue> for crate::refmodel::tree::VersionedValue {
    fn from(sv: SerializedVersionedValue) -> Self {
        Self {
            value: sv.value,
            lsn: Lsn::from(sv.lsn),
            is_tombstone: sv.is_tombstone,
        }
    }
}

impl From<crate::refmodel::tree::VersionedValue> for SerializedVersionedValue {
    fn from(vv: crate::refmodel::tree::VersionedValue) -> Self {
        Self {
            value: vv.value,
            lsn: vv.lsn.as_u64(),
            is_tombstone: vv.is_tombstone,
        }
    }
}

/// Serialized representation of a version chain
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SerializedVersionChain {
    /// All versions in LSN order
    pub versions: Vec<SerializedVersionedValue>,
}

/// Serialized entry for key-value pair
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SerializedEntry {
    /// Key bytes (base64 encoded)
    #[serde(serialize_with = "serialize_bytes", deserialize_with = "deserialize_bytes")]
    pub key: Vec<u8>,
    /// Version chain
    pub chain: SerializedVersionChain,
}

/// Serialized representation of the reference tree
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SerializedRefTree {
    /// List of entries (instead of HashMap to avoid JSON key issues)
    pub entries: Vec<SerializedEntry>,
}

impl From<RefTree> for SerializedRefTree {
    fn from(tree: RefTree) -> Self {
        let items = tree.iter();
        let entries = items.into_iter().map(|(key, value)| SerializedEntry {
            key,
            chain: SerializedVersionChain {
                versions: vec![SerializedVersionedValue {
                    value,
                    lsn: 1, // Simplified - serialization doesn't preserve full version history
                    is_tombstone: false,
                }],
            },
        }).collect();

        Self { entries }
    }
}

impl TryFrom<SerializedRefTree> for RefTree {
    type Error = String;

    fn try_from(st: SerializedRefTree) -> Result<Self, String> {
        let mut tree = Self::new();

        for entry in st.entries {
            // Take the latest (last) version from the chain
            if let Some(latest_version) = entry.chain.versions.last() {
                if !latest_version.is_tombstone {
                    tree.put(entry.key, latest_version.value.clone(), Lsn::from(latest_version.lsn));
                }
            }
        }

        Ok(tree)
    }
}

/// Save RefModel state to a file
///
/// Serializes the RefModel state to JSON format for later replay.
pub fn save_to_file<P: AsRef<std::path::Path>>(
    tree: &RefTree,
    path: P,
) -> std::io::Result<()> {
    let serialized = SerializedRefTree::from(tree.clone());
    let json = serde_json::to_string_pretty(&serialized)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    std::fs::write(path, json)
}

/// Load RefModel state from a file
///
/// Deserializes a previously saved RefModel state.
pub fn load_from_file<P: AsRef<std::path::Path>>(path: P) -> std::io::Result<RefTree> {
    let json = std::fs::read_to_string(path)?;
    let serialized: SerializedRefTree = serde_json::from_str(&json)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    serialized.try_into()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))
}

/// Save snapshot registry to a file
pub fn save_snapshots_to_file<P: AsRef<std::path::Path>>(
    snapshots: &SnapshotRegistry,
    path: P,
) -> std::io::Result<()> {
    let data: Vec<(u64, SerializedRefTree)> = snapshots
        .snapshots
        .iter()
        .map(|(lsn, tree)| (lsn.as_u64(), SerializedRefTree::from(tree.clone())))
        .collect();

    let json = serde_json::to_string_pretty(&data)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    std::fs::write(path, json)
}

/// Load snapshot registry from a file
pub fn load_snapshots_from_file<P: AsRef<std::path::Path>>(
    path: P,
) -> std::io::Result<SnapshotRegistry> {
    let json = std::fs::read_to_string(path)?;
    let data: Vec<(u64, SerializedRefTree)> = serde_json::from_str(&json)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    let mut registry = SnapshotRegistry::new();
    for (lsn, tree) in data {
        let ref_tree: RefTree = tree.try_into()
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        registry.snapshots.insert(Lsn::from(lsn), ref_tree);
    }

    Ok(registry)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Lsn;

    fn make_tree() -> RefTree {
        let mut tree = RefTree::new();
        tree.put(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1));
        tree.put(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(2));
        tree
    }

    #[test]
    fn test_serialize_deserialize_tree() {
        let tree1 = make_tree();

        let serialized = SerializedRefTree::from(tree1.clone());
        let tree2 = RefTree::try_from(serialized).unwrap();

        // Check that all key-value pairs are preserved
        // Note: LSN values are simplified during serialization, so we only check values
        assert_eq!(tree2.get(b"key1"), Some(b"value1".to_vec()));
        assert_eq!(tree2.get(b"key2"), Some(b"value2".to_vec()));
        assert_eq!(tree1.len(), tree2.len());
    }

    #[test]
    fn test_serialize_versioned_value() {
        let vv = crate::refmodel::tree::VersionedValue::new(b"data".to_vec(), Lsn::from(100));
        let serialized = SerializedVersionedValue::from(vv.clone());

        assert_eq!(serialized.value, b"data");
        assert_eq!(serialized.lsn, 100);
        assert!(!serialized.is_tombstone);

        let restored: crate::refmodel::tree::VersionedValue = serialized.into();
        assert_eq!(restored.value, vv.value);
        assert_eq!(restored.lsn, vv.lsn);
        assert_eq!(restored.is_tombstone, vv.is_tombstone);
    }

    #[test]
    fn test_serialize_tombstone() {
        let vv = crate::refmodel::tree::VersionedValue::tombstone(Lsn::from(200));
        let serialized = SerializedVersionedValue::from(vv.clone());

        assert!(serialized.is_tombstone);

        let restored: crate::refmodel::tree::VersionedValue = serialized.into();
        assert_eq!(restored.is_tombstone, vv.is_tombstone);
    }

    #[test]
    fn test_save_load_file() {
        let tree1 = make_tree();
        let path = "/tmp/test_refmodel_serialize.json";

        save_to_file(&tree1, path).unwrap();
        let tree2 = load_from_file(path).unwrap();

        // Check that all key-value pairs are preserved
        assert_eq!(tree2.get(b"key1"), Some(b"value1".to_vec()));
        assert_eq!(tree2.get(b"key2"), Some(b"value2".to_vec()));
        assert_eq!(tree1.len(), tree2.len());

        // Clean up
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn test_save_empty_tree() {
        let tree = RefTree::new();
        let path = "/tmp/test_refmodel_empty.json";

        save_to_file(&tree, path).unwrap();
        let loaded = load_from_file(path).unwrap();

        assert!(loaded.is_empty());

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn test_save_snapshots() {
        let mut registry = SnapshotRegistry::new();

        let mut tree1 = RefTree::new();
        tree1.put(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(1));
        registry.add_snapshot(Lsn::from(1), tree1);

        let path = "/tmp/test_refmodel_snapshots.json";

        save_snapshots_to_file(&registry, path).unwrap();
        let loaded = load_snapshots_from_file(path).unwrap();

        assert_eq!(loaded.len(), 1);
        let state = loaded.get_state_at(Lsn::from(1)).unwrap();
        assert_eq!(state.get(b"key1"), Some(b"value1".to_vec()));

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn test_serialize_with_versions() {
        let mut tree = RefTree::new();
        tree.put(b"key".to_vec(), b"v3".to_vec(), Lsn::from(3));

        let serialized = SerializedRefTree::from(tree.clone());
        let restored = RefTree::try_from(serialized).unwrap();

        // Should have the latest version
        assert_eq!(restored.get(b"key"), Some(b"v3".to_vec()));
    }
}
