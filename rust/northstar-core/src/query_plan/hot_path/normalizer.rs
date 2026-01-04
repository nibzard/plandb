//! Query Normalization
//!
//! This module provides functionality to normalize SQL queries by converting
//! literal values into placeholders, enabling grouping of similar queries.

use sqlparser::{ast::*, parser::Parser, dialect::GenericDialect};

use super::error::{HotPathError, HotPathResult};

/// Convert a query with literal values into a parameterized pattern.
///
/// # Arguments
/// * `query` - Original SQL query text
///
/// # Returns
/// Normalized query with literals replaced by placeholders
///
/// # Example
/// ```
/// let normalized = normalize_query("SELECT * FROM users WHERE age > 25")?;
/// // Result will be something like: "SELECT * FROM users WHERE age > $LIT"
/// ```
pub fn normalize_query(query: &str) -> HotPathResult<String> {
    let dialect = GenericDialect {};
    let ast = match Parser::parse_sql(&dialect, query) {
        Ok(statements) => statements,
        Err(e) => {
            return Err(HotPathError::QueryNormalizationError(format!(
                "Failed to parse query: {}",
                e
            )))
        }
    };

    if ast.is_empty() {
        return Ok(String::new());
    }

    // Normalize each statement and join them
    let normalized: Vec<String> = ast
        .into_iter()
        .map(|stmt| normalize_statement(&stmt))
        .collect();
    Ok(normalized.join("; "))
}

/// Normalize a single SQL statement by replacing literals with placeholders.
fn normalize_statement(stmt: &Statement) -> String {
    match stmt {
        Statement::Query(query) => normalize_query_expr(&query.body),
        Statement::Insert { .. } => {
            format!("INSERT INTO ... VALUES (...)")
        }
        Statement::Update { .. } => {
            format!("UPDATE ... SET ...")
        }
        Statement::Delete { .. } => {
            format!("DELETE FROM ...")
        }
        _ => format!("{:?}", stmt),
    }
}

/// Normalize a query expression.
fn normalize_query_expr(set_expr: &SetExpr) -> String {
    match set_expr {
        SetExpr::Select(select) => {
            let distinct = if select.distinct.is_some() { "DISTINCT " } else { "" };
            let projections: String = select
                .projection
                .iter()
                .map(|p| normalize_select_item(p))
                .collect::<Vec<_>>()
                .join(", ");

            let from = if !select.from.is_empty() {
                let from_items: String = select
                    .from
                    .iter()
                    .map(|f| format!("{}", f.relation))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!(" FROM {}", from_items)
            } else {
                String::new()
            };

            let selection = select
                .selection
                .as_ref()
                .map(|s| format!(" WHERE {}", normalize_expr(s)))
                .unwrap_or_default();

            let group_by = match &select.group_by {
                GroupByExpr::Expressions(exprs, _) if !exprs.is_empty() => {
                    let items: String = exprs.iter()
                        .map(|e| normalize_expr(e))
                        .collect::<Vec<_>>()
                        .join(", ");
                    format!(" GROUP BY {}", items)
                }
                _ => String::new(),
            };

            let having = select
                .having
                .as_ref()
                .map(|h| format!(" HAVING {}", normalize_expr(h)))
                .unwrap_or_default();

            format!(
                "SELECT {}{}{}{}{}",
                distinct, projections, from, selection, group_by
            )
        }
        SetExpr::SetOperation { op, left, right, .. } => {
            format!(
                "({}) {} ({})",
                normalize_set_expr(left),
                format!("{:?}", op),
                normalize_set_expr(right)
            )
        }
        _ => format!("{:?}", set_expr),
    }
}

/// Normalize a set expression (nested queries).
fn normalize_set_expr(set_expr: &SetExpr) -> String {
    normalize_query_expr(set_expr)
}

/// Normalize a select item (projection).
fn normalize_select_item(item: &SelectItem) -> String {
    match item {
        SelectItem::UnnamedExpr(expr) => normalize_expr(expr),
        SelectItem::ExprWithAlias { expr, alias } => {
            format!("{} AS {}", normalize_expr(expr), alias)
        }
        SelectItem::QualifiedWildcard(obj_name, _) => format!("{}.*", obj_name),
        SelectItem::Wildcard(_) => "*".to_string(),
    }
}

/// Normalize an expression by replacing literals with placeholders.
fn normalize_expr(expr: &Expr) -> String {
    match expr {
        // Literals - replace with placeholder
        Expr::Value(Value::Number(_, _))
        | Expr::Value(Value::SingleQuotedString(_))
        | Expr::Value(Value::DoubleQuotedString(_))
        | Expr::Value(Value::Boolean(_))
        | Expr::Value(Value::Null)
        | Expr::TypedString { .. } => "$LIT".to_string(),

        // Unary operations
        Expr::UnaryOp { op, expr } => {
            format!("{}{}", op, normalize_expr(expr))
        }

        // Binary operations
        Expr::BinaryOp { left, op, right } => {
            format!("{} {} {}", normalize_expr(left), op, normalize_expr(right))
        }

        // Between
        Expr::Between {
            expr,
            negated,
            low,
            high,
        } => {
            let not = if *negated { " NOT " } else { " " };
            format!(
                "{}{}BETWEEN {} AND {}",
                normalize_expr(expr),
                not,
                normalize_expr(low),
                normalize_expr(high)
            )
        }

        // Function calls
        Expr::Function(func) => {
            let name = format!("{}", func.name);
            let args = match &func.args {
                FunctionArguments::List(list) => {
                    list.args.iter()
                        .map(|arg| normalize_func_arg(arg))
                        .collect::<Vec<_>>()
                        .join(", ")
                }
                FunctionArguments::Subquery { .. } => "($LIT)".to_string(),
                FunctionArguments::None => String::new(),
            };
            format!("{}({})", name, args)
        }

        // Nested queries
        Expr::Subquery(subquery) => {
            format!("({})", normalize_query_expr(&subquery.body))
        }

        // Case expressions
        Expr::Case {
            operand,
            conditions,
            results,
            else_result,
        } => {
            let mut result = "CASE".to_string();
            if let Some(operand_expr) = operand {
                result.push_str(&format!(" {}", normalize_expr(operand_expr)));
            }
            for (cond, res) in conditions.iter().zip(results.iter()) {
                result.push_str(&format!(
                    " WHEN {} THEN {}",
                    normalize_expr(cond),
                    normalize_expr(res)
                ));
            }
            if let Some(else_res) = else_result {
                result.push_str(&format!(" ELSE {}", normalize_expr(else_res)));
            }
            result.push_str(" END");
            result
        }

        // Cast expressions
        Expr::Cast { expr, data_type, .. } => {
            format!("CAST({} AS {:?})", normalize_expr(expr), data_type)
        }

        // Is null / is not null
        Expr::IsNull(expr) => format!("{} IS NULL", normalize_expr(expr)),
        Expr::IsNotNull(expr) => format!("{} IS NOT NULL", normalize_expr(expr)),

        // In list
        Expr::InList {
            expr,
            list,
            negated,
        } => {
            let not = if *negated { " NOT " } else { " " };
            let list_str = if list.is_empty() {
                String::new()
            } else {
                format!(
                    "({})",
                    list.iter().map(|e| normalize_expr(e)).collect::<Vec<_>>().join(", ")
                )
            };
            format!("{}{}IN {}", normalize_expr(expr), not, list_str)
        }

        // Column references and identifiers
        Expr::Identifier(id) => format!("{}", id),
        Expr::CompoundIdentifier(ids) => {
            ids.iter().map(|id| format!("{}", id)).collect::<Vec<_>>().join(".")
        }

        // Wildcard
        Expr::Wildcard => "*".to_string(),

        // Default case - use debug output
        _ => format!("{:?}", expr),
    }
}

/// Normalize a function argument.
fn normalize_func_arg(arg: &FunctionArg) -> String {
    match arg {
        FunctionArg::Unnamed(func_arg_expr) => {
            match func_arg_expr {
                FunctionArgExpr::Expr(expr) => normalize_expr(expr),
                _ => format!("{:?}", func_arg_expr),
            }
        }
        FunctionArg::Named { name, arg, .. } => {
            match arg {
                FunctionArgExpr::Expr(expr) => {
                    format!("{} => {}", name, normalize_expr(expr))
                }
                _ => format!("{} => {:?}", name, arg),
            }
        }
    }
}

/// Compute hash of normalized query for grouping.
///
/// # Arguments
/// * `normalized_query` - Normalized query string
///
/// # Returns
/// 64-bit hash of the query
pub fn query_hash(normalized_query: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    normalized_query.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_simple_select() {
        let query = "SELECT * FROM users WHERE age > 25";
        let normalized = normalize_query(query).unwrap();
        assert!(normalized.contains("SELECT"));
        assert!(normalized.contains("FROM"));
        assert!(normalized.contains("WHERE"));
    }

    #[test]
    fn test_query_hash() {
        let query1 = "SELECT * FROM users WHERE age > 25";
        let query2 = "SELECT * FROM users WHERE age > 30";
        let query3 = "SELECT * FROM orders WHERE id > 25";

        let hash1 = query_hash(&normalize_query(query1).unwrap());
        let hash2 = query_hash(&normalize_query(query2).unwrap());
        let hash3 = query_hash(&normalize_query(query3).unwrap());

        // query1 and query2 should have the same hash (same pattern)
        assert_eq!(hash1, hash2);
        // query3 should have a different hash
        assert_ne!(hash1, hash3);
    }

    #[test]
    fn test_empty_query() {
        let query = "";
        let normalized = normalize_query(query).unwrap();
        assert_eq!(normalized, "");
    }
}
