//! Maintenance Window Scheduler.
//!
//! Schedules optimizations during low-traffic periods.

use crate::autonomous::{OptimizationType, ScheduledTime, AutonomousResult};
use std::time::{SystemTime, Duration};
use chrono::{Timelike, Datelike};

/// Maintenance window configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MaintenanceWindow {
    /// Start hour (0-23)
    pub start_hour: u8,

    /// End hour (0-23)
    pub end_hour: u8,

    /// Days of week (None = all days)
    pub days_of_week: Option<Vec<chrono::Weekday>>,
}

impl MaintenanceWindow {
    /// Create new maintenance window.
    pub fn new(start_hour: u8, end_hour: u8) -> Self {
        Self {
            start_hour: start_hour.min(23),
            end_hour: end_hour.min(23),
            days_of_week: None,
        }
    }

    /// Create with specific days.
    pub fn with_days(start_hour: u8, end_hour: u8, days: Vec<chrono::Weekday>) -> Self {
        Self {
            start_hour: start_hour.min(23),
            end_hour: end_hour.min(23),
            days_of_week: Some(days),
        }
    }

    /// Check if current time is within this window.
    pub fn contains(&self, time: SystemTime) -> bool {
        let datetime = chrono::DateTime::<chrono::Utc>::from(time);
        let hour = datetime.hour() as u8;

        // Check hour range
        if self.start_hour <= self.end_hour {
            // Same day window (e.g., 2-4 AM)
            if hour < self.start_hour || hour > self.end_hour {
                return false;
            }
        } else {
            // Crosses midnight (e.g., 22-2 AM)
            if hour < self.start_hour && hour > self.end_hour {
                return false;
            }
        }

        // Check day of week if specified
        if let Some(ref days) = self.days_of_week {
            let weekday = datetime.weekday();
            if !days.contains(&weekday) {
                return false;
            }
        }

        true
    }
}

/// Maintenance scheduler for optimization execution.
pub struct MaintenanceScheduler {
    /// Maintenance windows
    windows: Vec<MaintenanceWindow>,

    /// Maximum load threshold (abort if load > threshold)
    max_load_threshold: f64,

    /// Emergency mode (bypass maintenance window)
    emergency_mode: bool,

    /// Current system load (0.0 to 1.0)
    current_load: f64,
}

impl MaintenanceScheduler {
    /// Create new maintenance scheduler.
    pub fn new(windows: Vec<MaintenanceWindow>, max_load_threshold: f64) -> Self {
        Self {
            windows,
            max_load_threshold,
            emergency_mode: false,
            current_load: 0.0,
        }
    }

    /// Create with default windows (2-4 AM daily).
    pub fn default_config() -> Self {
        Self {
            windows: vec![MaintenanceWindow::new(2, 4)],
            max_load_threshold: 0.3, // 30% CPU
            emergency_mode: false,
            current_load: 0.0,
        }
    }

    /// Set emergency mode.
    pub fn set_emergency_mode(&mut self, emergency: bool) {
        self.emergency_mode = emergency;
    }

    /// Update current load.
    pub fn update_load(&mut self, load: f64) {
        self.current_load = load.clamp(0.0, 1.0);
    }

    /// Check if can execute optimization now.
    pub fn can_execute_now(&self, optimization: &OptimizationType) -> bool {
        // Emergency optimizations always allowed
        if self.emergency_mode && self.is_emergency(optimization) {
            return true;
        }

        // Check if within maintenance window
        if !self.is_in_maintenance_window() {
            return false;
        }

        // Check current load
        if self.current_load > self.max_load_threshold {
            return false;
        }

        true
    }

    /// Schedule optimization at appropriate time.
    pub fn schedule_optimization(&self, optimization: OptimizationType) -> ScheduledTime {
        if self.can_execute_now(&optimization) {
            ScheduledTime::Now
        } else if self.is_in_maintenance_window() {
            // In window but high load - try again soon
            ScheduledTime::At(SystemTime::now() + Duration::from_secs(300)) // 5 minutes
        } else {
            ScheduledTime::NextMaintenanceWindow
        }
    }

    /// Check if currently in maintenance window.
    pub fn is_in_maintenance_window(&self) -> bool {
        let now = SystemTime::now();
        self.windows.iter().any(|w| w.contains(now))
    }

    /// Get next maintenance window start time.
    pub fn next_maintenance_window(&self) -> SystemTime {
        let now = chrono::Utc::now();
        let current_hour = now.hour() as u8;
        let current_weekday = now.weekday();

        // Check if we're in a window today
        for window in &self.windows {
            // Check day of week
            if let Some(ref days) = window.days_of_week {
                if !days.contains(&current_weekday) {
                    continue;
                }
            }

            // Check if window is later today
            if window.start_hour > current_hour {
                let next = now
                    .with_hour(window.start_hour as u32)
                    .unwrap()
                    .with_minute(0)
                    .unwrap()
                    .with_second(0)
                    .unwrap();
                return SystemTime::from(next);
            }
        }

        // No window today, check tomorrow
        for window in &self.windows {
            let next_day = now + chrono::Duration::days(1);

            // Check day of week
            if let Some(ref days) = window.days_of_week {
                let mut check_day = next_day;
                for _ in 0..7 {
                    if days.contains(&check_day.weekday()) {
                        let next = check_day
                            .with_hour(window.start_hour as u32)
                            .unwrap()
                            .with_minute(0)
                            .unwrap()
                            .with_second(0)
                            .unwrap();
                        return SystemTime::from(next);
                    }
                    check_day = check_day + chrono::Duration::days(1);
                }
            } else {
                // Any day is fine
                let next = next_day
                    .with_hour(window.start_hour as u32)
                    .unwrap()
                    .with_minute(0)
                    .unwrap()
                    .with_second(0)
                    .unwrap();
                return SystemTime::from(next);
            }
        }

        // Fallback: 6 hours from now
        SystemTime::now() + Duration::from_secs(21600)
    }

    /// Check if optimization is emergency.
    fn is_emergency(&self, optimization: &OptimizationType) -> bool {
        match optimization {
            OptimizationType::CreateIndex { .. } => false,
            OptimizationType::DropIndex { .. } => false,
            OptimizationType::CacheWarming { .. } => true, // Safe to do anytime
            OptimizationType::CacheResize { .. } => true,  // Safe to do anytime
            OptimizationType::ArchiveData { .. } => false,
            OptimizationType::CompressData { .. } => false,
            OptimizationType::Vacuum { .. } => false,
            OptimizationType::OptimizeQueryPlan { .. } => true, // Safe
        }
    }

    /// Get current load.
    pub fn current_load(&self) -> f64 {
        self.current_load
    }

    /// Get max load threshold.
    pub fn max_load_threshold(&self) -> f64 {
        self.max_load_threshold
    }
}

impl Default for MaintenanceScheduler {
    fn default() -> Self {
        Self::default_config()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_maintenance_window_contains() {
        let window = MaintenanceWindow::new(2, 4);

        // Test within window
        let time = SystemTime::UNIX_EPOCH + Duration::from_secs(7200); // 02:00
        assert!(window.contains(time));

        // Test outside window
        let time = SystemTime::UNIX_EPOCH + Duration::from_secs(18000); // 05:00
        assert!(!window.contains(time));
    }

    #[test]
    fn test_maintenance_window_cross_midnight() {
        let window = MaintenanceWindow::new(22, 2);

        // Test before midnight
        let time = SystemTime::UNIX_EPOCH + Duration::from_secs(79200); // 22:00
        assert!(window.contains(time));

        // Test after midnight
        let time = SystemTime::UNIX_EPOCH + Duration::from_secs(3600); // 01:00
        assert!(window.contains(time));

        // Test outside window
        let time = SystemTime::UNIX_EPOCH + Duration::from_secs(10800); // 03:00
        assert!(!window.contains(time));
    }

    #[test]
    fn test_scheduler_can_execute_now() {
        let mut scheduler = MaintenanceScheduler::default_config();

        // In maintenance window, low load
        scheduler.update_load(0.1);
        let opt = OptimizationType::CacheWarming {
            keys: vec![],
            cache_level: 1,
        };
        assert!(scheduler.can_execute_now(&opt));

        // In maintenance window, high load
        scheduler.update_load(0.5);
        assert!(!scheduler.can_execute_now(&opt));
    }

    #[test]
    fn test_emergency_mode() {
        let mut scheduler = MaintenanceScheduler::default_config();
        scheduler.set_emergency_mode(true);
        scheduler.update_load(0.8); // High load

        // Cache warming is emergency-safe
        let opt = OptimizationType::CacheWarming {
            keys: vec![],
            cache_level: 1,
        };
        assert!(scheduler.can_execute_now(&opt));

        // Index creation is not emergency-safe
        let opt = OptimizationType::CreateIndex {
            table: "test".to_string(),
            columns: vec!["id".to_string()],
        };
        assert!(!scheduler.can_execute_now(&opt));
    }
}
