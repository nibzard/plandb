//! Equivalence Checking
//!
//! Tools for comparing reference model state with production database state.

use super::tree::RefTree;
use std::collections::HashMap;

/// Result of comparing two states
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ComparisonResult {
    /// States are equivalent
    Equivalent,
    /// States differ
    Different { differences: Vec<Difference> },
}

/// Difference between two states
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Difference {
    /// The key that differs
    pub key: Vec<u8>,
    /// The type of difference
    pub diff_type: DiffType,
}

/// Type of difference
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffType {
    /// Key only exists in left (reference) state
    OnlyInLeft { value: Vec<u8> },
    /// Key only exists in right (production) state
    OnlyInRight { value: Vec<u8> },
    /// Key exists in both but values differ
    ValueMismatch { left: Vec<u8>, right: Vec<u8> },
}

impl ComparisonResult {
    /// Check if the comparison result indicates equivalence
    pub fn is_equivalent(&self) -> bool {
        matches!(self, ComparisonResult::Equivalent)
    }

    /// Get the list of differences if any
    pub fn differences(&self) -> &[Difference] {
        match self {
            ComparisonResult::Equivalent => &[],
            ComparisonResult::Different { differences } => differences,
        }
    }
}

/// Compare two reference trees for equivalence
///
/// Returns `ComparisonResult::Equivalent` if both trees contain the same
/// key-value pairs, otherwise returns a list of differences.
pub fn compare_trees(left: &RefTree, right: &RefTree) -> ComparisonResult {
    let left_items: HashMap<Vec<u8>, Vec<u8>> = left
        .iter()
        .into_iter()
        .collect();

    let right_items: HashMap<Vec<u8>, Vec<u8>> = right
        .iter()
        .into_iter()
        .collect();

    let mut differences = Vec::new();

    // Check keys only in left
    for (key, left_value) in &left_items {
        if let Some(right_value) = right_items.get(key) {
            if left_value != right_value {
                differences.push(Difference {
                    key: key.clone(),
                    diff_type: DiffType::ValueMismatch {
                        left: left_value.clone(),
                        right: right_value.clone(),
                    },
                });
            }
        } else {
            differences.push(Difference {
                key: key.clone(),
                diff_type: DiffType::OnlyInLeft {
                    value: left_value.clone(),
                },
            });
        }
    }

    // Check keys only in right
    for (key, right_value) in &right_items {
        if !left_items.contains_key(key) {
            differences.push(Difference {
                key: key.clone(),
                diff_type: DiffType::OnlyInRight {
                    value: right_value.clone(),
                },
            });
        }
    }

    if differences.is_empty() {
        ComparisonResult::Equivalent
    } else {
        ComparisonResult::Different { differences }
    }
}

/// Compute a digest of the reference tree state
///
/// Returns a hash that uniquely identifies the tree state.
pub fn compute_digest(tree: &RefTree) -> u64 {
    tree.compute_hash()
}

/// Check if two trees have the same digest
///
/// Faster than full comparison but may have collisions (extremely unlikely).
pub fn same_digest(left: &RefTree, right: &RefTree) -> bool {
    compute_digest(left) == compute_digest(right)
}

/// Generate a human-readable diff report
pub fn generate_diff_report(result: &ComparisonResult) -> String {
    match result {
        ComparisonResult::Equivalent => "States are equivalent".to_string(),
        ComparisonResult::Different { differences } => {
            let mut report = format!("Found {} differences:\n", differences.len());
            for (i, diff) in differences.iter().enumerate() {
                report.push_str(&format!("  {}. ", i + 1));
                match &diff.diff_type {
                    DiffType::OnlyInLeft { value } => {
                        report.push_str(&format!(
                            "Key {:?} only in reference: {:?}\n",
                            String::from_utf8_lossy(&diff.key),
                            String::from_utf8_lossy(value)
                        ));
                    }
                    DiffType::OnlyInRight { value } => {
                        report.push_str(&format!(
                            "Key {:?} only in production: {:?}\n",
                            String::from_utf8_lossy(&diff.key),
                            String::from_utf8_lossy(value)
                        ));
                    }
                    DiffType::ValueMismatch { left, right } => {
                        report.push_str(&format!(
                            "Key {:?} differs: ref={:?}, prod={:?}\n",
                            String::from_utf8_lossy(&diff.key),
                            String::from_utf8_lossy(left),
                            String::from_utf8_lossy(right)
                        ));
                    }
                }
            }
            report
        }
    }
}

/// Summary statistics for a comparison
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ComparisonStats {
    /// Number of keys in left tree
    pub left_keys: usize,
    /// Number of keys in right tree
    pub right_keys: usize,
    /// Number of keys only in left
    pub only_in_left: usize,
    /// Number of keys only in right
    pub only_in_right: usize,
    /// Number of value mismatches
    pub mismatches: usize,
    /// Total number of differences
    pub total_differences: usize,
}

impl ComparisonStats {
    /// Check if the comparison shows any differences
    pub fn has_differences(&self) -> bool {
        self.total_differences > 0
    }
}

/// Generate comparison statistics without storing the full diff
pub fn compare_stats(left: &RefTree, right: &RefTree) -> ComparisonStats {
    let left_items: HashMap<Vec<u8>, Vec<u8>> = left.iter().into_iter().collect();
    let right_items: HashMap<Vec<u8>, Vec<u8>> = right.iter().into_iter().collect();

    let mut only_in_left = 0;
    let mut only_in_right = 0;
    let mut mismatches = 0;

    for (key, left_value) in &left_items {
        match right_items.get(key) {
            Some(right_value) => {
                if left_value != right_value {
                    mismatches += 1;
                }
            }
            None => {
                only_in_left += 1;
            }
        }
    }

    for key in right_items.keys() {
        if !left_items.contains_key(key) {
            only_in_right += 1;
        }
    }

    let total_differences = only_in_left + only_in_right + mismatches;

    ComparisonStats {
        left_keys: left_items.len(),
        right_keys: right_items.len(),
        only_in_left,
        only_in_right,
        mismatches,
        total_differences,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Lsn;

    fn make_tree(items: &[(&[u8], &[u8])]) -> RefTree {
        let mut tree = RefTree::new();
        for (key, value) in items {
            tree.put(key.to_vec(), value.to_vec(), Lsn::from(1));
        }
        tree
    }

    #[test]
    fn test_compare_equivalent_trees() {
        let tree1 = make_tree(&[(b"key1", b"value1"), (b"key2", b"value2")]);
        let tree2 = make_tree(&[(b"key1", b"value1"), (b"key2", b"value2")]);

        let result = compare_trees(&tree1, &tree2);
        assert!(result.is_equivalent());
    }

    #[test]
    fn test_compare_different_values() {
        let tree1 = make_tree(&[(b"key1", b"value1")]);
        let mut tree2 = RefTree::new();
        tree2.put(b"key1".to_vec(), b"different".to_vec(), Lsn::from(1));

        let result = compare_trees(&tree1, &tree2);
        assert!(!result.is_equivalent());

        let diffs = result.differences();
        assert_eq!(diffs.len(), 1);
        assert!(matches!(diffs[0].diff_type, DiffType::ValueMismatch { .. }));
    }

    #[test]
    fn test_compare_only_in_left() {
        let tree1 = make_tree(&[(b"key1", b"value1")]);
        let tree2 = RefTree::new();

        let result = compare_trees(&tree1, &tree2);
        assert!(!result.is_equivalent());

        let diffs = result.differences();
        assert_eq!(diffs.len(), 1);
        assert!(matches!(diffs[0].diff_type, DiffType::OnlyInLeft { .. }));
    }

    #[test]
    fn test_compare_only_in_right() {
        let tree1 = RefTree::new();
        let tree2 = make_tree(&[(b"key1", b"value1")]);

        let result = compare_trees(&tree1, &tree2);
        assert!(!result.is_equivalent());

        let diffs = result.differences();
        assert_eq!(diffs.len(), 1);
        assert!(matches!(diffs[0].diff_type, DiffType::OnlyInRight { .. }));
    }

    #[test]
    fn test_compare_mixed_differences() {
        let tree1 = make_tree(&[(b"a", b"1"), (b"b", b"2"), (b"c", b"3")]);
        let mut tree2 = make_tree(&[(b"a", b"1"), (b"b", b"different")]);
        tree2.put(b"d".to_vec(), b"4".to_vec(), Lsn::from(1));

        let result = compare_trees(&tree1, &tree2);
        assert!(!result.is_equivalent());

        let diffs = result.differences();
        assert_eq!(diffs.len(), 3); // b mismatch, c only left, d only right
    }

    #[test]
    fn test_compute_digest() {
        let tree1 = make_tree(&[(b"key", b"value")]);
        let tree2 = make_tree(&[(b"key", b"value")]);
        let tree3 = make_tree(&[(b"key", b"different")]);

        assert_eq!(compute_digest(&tree1), compute_digest(&tree2));
        assert_ne!(compute_digest(&tree1), compute_digest(&tree3));
    }

    #[test]
    fn test_same_digest() {
        let tree1 = make_tree(&[(b"key", b"value")]);
        let tree2 = make_tree(&[(b"key", b"value")]);
        let tree3 = make_tree(&[(b"key", b"different")]);

        assert!(same_digest(&tree1, &tree2));
        assert!(!same_digest(&tree1, &tree3));
    }

    #[test]
    fn test_generate_diff_report() {
        let tree1 = make_tree(&[(b"key1", b"value1")]);
        let mut tree2 = RefTree::new();
        tree2.put(b"key1".to_vec(), b"value2".to_vec(), Lsn::from(1));

        let result = compare_trees(&tree1, &tree2);
        let report = generate_diff_report(&result);

        assert!(report.contains("1 differences"));
        assert!(report.contains("key1"));
        assert!(report.contains("differs"));
    }

    #[test]
    fn test_generate_diff_report_equivalent() {
        let tree1 = make_tree(&[(b"key", b"value")]);
        let tree2 = make_tree(&[(b"key", b"value")]);

        let result = compare_trees(&tree1, &tree2);
        let report = generate_diff_report(&result);

        assert_eq!(report, "States are equivalent");
    }

    #[test]
    fn test_compare_stats() {
        let tree1 = make_tree(&[(b"a", b"1"), (b"b", b"2"), (b"c", b"3")]);
        let mut tree2 = make_tree(&[(b"a", b"1"), (b"b", b"different")]);
        tree2.put(b"d".to_vec(), b"4".to_vec(), Lsn::from(1));

        let stats = compare_stats(&tree1, &tree2);

        assert_eq!(stats.left_keys, 3);
        assert_eq!(stats.right_keys, 3);
        assert_eq!(stats.only_in_left, 1); // c
        assert_eq!(stats.only_in_right, 1); // d
        assert_eq!(stats.mismatches, 1); // b
        assert_eq!(stats.total_differences, 3);
    }

    #[test]
    fn test_compare_stats_no_differences() {
        let tree1 = make_tree(&[(b"key", b"value")]);
        let tree2 = make_tree(&[(b"key", b"value")]);

        let stats = compare_stats(&tree1, &tree2);

        assert!(!stats.has_differences());
        assert_eq!(stats.total_differences, 0);
    }

    #[test]
    fn test_comparison_result_is_equivalent() {
        let result = ComparisonResult::Equivalent;
        assert!(result.is_equivalent());
        assert_eq!(result.differences().len(), 0);
    }

    #[test]
    fn test_comparison_result_differences() {
        let result = ComparisonResult::Different {
            differences: vec![Difference {
                key: b"key".to_vec(),
                diff_type: DiffType::OnlyInLeft {
                    value: b"value".to_vec(),
                },
            }],
        };

        assert!(!result.is_equivalent());
        assert_eq!(result.differences().len(), 1);
    }
}
