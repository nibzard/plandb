//! Alert Engine and Rules
//!
//! Rule-based alerting with threshold evaluation and cooldown periods.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use parking_lot::Mutex;
use uuid::Uuid;

/// Alert severity levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum AlertSeverity {
    /// Informational, no action required
    Info,
    /// Potentially problematic, monitor closely
    Warning,
    /// Immediate action required
    Critical,
    /// System failure in progress
    Emergency,
}

/// Alert condition types.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertCondition {
    /// Value > threshold
    GreaterThan,
    /// Value < threshold
    LessThan,
    /// Value == threshold
    Equals,
    /// Value != threshold
    NotEquals,
    /// Rate of change > threshold per second
    RateAbove,
    /// Rate of change < threshold per second
    RateBelow,
}

/// Alert event triggered when threshold exceeded.
#[derive(Debug, Clone)]
pub struct Alert {
    /// Unique alert identifier
    pub id: Uuid,
    /// Alert severity level
    pub severity: AlertSeverity,
    /// Short alert title
    pub title: String,
    /// Detailed description
    pub description: String,
    /// Metric that triggered alert
    pub metric_name: String,
    /// Current metric value
    pub current_value: f64,
    /// Threshold that was exceeded
    pub threshold: f64,
    /// When alert was triggered
    pub triggered_at: Instant,
    /// When alert was resolved (None if active)
    pub resolved_at: Option<Instant>,
    /// Dimensional labels
    pub labels: HashMap<String, String>,
}

/// Alert rule defining when to trigger alerts.
#[derive(Debug, Clone)]
pub struct AlertRule {
    /// Unique rule identifier
    pub id: Uuid,
    /// Human-readable rule name
    pub name: String,
    /// Metric to monitor
    pub metric_name: String,
    /// Trigger condition
    pub condition: AlertCondition,
    /// Threshold value
    pub threshold: f64,
    /// How long condition must persist
    pub duration: Duration,
    /// Alert severity
    pub severity: AlertSeverity,
    /// Whether rule is active
    pub enabled: bool,
    /// Minimum time between alerts for this rule
    pub cooldown: Duration,
}

/// Alert engine with rule evaluation and cooldown tracking.
pub struct AlertEngine {
    rules: Mutex<Vec<AlertRule>>,
    last_alert_times: Mutex<HashMap<Uuid, Instant>>,
    active_alerts: Mutex<Vec<Alert>>,
}

impl AlertEngine {
    /// Create a new alert engine.
    pub fn new() -> Self {
        Self {
            rules: Mutex::new(Vec::new()),
            last_alert_times: Mutex::new(HashMap::new()),
            active_alerts: Mutex::new(Vec::new()),
        }
    }

    /// Register a new alert rule.
    pub fn register_rule(&self, mut rule: AlertRule) -> Result<Uuid, String> {
        if rule.metric_name.is_empty() {
            return Err("Metric name cannot be empty".to_string());
        }

        if rule.cooldown < Duration::from_secs(1) {
            return Err("Cooldown must be at least 1 second".to_string());
        }

        let id = Uuid::new_v4();
        rule.id = id;

        let mut rules = self.rules.lock();
        rules.push(rule);

        Ok(id)
    }

    /// Unregister an alert rule by ID.
    pub fn unregister_rule(&self, id: Uuid) -> bool {
        let mut rules = self.rules.lock();
        if let Some(pos) = rules.iter().position(|r| r.id == id) {
            rules.remove(pos);
            true
        } else {
            false
        }
    }

    /// Get all registered rules.
    pub fn get_rules(&self) -> Vec<AlertRule> {
        let rules = self.rules.lock();
        rules.clone()
    }

    /// Get all active alerts.
    pub fn get_active_alerts(&self) -> Vec<Alert> {
        let alerts = self.active_alerts.lock();
        alerts.iter().filter(|a| a.resolved_at.is_none()).cloned().collect()
    }

    /// Resolve an alert by ID.
    pub fn resolve_alert(&self, id: Uuid) -> bool {
        let mut alerts = self.active_alerts.lock();
        if let Some(alert) = alerts.iter_mut().find(|a| a.id == id) {
            if alert.resolved_at.is_none() {
                alert.resolved_at = Some(Instant::now());
                return true;
            }
        }
        false
    }

    /// Evaluate alert rules against current metric values.
    pub fn evaluate_rules<F>(&self, get_metric_value: F) -> Vec<Alert>
    where
        F: Fn(&str) -> Option<f64> + Sync,
    {
        let rules = self.rules.lock();
        let mut last_alert_times = self.last_alert_times.lock();
        let mut active_alerts = self.active_alerts.lock();
        let now = Instant::now();

        let mut new_alerts = Vec::new();

        for rule in rules.iter() {
            if !rule.enabled {
                continue;
            }

            let current_value = match get_metric_value(&rule.metric_name) {
                Some(v) => v,
                None => continue,
            };

            let condition_met = match rule.condition {
                AlertCondition::GreaterThan => current_value > rule.threshold,
                AlertCondition::LessThan => current_value < rule.threshold,
                AlertCondition::Equals => (current_value - rule.threshold).abs() < f64::EPSILON,
                AlertCondition::NotEquals => (current_value - rule.threshold).abs() >= f64::EPSILON,
                AlertCondition::RateAbove => {
                    // Simplified: just check value for now
                    current_value > rule.threshold
                }
                AlertCondition::RateBelow => {
                    // Simplified: just check value for now
                    current_value < rule.threshold
                }
            };

            if condition_met {
                // Check cooldown
                let can_alert = last_alert_times
                    .get(&rule.id)
                    .map(|&last| now.saturating_duration_since(last) >= rule.cooldown)
                    .unwrap_or(true);

                if can_alert {
                    let alert = Alert {
                        id: Uuid::new_v4(),
                        severity: rule.severity,
                        title: format!("Alert: {}", rule.name),
                        description: format!(
                            "Metric '{}' {} threshold {} (current: {})",
                            rule.metric_name,
                            condition_description(rule.condition),
                            rule.threshold,
                            current_value
                        ),
                        metric_name: rule.metric_name.clone(),
                        current_value,
                        threshold: rule.threshold,
                        triggered_at: now,
                        resolved_at: None,
                        labels: HashMap::new(),
                    };

                    new_alerts.push(alert.clone());
                    active_alerts.push(alert);
                    last_alert_times.insert(rule.id, now);
                }
            }
        }

        new_alerts
    }
}

/// Helper function to get condition description.
fn condition_description(condition: AlertCondition) -> &'static str {
    match condition {
        AlertCondition::GreaterThan => "exceeded",
        AlertCondition::LessThan => "fell below",
        AlertCondition::Equals => "equals",
        AlertCondition::NotEquals => "does not equal",
        AlertCondition::RateAbove => "rate exceeded",
        AlertCondition::RateBelow => "rate fell below",
    }
}

impl Default for AlertEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_severity_ord() {
        assert!(AlertSeverity::Critical > AlertSeverity::Warning);
        assert!(AlertSeverity::Emergency > AlertSeverity::Critical);
        assert!(AlertSeverity::Info < AlertSeverity::Warning);
    }

    #[test]
    fn test_alert_engine_register_rule() {
        let engine = AlertEngine::new();

        let rule = AlertRule {
            id: Uuid::default(),
            name: "Test Rule".to_string(),
            metric_name: "test_metric".to_string(),
            condition: AlertCondition::GreaterThan,
            threshold: 100.0,
            duration: Duration::from_secs(0),
            severity: AlertSeverity::Warning,
            enabled: true,
            cooldown: Duration::from_secs(60),
        };

        let id = engine.register_rule(rule).unwrap();
        assert_ne!(id, Uuid::default());

        let rules = engine.get_rules();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].name, "Test Rule");
    }

    #[test]
    fn test_alert_engine_empty_metric_name() {
        let engine = AlertEngine::new();

        let rule = AlertRule {
            id: Uuid::default(),
            name: "Test Rule".to_string(),
            metric_name: "".to_string(),
            condition: AlertCondition::GreaterThan,
            threshold: 100.0,
            duration: Duration::from_secs(0),
            severity: AlertSeverity::Warning,
            enabled: true,
            cooldown: Duration::from_secs(60),
        };

        let result = engine.register_rule(rule);
        assert!(result.is_err());
    }

    #[test]
    fn test_alert_engine_cooldown_too_short() {
        let engine = AlertEngine::new();

        let rule = AlertRule {
            id: Uuid::default(),
            name: "Test Rule".to_string(),
            metric_name: "test_metric".to_string(),
            condition: AlertCondition::GreaterThan,
            threshold: 100.0,
            duration: Duration::from_secs(0),
            severity: AlertSeverity::Warning,
            enabled: true,
            cooldown: Duration::from_millis(500),
        };

        let result = engine.register_rule(rule);
        assert!(result.is_err());
    }

    #[test]
    fn test_alert_engine_evaluate_greater_than() {
        let engine = AlertEngine::new();

        let rule = AlertRule {
            id: Uuid::default(),
            name: "High Value".to_string(),
            metric_name: "test_metric".to_string(),
            condition: AlertCondition::GreaterThan,
            threshold: 100.0,
            duration: Duration::from_secs(0),
            severity: AlertSeverity::Warning,
            enabled: true,
            cooldown: Duration::from_secs(1),
        };

        engine.register_rule(rule).unwrap();

        fn get_value(name: &str) -> Option<f64> {
            if name == "test_metric" {
                Some(150.0)
            } else {
                None
            }
        }

        let alerts = engine.evaluate_rules(get_value);
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].metric_name, "test_metric");
        assert_eq!(alerts[0].current_value, 150.0);
    }

    #[test]
    fn test_alert_engine_cooldown() {
        let engine = AlertEngine::new();

        let rule = AlertRule {
            id: Uuid::default(),
            name: "High Value".to_string(),
            metric_name: "test_metric".to_string(),
            condition: AlertCondition::GreaterThan,
            threshold: 100.0,
            duration: Duration::from_secs(0),
            severity: AlertSeverity::Warning,
            enabled: true,
            cooldown: Duration::from_secs(1),
        };

        engine.register_rule(rule).unwrap();

        fn get_value(_: &str) -> Option<f64> {
            Some(150.0)
        }

        // First evaluation should trigger alert
        let alerts1 = engine.evaluate_rules(get_value);
        assert_eq!(alerts1.len(), 1);

        // Immediate second evaluation should respect cooldown
        let alerts2 = engine.evaluate_rules(get_value);
        assert_eq!(alerts2.len(), 0);
    }

    #[test]
    fn test_alert_engine_disabled_rule() {
        let engine = AlertEngine::new();

        let rule = AlertRule {
            id: Uuid::default(),
            name: "High Value".to_string(),
            metric_name: "test_metric".to_string(),
            condition: AlertCondition::GreaterThan,
            threshold: 100.0,
            duration: Duration::from_secs(0),
            severity: AlertSeverity::Warning,
            enabled: false, // Disabled
            cooldown: Duration::from_secs(1),
        };

        engine.register_rule(rule).unwrap();

        fn get_value(_: &str) -> Option<f64> {
            Some(150.0)
        }

        let alerts = engine.evaluate_rules(get_value);
        assert_eq!(alerts.len(), 0);
    }

    #[test]
    fn test_alert_resolve() {
        let engine = AlertEngine::new();

        let rule = AlertRule {
            id: Uuid::default(),
            name: "High Value".to_string(),
            metric_name: "test_metric".to_string(),
            condition: AlertCondition::GreaterThan,
            threshold: 100.0,
            duration: Duration::from_secs(0),
            severity: AlertSeverity::Warning,
            enabled: true,
            cooldown: Duration::from_secs(1),
        };

        engine.register_rule(rule).unwrap();

        fn get_value(_: &str) -> Option<f64> {
            Some(150.0)
        }

        let alerts = engine.evaluate_rules(get_value);
        assert_eq!(alerts.len(), 1);

        let alert_id = alerts[0].id;

        // Should have 1 active alert
        let active = engine.get_active_alerts();
        assert_eq!(active.len(), 1);

        // Resolve the alert
        assert!(engine.resolve_alert(alert_id));

        // Should have 0 active alerts
        let active = engine.get_active_alerts();
        assert_eq!(active.len(), 0);
    }

    #[test]
    fn test_alert_unregister_rule() {
        let engine = AlertEngine::new();

        let rule = AlertRule {
            id: Uuid::default(),
            name: "Test Rule".to_string(),
            metric_name: "test_metric".to_string(),
            condition: AlertCondition::GreaterThan,
            threshold: 100.0,
            duration: Duration::from_secs(0),
            severity: AlertSeverity::Warning,
            enabled: true,
            cooldown: Duration::from_secs(1),
        };

        let id = engine.register_rule(rule).unwrap();

        assert!(engine.unregister_rule(id));

        let rules = engine.get_rules();
        assert_eq!(rules.len(), 0);
    }
}
