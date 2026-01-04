//! Theme application for visualization JSON.

use crate::analytics::TimeSeriesError;
use serde_json::{json, Value};

/// Visual styling theme
#[derive(Debug, Clone, PartialEq)]
pub enum ChartTheme {
    /// Light background with dark text
    Light,
    /// Dark background with light text
    Dark,
    /// Custom color scheme
    Custom(ThemeColors),
}

/// Custom color scheme definitions
#[derive(Debug, Clone, PartialEq)]
pub struct ThemeColors {
    /// Background color (CSS color)
    pub background: String,
    /// Text color
    pub text: String,
    /// Primary color palette
    pub primary: Vec<String>,
    /// Secondary color palette
    pub secondary: Vec<String>,
    /// Grid line color
    pub grid: String,
    /// Axis line color
    pub axis: String,
}

impl ThemeColors {
    /// Create a new theme color scheme
    pub fn new(
        background: String,
        text: String,
        primary: Vec<String>,
        secondary: Vec<String>,
        grid: String,
        axis: String,
    ) -> Self {
        Self {
            background,
            text,
            primary,
            secondary,
            grid,
            axis,
        }
    }
}

impl Default for ThemeColors {
    fn default() -> Self {
        Self::light()
    }
}

impl ThemeColors {
    /// Default light theme colors
    pub fn light() -> Self {
        Self {
            background: "#ffffff".to_string(),
            text: "#333333".to_string(),
            primary: vec![
                "#3b82f6".to_string(),
                "#ef4444".to_string(),
                "#10b981".to_string(),
                "#f59e0b".to_string(),
                "#8b5cf6".to_string(),
                "#ec4899".to_string(),
            ],
            secondary: vec![
                "#93c5fd".to_string(),
                "#fca5a5".to_string(),
                "#6ee7b7".to_string(),
                "#fcd34d".to_string(),
                "#c4b5fd".to_string(),
                "#f9a8d4".to_string(),
            ],
            grid: "#e5e7eb".to_string(),
            axis: "#9ca3af".to_string(),
        }
    }

    /// Default dark theme colors
    pub fn dark() -> Self {
        Self {
            background: "#1f2937".to_string(),
            text: "#f9fafb".to_string(),
            primary: vec![
                "#60a5fa".to_string(),
                "#f87171".to_string(),
                "#34d399".to_string(),
                "#fbbf24".to_string(),
                "#a78bfa".to_string(),
                "#f472b6".to_string(),
            ],
            secondary: vec![
                "#3b82f6".to_string(),
                "#ef4444".to_string(),
                "#10b981".to_string(),
                "#f59e0b".to_string(),
                "#8b5cf6".to_string(),
                "#ec4899".to_string(),
            ],
            grid: "#374151".to_string(),
            axis: "#6b7280".to_string(),
        }
    }
}

/// Apply color theme to visualization JSON
pub fn apply_theme(data: String, theme: &ChartTheme) -> Result<String, TimeSeriesError> {
    // Parse JSON string to Value
    let mut json: Value = serde_json::from_str(&data)
        .map_err(|e| TimeSeriesError::InvalidWindow(format!("Invalid JSON: {}", e)))?;

    // Get theme colors
    let colors = match theme {
        ChartTheme::Light => ThemeColors::light(),
        ChartTheme::Dark => ThemeColors::dark(),
        ChartTheme::Custom(c) => c.clone(),
    };

    // Apply theme based on JSON structure
    if let Some(obj) = json.as_object_mut() {
        // Chart.js format
        if obj.contains_key("options") {
            apply_chart_js_theme(obj, &colors);
        }
        // Plotly format
        else if obj.contains_key("layout") {
            apply_plotly_theme(obj, &colors);
        }
        // Generic format - apply basic colors
        else {
            apply_generic_theme(obj, &colors);
        }
    }

    // Serialize back to JSON string
    serde_json::to_string_pretty(&json)
        .map_err(|e| TimeSeriesError::InvalidWindow(format!("Failed to serialize JSON: {}", e)))
}

/// Apply theme to Chart.js format
fn apply_chart_js_theme(obj: &mut serde_json::Map<String, Value>, colors: &ThemeColors) {
    if let Some(options) = obj.get_mut("options").and_then(|v| v.as_object_mut()) {
        // Set plugins colors
        if let Some(plugins) = options.get_mut("plugins").and_then(|v| v.as_object_mut()) {
            // Legend color
            if let Some(legend) = plugins.get_mut("legend").and_then(|v| v.as_object_mut()) {
                legend.insert("labels".to_string(), json!({
                    "color": colors.text
                }));
            }

            // Title color
            if let Some(title) = plugins.get_mut("title").and_then(|v| v.as_object_mut()) {
                title.insert("color".to_string(), Value::String(colors.text.clone()));
            }
        }

        // Set scale colors
        if let Some(scales) = options.get_mut("scales").and_then(|v| v.as_object_mut()) {
            // X-axis colors
            if let Some(x) = scales.get_mut("x").and_then(|v| v.as_object_mut()) {
                apply_axis_theme(x, colors);
            }

            // Y-axis colors
            if let Some(y_array) = scales.get_mut("y").and_then(|v| v.as_array_mut()) {
                for y in y_array.iter_mut().filter_map(|v| v.as_object_mut()) {
                    apply_axis_theme(y, colors);
                }
            }
        }
    }

    // Set dataset colors
    if let Some(datasets) = obj.get_mut("datasets").and_then(|v| v.as_array_mut()) {
        for (i, dataset) in datasets.iter_mut().enumerate() {
            if let Some(ds_obj) = dataset.as_object_mut() {
                // Use primary color palette
                let color = colors.primary.get(i % colors.primary.len()).unwrap();
                let bg_color = colors.secondary.get(i % colors.secondary.len()).unwrap();

                ds_obj.insert("borderColor".to_string(), Value::String(color.clone()));
                ds_obj.insert("backgroundColor".to_string(), Value::String(bg_color.clone()));
            }
        }
    }
}

/// Apply theme colors to Chart.js axis
fn apply_axis_theme(axis: &mut serde_json::Map<String, Value>, colors: &ThemeColors) {
    // Ticks color
    axis.insert("ticks".to_string(), json!({
        "color": colors.text
    }));

    // Grid color
    axis.insert("grid".to_string(), json!({
        "color": colors.grid
    }));

    // Title color
    if let Some(title) = axis.get_mut("title").and_then(|v| v.as_object_mut()) {
        title.insert("color".to_string(), Value::String(colors.text.clone()));
    }
}

/// Apply theme to Plotly format
fn apply_plotly_theme(obj: &mut serde_json::Map<String, Value>, colors: &ThemeColors) {
    // Set layout colors
    if let Some(layout) = obj.get_mut("layout").and_then(|v| v.as_object_mut()) {
        layout.insert("plot_bgcolor".to_string(), Value::String(colors.background.clone()));
        layout.insert("paper_bgcolor".to_string(), Value::String(colors.background.clone()));
        layout.insert("font".to_string(), json!({
            "color": colors.text
        }));

        // Set axis colors
        for axis_key in ["xaxis", "yaxis", "xaxis2", "yaxis2"].iter() {
            if let Some(axis) = layout.get_mut(*axis_key).and_then(|v| v.as_object_mut()) {
                axis.insert("gridcolor".to_string(), Value::String(colors.grid.clone()));
                axis.insert("zerolinecolor".to_string(), Value::String(colors.axis.clone()));
            }
        }
    }

    // Set trace colors
    if let Some(data) = obj.get_mut("data").and_then(|v| v.as_array_mut()) {
        for (i, trace) in data.iter_mut().enumerate() {
            if let Some(trace_obj) = trace.as_object_mut() {
                let color = colors.primary.get(i % colors.primary.len()).unwrap();
                if let Some(line) = trace_obj.get_mut("line").and_then(|v| v.as_object_mut()) {
                    line.insert("color".to_string(), Value::String(color.clone()));
                }
            }
        }
    }
}

/// Apply generic theme to any JSON structure
fn apply_generic_theme(obj: &mut serde_json::Map<String, Value>, colors: &ThemeColors) {
    // Set background if present
    if !obj.contains_key("backgroundColor") {
        obj.insert("backgroundColor".to_string(), Value::String(colors.background.clone()));
    }

    // Set text color if present
    if !obj.contains_key("textColor") {
        obj.insert("textColor".to_string(), Value::String(colors.text.clone()));
    }

    // Set grid color if present
    if !obj.contains_key("gridColor") {
        obj.insert("gridColor".to_string(), Value::String(colors.grid.clone()));
    }
}

/// Create a Chart.js dataset with colors from theme
pub fn chart_js_dataset_with_theme(
    label: String,
    data: Vec<f64>,
    theme: &ChartTheme,
    index: usize,
) -> crate::analytics::visualization::ChartJsDataset {
    let colors = match theme {
        ChartTheme::Light => ThemeColors::light(),
        ChartTheme::Dark => ThemeColors::dark(),
        ChartTheme::Custom(c) => c.clone(),
    };

    let color = colors.primary.get(index % colors.primary.len()).cloned();
    let bg_color = colors.secondary.get(index % colors.secondary.len()).cloned();

    crate::analytics::visualization::ChartJsDataset {
        label,
        data,
        border_color: color,
        background_color: bg_color,
        chart_type: None,
    }
}

/// Create a Plotly trace with colors from theme
pub fn plotly_trace_with_theme(
    name: String,
    x: Vec<f64>,
    y: Vec<f64>,
    trace_type: String,
    mode: String,
    theme: &ChartTheme,
    index: usize,
) -> crate::analytics::visualization::PlotlyTrace {
    let colors = match theme {
        ChartTheme::Light => ThemeColors::light(),
        ChartTheme::Dark => ThemeColors::dark(),
        ChartTheme::Custom(c) => c.clone(),
    };

    let color = colors.primary.get(index % colors.primary.len()).cloned();

    crate::analytics::visualization::PlotlyTrace {
        x,
        y,
        name,
        mode,
        trace_type,
        line: if let Some(c) = color {
            Some(crate::analytics::visualization::PlotlyLine {
                color: c,
                width: 2.0,
            })
        } else {
            None
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_theme_colors_light() {
        let colors = ThemeColors::light();
        assert_eq!(colors.background, "#ffffff");
        assert_eq!(colors.text, "#333333");
        assert!(colors.primary.len() >= 6);
    }

    #[test]
    fn test_theme_colors_dark() {
        let colors = ThemeColors::dark();
        assert_eq!(colors.background, "#1f2937");
        assert_eq!(colors.text, "#f9fafb");
        assert!(colors.primary.len() >= 6);
    }

    #[test]
    fn test_apply_theme_to_chart_js() {
        let json = r#"{
            "labels": ["A", "B", "C"],
            "datasets": [{"label": "Test", "data": [1, 2, 3]}],
            "options": {
                "plugins": {
                    "legend": {"display": true},
                    "title": {"display": true, "text": "Test Chart"}
                },
                "scales": {
                    "x": {"type": "category", "position": "bottom"},
                    "y": [{"type": "linear", "position": "left"}]
                }
            }
        }"#;

        let result = apply_theme(json.to_string(), &ChartTheme::Light);
        assert!(result.is_ok());

        let themed = result.unwrap();
        assert!(themed.contains("color"));
    }

    #[test]
    fn test_apply_theme_invalid_json() {
        let result = apply_theme("not json".to_string(), &ChartTheme::Light);
        assert!(result.is_err());
    }

    #[test]
    fn test_chart_js_dataset_with_theme() {
        use crate::analytics::visualization::ChartJsDataset;

        let dataset = chart_js_dataset_with_theme(
            "Test".to_string(),
            vec![1.0, 2.0, 3.0],
            &ChartTheme::Light,
            0,
        );

        assert_eq!(dataset.label, "Test");
        assert!(dataset.border_color.is_some());
        assert!(dataset.background_color.is_some());
    }

    #[test]
    fn test_plotly_trace_with_theme() {
        use crate::analytics::visualization::PlotlyTrace;

        let trace = plotly_trace_with_theme(
            "Test".to_string(),
            vec![1.0, 2.0, 3.0],
            vec![4.0, 5.0, 6.0],
            "scatter".to_string(),
            "lines".to_string(),
            &ChartTheme::Dark,
            0,
        );

        assert_eq!(trace.name, "Test");
        assert!(trace.line.is_some());
    }
}
