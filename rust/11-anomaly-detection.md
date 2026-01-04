# Trend Analysis and Anomaly Detection

## Purpose

Trend analysis and anomaly detection provide intelligent monitoring and alerting capabilities for NorthstarDB. This component analyzes time-series data to identify patterns, trends, and deviations from expected behavior, enabling proactive detection of performance issues, security anomalies, and operational problems before they impact users.

## Core Concepts

### Trend

A trend is the general direction in which data points are moving over time. Trends can be upward (increasing), downward (decreasing), or stationary (stable). Trend analysis enables forecasting and capacity planning.

### Anomaly

An anomaly is a data point or pattern that deviates significantly from expected behavior. Anomalies can be point anomalies (single outliers), contextual anomalies (abnormal in specific context), or collective anomalies (group of data points that are anomalous together).

### Detection Methods

Various statistical and machine learning methods are used to detect anomalies:
- Statistical: Z-score, modified Z-score, interquartile range
- Time-series: Moving average, exponential smoothing, ARIMA deviations
- ML-based: Isolation forest, one-class SVM, autoencoder reconstruction error

## Types

### TrendDirection

**Description**: Direction of trend

**Variants**:
- `Upward` - Increasing trend
- `Downward` - Decreasing trend
- `Stationary` - No clear trend (flat)
- `Volatile` - High variance with no clear direction

### TrendAnalysis

**Description**: Result of trend analysis

**Fields**:
- `direction: TrendDirection` - Trend direction
- `slope: f64` - Linear regression slope
- `intercept: f64` - Linear regression intercept
- `r_squared: f64` - Goodness of fit (0.0 to 1.0)
- `confidence: f64` - Confidence in trend (0.0 to 1.0)
- `seasonality: Option<Seasonality>` - Detected seasonality pattern

**Invariants**:
- `r_squared` is in range [0.0, 1.0]
- `confidence` is in range [0.0, 1.0]

### Seasonality

**Description**: Seasonal pattern in data

**Fields**:
- `period_ms: i64` - Period of seasonality in milliseconds
- `amplitude: f64` - Average amplitude of seasonal variation
- `phase: f64` - Phase offset in radians

**Invariants**:
- `period_ms > 0`
- `amplitude >= 0`

### AnomalyType

**Description**: Type of anomaly detected

**Variants**:
- `Point` - Single data point is anomalous
- `Contextual` - Point is anomalous in specific context
- `Collective` - Group of consecutive points is anomalous
- `TrendChange` - Sudden change in trend direction
- `VarianceSpike` - Sudden increase in variance
- `PatternBreak` - Expected pattern is violated

### AnomalySeverity

**Description**: Severity level of anomaly

**Variants**:
- `Low` - Minor deviation, investigate when convenient
- `Medium` - Moderate deviation, investigate soon
- `High` - Major deviation, investigate immediately
- `Critical` - Extreme deviation, emergency action required

### Anomaly

**Description**: Detected anomaly with context

**Fields**:
- `anomaly_id: String` - Unique anomaly identifier
- `anomaly_type: AnomalyType` - Type of anomaly
- `severity: AnomalySeverity` - Anomaly severity
- `timestamp: i64` - Timestamp of anomaly (milliseconds)
- `value: f64` - Anomalous value
- `expected_value: f64` - Expected value based on model
- `deviation: f64` - Absolute deviation from expected
- `score: f64` - Anomaly score (higher = more anomalous)
- `confidence: f64` - Confidence in anomaly detection (0.0 to 1.0)
- `context: HashMap<String, String>` - Additional context
- `affected_series: Vec<String>` - Series affected by anomaly

**Invariants**:
- `deviation >= 0`
- `score >= 0`
- `confidence` is in range [0.0, 1.0]

### AnomalyDetectionResult

**Description**: Complete result of anomaly detection

**Fields**:
- `anomalies: Vec<Anomaly>` - Detected anomalies
- `baseline: BaselineModel` - Baseline model used for detection
- `timestamp_range: (i64, i64)` - Time range analyzed
- `total_points: usize` - Total data points analyzed
- `anomaly_count: usize` - Number of anomalies detected
- `anomaly_rate: f64` - Percentage of points flagged as anomalous

**Invariants**:
- `anomaly_count <= total_points`
- `anomaly_rate` is in range [0.0, 1.0]

### BaselineModel

**Description**: Model representing expected behavior

**Fields**:
- `model_type: ModelType` - Type of baseline model
- `parameters: HashMap<String, f64>` - Model parameters
- `trained_at: i64` - When model was trained
- `training_data_points: usize` - Number of points used for training
- `accuracy: f64` - Model accuracy metric

**Invariants**:
- `accuracy` is in range [0.0, 1.0]

### ModelType

**Description**: Type of baseline model

**Variants**:
- `MovingAverage` - Simple moving average
- `ExponentialSmoothing` - Exponentially weighted moving average
- `LinearRegression` - Linear regression trend
- `ARIMA` - Auto-Regressive Integrated Moving Average
- `IsolationForest` - Isolation forest ML model
- `OneClassSVM` - One-class support vector machine
- `Autoencoder` - Neural network autoencoder
- `Custom(String)` - Custom model type

### DetectionConfig

**Description**: Configuration for anomaly detection

**Fields**:
- `model_type: ModelType` - Model to use
- `sensitivity: f64` - Detection sensitivity (0.0 to 1.0, higher = more sensitive)
- `min_anomaly_score: f64` - Minimum score to flag as anomaly
- `max_anomaly_rate: f64` - Maximum acceptable anomaly rate (0.0 to 1.0)
- `window_size_ms: i64` - Time window for baseline computation
- `min_training_points: usize` - Minimum points required for training
- `seasonality_enabled: bool` - Whether to detect seasonality
- `trend_enabled: bool` - Whether to account for trend

**Invariants**:
- `sensitivity` is in range [0.0, 1.0]
- `min_anomaly_score >= 0`
- `max_anomaly_rate` is in range [0.0, 1.0]
- `window_size_ms > 0`
- `min_training_points >= 1`

### StatisticalSummary

**Description**: Statistical summary of data

**Fields**:
- `count: usize` - Number of data points
- `mean: f64` - Mean value
- `median: f64` - Median value
- `stddev: f64` - Standard deviation
- `variance: f64` - Variance
- `min: f64` - Minimum value
- `max: f64` - Maximum value
- `q1: f64` - First quartile (25th percentile)
- `q3: f64` - Third quartile (75th percentile)
- `iqr: f64` - Interquartile range (q3 - q1)
- `skewness: f64` - Skewness (asymmetry)
- `kurtosis: f64` - Kurtosis (tailedness)

**Invariants**:
- `count >= 1`
- `stddev >= 0`
- `variance >= 0`
- `iqr >= 0`
- `min <= q1 <= median <= q3 <= max`

### ZScoreResult

**Description**: Z-score based anomaly detection

**Fields**:
- `z_scores: Vec<f64>` - Z-scores for each data point
- `threshold: f64` - Z-score threshold for anomalies (typically 3.0)
- `anomalies: Vec<usize>` - Indices of anomalous points

**Invariants**:
- `z_scores.len()` equals input data length
- All anomaly indices are valid (less than data length)

### MovingAverageResult

**Description**: Moving average baseline

**Fields**:
- `window_size: usize` - Size of moving average window
- `averages: Vec<f64>` - Moving average values
- `residuals: Vec<f64>` - Residuals (actual - predicted)

**Invariants**:
- `averages.len() == residuals.len()`
- `averages.len() <= input data length` (shorter at beginning)

### ForecastResult

**Description**: Forecast of future values

**Fields**:
- `forecasted_values: Vec<f64>` - Forecasted values
- `confidence_intervals: Vec<(f64, f64)>` - Lower and upper bounds
- `forecast_horizon_ms: i64` - Time horizon of forecast
- `method: ForecastMethod` - Method used for forecasting
- `accuracy: Option<f64>` - Forecast accuracy (if historical data available)

**Invariants**:
- `forecasted_values.len() == confidence_intervals.len()`
- All confidence interval bounds are valid (lower <= upper)

### ForecastMethod

**Description**: Forecasting method

**Variants**:
- `Naive` - Use last value as forecast
- `MovingAverage` - Average of recent values
- `ExponentialSmoothing` - Exponentially weighted average
- `LinearRegression` - Extrapolate trend line
- `ARIMA` - ARIMA time-series model
- `Prophet` - Facebook Prophet model

### AlertRule

**Description**: Rule for triggering alerts based on anomalies

**Fields**:
- `rule_id: String` - Unique rule identifier
- `name: String` - Rule name
- `condition: AlertCondition` - Condition for triggering alert
- `severity_threshold: AnomalySeverity` - Minimum severity to alert
- `cooldown_ms: i64` - Minimum time between alerts (milliseconds)
- `enabled: bool` - Whether rule is enabled
- `notification_channels: Vec<String>` - Where to send alerts

**Invariants**:
- `cooldown_ms >= 0`

### AlertCondition

**Description**: Condition for triggering alert

**Variants**:
- `AnomalyDetected` - Alert on any anomaly
- `AnomalyCountAbove(usize)` - Alert when anomaly count exceeds threshold
- `AnomalyRateAbove(f64)` - Alert when anomaly rate exceeds threshold
- `SeverityAtLeast(AnomalySeverity)` - Alert when severity is at least threshold
- `Custom(String)` - Custom condition expression

### Alert

**Description**: Alert triggered by rule

**Fields**:
- `alert_id: String` - Unique alert identifier
- `rule_id: String` - Rule that triggered alert
- `severity: AnomalySeverity` - Alert severity
- `timestamp: i64` - Alert timestamp
- `anomalies: Vec<Anomaly>` - Anomalies that triggered alert
- `message: String` - Alert message
- `context: HashMap<String, String>` - Additional context
- `acknowledged: bool` - Whether alert has been acknowledged
- `resolved: bool` - Whether alert has been resolved

**Invariants**:
- `anomalies` is non-empty

## Functions

### analyze_trend(data: &[(i64, f64)]) -> TrendAnalysis

**Purpose**: Analyze trend in time-series data

**Parameters**:
- `data: &[(i64, f64)]` - Time-series data (timestamp, value) pairs

**Returns**: `TrendAnalysis` - Trend analysis result

**Algorithm**:
1. If data is empty, return stationary trend with zero confidence
2. Extract timestamps and values into separate arrays
3. Perform linear regression:
   a. Compute means of timestamps and values
   b. Compute slope and intercept using least squares
   c. Compute R-squared (coefficient of determination)
4. Determine direction:
   a. If slope > threshold, return Upward
   b. If slope < -threshold, return Downward
   c. Otherwise, return Stationary
5. Detect seasonality using autocorrelation or FFT
6. Compute confidence from R-squared and data quality
7. Return TrendAnalysis

**Error Conditions**: None (returns default analysis for empty data)

**Concurrency**: Read-only access to data, thread-safe

### detect_anomalies_zscore(data: &[(i64, f64)], threshold: f64) -> AnomalyDetectionResult

**Purpose**: Detect anomalies using Z-score method

**Parameters**:
- `data: &[(i64, f64)]` - Time-series data
- `threshold: f64` - Z-score threshold (typically 3.0)

**Returns**: `AnomalyDetectionResult` - Detected anomalies

**Algorithm**:
1. If data is empty, return empty result
2. Compute mean and standard deviation of values
3. For each data point:
   a. Compute z-score: (value - mean) / stddev
   b. If absolute z-score > threshold, flag as anomaly
4. Create Anomaly objects for flagged points:
   a. Set expected_value to mean
   b. Set deviation to absolute difference from mean
   c. Set score to absolute z-score
5. Build AnomalyDetectionResult with anomalies
6. Return result

**Error Conditions**: None (returns empty result for empty data)

**Concurrency**: Read-only access to data, thread-safe

### detect_anomalies_iqr(data: &[(i64, f64)], multiplier: f64) -> AnomalyDetectionResult

**Purpose**: Detect anomalies using interquartile range method

**Parameters**:
- `data: &[(i64, f64)]` - Time-series data
- `multiplier: f64` - IQR multiplier (typically 1.5 or 3.0)

**Returns**: `AnomalyDetectionResult` - Detected anomalies

**Algorithm**:
1. If data is empty, return empty result
2. Compute quartiles:
   a. Sort values
   b. Find Q1 (25th percentile) and Q3 (75th percentile)
   c. Compute IQR: Q3 - Q1
3. Compute bounds:
   a. Lower bound: Q1 - multiplier * IQR
   b. Upper bound: Q3 + multiplier * IQR
4. For each data point:
   a. If value < lower bound or value > upper bound, flag as anomaly
5. Create Anomaly objects for flagged points
6. Return AnomalyDetectionResult

**Error Conditions**: None (returns empty result for empty data)

**Concurrency**: Read-only access to data, thread-safe

### detect_anomalies_moving_average(data: &[(i64, f64)], window_size: usize, threshold: f64) -> AnomalyDetectionResult

**Purpose**: Detect anomalies using moving average baseline

**Parameters**:
- `data: &[(i64, f64)]` - Time-series data
- `window_size: usize` - Moving average window size
- `threshold: f64` - Standard deviation threshold

**Returns**: `AnomalyDetectionResult` - Detected anomalies

**Algorithm**:
1. If data length < window_size, return empty result
2. Compute moving average for each point:
   a. Average of previous `window_size` points
   b. Skip first `window_size - 1` points (insufficient data)
3. Compute moving standard deviation for residuals
4. For each point with baseline:
   a. Compute residual: actual - baseline
   b. If |residual| > threshold * moving_stddev, flag as anomaly
5. Create Anomaly objects for flagged points
6. Return AnomalyDetectionResult

**Error Conditions**: None (returns empty result for insufficient data)

**Concurrency**: Read-only access to data, thread-safe

### detect_anomalies_exponential_smoothing(data: &[(i64, f64)], alpha: f64, threshold: f64) -> AnomalyDetectionResult

**Purpose**: Detect anomalies using exponential smoothing baseline

**Parameters**:
- `data: &[(i64, f64)]` - Time-series data
- `alpha: f64` - Smoothing factor (0.0 to 1.0)
- `threshold: f64` - Standard deviation threshold

**Returns**: `AnomalyDetectionResult` - Detected anomalies

**Algorithm**:
1. If data is empty, return empty result
2. Initialize smoothed value to first data point
3. Initialize residuals Vec
4. For each subsequent data point:
   a. Compute residual: actual - smoothed
   b. Push residual to residuals
   c. Update smoothed: alpha * actual + (1 - alpha) * smoothed
5. Compute mean and standard deviation of residuals
6. For each residual:
   a. If |residual| > threshold * stddev, flag as anomaly
7. Create Anomaly objects for flagged points
8. Return AnomalyDetectionResult

**Error Conditions**: None (returns empty result for empty data)

**Concurrency**: Read-only access to data, thread-safe

### compute_statistical_summary(data: &[f64]) -> StatisticalSummary

**Purpose**: Compute comprehensive statistics

**Parameters**:
- `data: &[f64]` - Numeric values

**Returns**: `StatisticalSummary` - Statistical summary

**Algorithm**:
1. If data is empty, return default summary
2. Compute basic stats:
   a. Mean: sum / count
   b. Min, max: find minimum and maximum
3. Sort data for percentiles
4. Compute median, Q1, Q3, IQR
5. Compute variance and standard deviation
6. Compute skewness and kurtosis using moments
7. Return StatisticalSummary

**Error Conditions**: None (returns default summary for empty data)

**Concurrency**: Read-only access to data, thread-safe

### detect_seasonality(data: &[(i64, f64)], max_period_ms: i64) -> Option<Seasonality>

**Purpose**: Detect seasonal patterns in data

**Parameters**:
- `data: &[(i64, f64)]` - Time-series data
- `max_period_ms: i64` - Maximum period to check

**Returns**: `Option<Seasonality>` - Detected seasonality or None

**Algorithm**:
1. If data is empty, return None
2. Detrend data by subtracting linear regression line
3. Compute autocorrelation for various lags
4. Find lag with maximum autocorrelation (excluding lag 0)
5. If maximum autocorrelation > threshold:
   a. Period: lag * average time between points
   b. Amplitude: average amplitude at detected period
   c. Phase: phase offset from sine wave fit
6. Return Seasonality or None if no significant seasonality

**Error Conditions**: None (returns None for empty data)

**Concurrency**: Read-only access to data, thread-safe

### forecast(data: &[(i64, f64)], horizon_ms: i64, method: ForecastMethod) -> ForecastResult

**Purpose**: Forecast future values

**Parameters**:
- `data: &[(i64, f64)]` - Historical data
- `horizon_ms: i64` - Forecast horizon
- `method: ForecastMethod` - Forecasting method

**Returns**: `ForecastResult` - Forecast with confidence intervals

**Algorithm**:
1. Determine number of points to forecast based on horizon and data frequency
2. Match on method:
   - Naive: Use last value for all forecasted points
   - MovingAverage: Use average of last N values
   - ExponentialSmoothing: Exponentially weighted forecast
   - LinearRegression: Extrapolate regression line
   - ARIMA: Fit ARIMA model and forecast
3. Compute confidence intervals using historical residuals
4. Return ForecastResult

**Error Conditions**:
- `InsufficientData`: When data is too short for method

**Concurrency**: Read-only access to data, thread-safe

### evaluate_alert_rules(anomalies: &[Anomaly], rules: &[AlertRule]) -> Vec<Alert>

**Purpose**: Check which alert rules are triggered

**Parameters**:
- `anomalies: &[Anomaly]` - Detected anomalies
- `rules: &[AlertRule]` - Alert rules to evaluate

**Returns**: `Vec<Alert>` - Triggered alerts

**Algorithm**:
1. Initialize empty alerts Vec
2. For each enabled rule:
   a. Match on rule condition:
     - AnomalyDetected: Trigger if anomalies non-empty
     - AnomalyCountAbove(n): Trigger if count > n
     - AnomalyRateAbove(r): Trigger if rate > r
     - SeverityAtLeast(s): Trigger if any anomaly >= s
   b. If condition met:
     - Create Alert with rule context
     - Add matching anomalies to alert
     - Generate alert message
3. Return triggered alerts

**Error Conditions**: None (returns empty Vec if no rules triggered)

**Concurrency**: Read-only access to anomalies and rules, thread-safe

### train_baseline_model(data: &[(i64, f64)], model_type: ModelType) -> BaselineModel

**Purpose**: Train baseline model on historical data

**Parameters**:
- `data: &[(i64, f64)]` - Training data
- `model_type: ModelType` - Type of model to train

**Returns**: `BaselineModel` - Trained model

**Algorithm**:
1. Match on model_type:
   - MovingAverage: Compute optimal window size via cross-validation
   - ExponentialSmoothing: Compute optimal alpha via cross-validation
   - LinearRegression: Fit linear regression to data
   - ARIMA: Fit ARIMA parameters (p, d, q) via grid search
   - IsolationForest: Train isolation forest on data
   - OneClassSVM: Train one-class SVM on data
2. Compute model accuracy on training or validation data
3. Store model parameters in HashMap
4. Create BaselineModel with parameters and metadata
5. Return model

**Error Conditions**: None (returns default model for insufficient data)

**Concurrency**: Read-only access to data, thread-safe

### detect_anomalies_with_model(data: &[(i64, f64)], model: &BaselineModel, config: &DetectionConfig) -> AnomalyDetectionResult

**Purpose**: Detect anomalies using trained baseline model

**Parameters**:
- `data: &[(i64, f64)]` - Data to analyze
- `model: &BaselineModel` - Trained baseline model
- `config: &DetectionConfig` - Detection configuration

**Returns**: `AnomalyDetectionResult` - Detected anomalies

**Algorithm**:
1. For each data point:
   a. Compute expected value using model
   b. Compute residual: actual - expected
   c. Compute anomaly score from residual (e.g., |residual| / stddev)
   d. If score > config.min_anomaly_score, flag as anomaly
2. If anomaly rate exceeds config.max_anomaly_rate, adjust threshold
3. Filter anomalies by severity based on score
4. Create AnomalyDetectionResult
5. Return result

**Error Conditions**:
- `ModelIncompatible`: When model type doesn't match data

**Concurrency**: Read-only access to data and model, thread-safe

### compute_anomaly_score(value: f64, expected: f64, stddev: f64, method: ScoringMethod) -> f64

**Purpose**: Compute anomaly score for single point

**Parameters**:
- `value: f64` - Actual value
- `expected: f64` - Expected value
- `stddev: f64` - Standard deviation
- `method: ScoringMethod` - Scoring method

**Returns**: `f64` - Anomaly score (higher = more anomalous)

**Algorithm**:
1. Match on method:
   - ZScore: Return |value - expected| / stddev
   - ModifiedZScore: Return 0.6745 * |value - median| / MAD
   - Percentile: Return percentile of residual in empirical distribution
   - Custom: Use custom scoring function
2. Return computed score

**Error Conditions**: None (returns 0.0 for invalid inputs)

**Concurrency**: Pure function, thread-safe

### ScoringMethod

**Description**: Method for computing anomaly scores

**Variants**:
- `ZScore` - Standard Z-score
- `ModifiedZScore` - Modified Z-score using median and MAD
- `Percentile` - Empirical percentile
- `IQR` - Interquartile range based
- `Custom(String)` - Custom scoring function

### detect_collective_anomalies(data: &[(i64, f64)], window_size: usize, threshold: f64) -> Vec<(usize, usize)>

**Purpose**: Detect collective anomalies (groups of anomalous points)

**Parameters**:
- `data: &[(i64, f64)]` - Time-series data
- `window_size: usize` - Size of window to analyze
- `threshold: f64` - Anomaly threshold for windows

**Returns**: `Vec<(usize, usize)>` - Start and end indices of anomalous windows

**Algorithm**:
1. Slide window of size `window_size` over data
2. For each window:
   a. Compute window statistics (mean, stddev)
   b. Compare window to surrounding windows
   c. Compute anomaly score for window
   d. If score > threshold, mark window as anomalous
3. Merge overlapping or adjacent anomalous windows
4. Return merged window ranges

**Error Conditions**: None (returns empty Vec for insufficient data)

**Concurrency**: Read-only access to data, thread-safe

### detect_change_points(data: &[(i64, f64)], min_segment_size: usize) -> Vec<usize>

**Purpose**: Detect change points in time-series

**Parameters**:
- `data: &[(i64, f64)]` - Time-series data
- `min_segment_size: usize` - Minimum segment size between changes

**Returns**: `Vec<usize>` - Indices of change points

**Algorithm**:
1. Initialize change_points Vec
2. Use sliding window to compare distributions:
   a. For each possible change point
   b. Compute statistics before and after
   c. Use statistical test (e.g., t-test) to detect significant difference
   d. If p-value < threshold, add to change_points
3. Filter change points to respect min_segment_size
4. Return change_points

**Error Conditions**: None (returns empty Vec for insufficient data)

**Concurrency**: Read-only access to data, thread-safe

### smooth_exponential(data: &[(i64, f64)], alpha: f64) -> Vec<(i64, f64)>

**Purpose**: Apply exponential smoothing to data

**Parameters**:
- `data: &[(i64, f64)]` - Input data
- `alpha: f64` - Smoothing factor (0.0 to 1.0)

**Returns**: `Vec<(i64, f64)>` - Smoothed data

**Algorithm**:
1. If data is empty, return empty Vec
2. Initialize result Vec with first data point
3. Initialize smoothed value to first data point's value
4. For each subsequent point:
   a. Update smoothed: alpha * value + (1 - alpha) * smoothed
   b. Push (timestamp, smoothed) to result
5. Return result

**Error Conditions**: None (returns empty Vec for empty data)

**Concurrency**: Read-only access to data, thread-safe

## Invariants

- Z-score thresholds are positive (typically 2.0 to 4.0)
- IQR multipliers are positive (typically 1.5 or 3.0)
- Smoothing factor alpha is in range [0.0, 1.0]
- Confidence levels are in range [0.0, 1.0]
- Anomaly scores are non-negative
- Timestamps are monotonically increasing
- Change points are in valid index range
- Forecast horizon is positive

## Dependencies

- **Uses**: Time-series aggregation types, Statistical functions
- **Used by**: Monitoring systems, alerting systems, analytics dashboards

## Rust Implementation Guidance

### Module Structure

The trend analysis and anomaly detection module should be organized as follows:

```
northstar-core/src/anomaly/
  mod.rs              - Public API exports
  types.rs            - Core type definitions
  trend.rs            - Trend analysis functions
  statistical.rs      - Statistical computations
  zscore.rs           - Z-score based detection
  iqr.rs              - IQR based detection
  moving_avg.rs       - Moving average detection
  exp_smooth.rs       - Exponential smoothing detection
  seasonality.rs      - Seasonality detection
  forecast.rs         - Forecasting functions
  model.rs            - Baseline model training
  alert.rs            - Alert rule evaluation
  collective.rs       - Collective anomaly detection
  changepoint.rs      - Change point detection
```

### Type Definitions

- **TrendDirection**: Enum with Upward, Downward, Stationary, Volatile variants
- **TrendAnalysis**: Struct with direction, slope, intercept, r_squared, confidence
- **Anomaly**: Struct with anomaly_id, type, severity, timestamp, value, score, confidence
- **AnomalyDetectionResult**: Struct with anomalies Vec, baseline model, metadata
- **BaselineModel**: Struct with model_type, parameters HashMap, accuracy
- **DetectionConfig**: Struct with sensitivity, thresholds, window sizes

### Key Implementation Patterns

1. **Statistical Functions**: Use robust algorithms (Welford's online algorithm for variance)
2. **Model Storage**: Use HashMap<String, f64> for flexible parameter storage
3. **Anomaly Scoring**: Support multiple scoring methods via enum dispatch
4. **Alert Evaluation**: Match on AlertCondition for declarative rule evaluation
5. **Seasonality Detection**: Use FFT or autocorrelation for period detection

### Concurrency Model

- **Stateless**: All functions are pure transformations of input data
- **Thread-Safe**: Read-only access to input data, immutable output
- **Parallelizable**: Independent anomaly detection methods can run in parallel
- **Model Training**: May be CPU-intensive, consider parallel training for ML models

### Performance Considerations

1. **Statistical Computations**: Use online algorithms where possible (O(n) single pass)
2. **Moving Windows**: Maintain running sums/counts to avoid recomputation
3. **Model Training**: Cache trained models for reuse
4. **Alert Evaluation**: Short-circuit on first matching condition
5. **Large Datasets**: Consider sampling or downsampling for initial anomaly detection

### Key Decisions

- **Statistical Library**: Implement core statistics in pure Rust (avoid heavy dependencies)
- **ML Models**: Use `linfa` crate for ML algorithms (isolation forest, SVM)
- **FFT**: Use `rustfft` crate for seasonality detection
- **Time-series**: Use `timeseries` crate or implement custom ARIMA
- **Optimization**: Use `ndarray` for efficient numerical computations

### External Dependencies

- **ndarray**: For efficient array operations and numerical computations
- **linfa**: For machine learning algorithms (optional, for ML-based detection)
- **rustfft**: For FFT-based seasonality detection (optional)
- **statrs**: For statistical distributions and tests (optional)

### Testing Strategy

**Unit tests for**:
- Trend analysis accuracy on synthetic data with known trends
- Z-score detection with synthetic anomalies
- IQR detection with synthetic outliers
- Moving average baseline accuracy
- Statistical summary correctness

**Property tests for**:
- Statistical summary invariants (min <= median <= max)
- Anomaly score non-negativity
- Confidence value bounds [0.0, 1.0]
- Monotonicity preservation in smoothing

**Integration scenarios**:
- Complete anomaly detection pipeline on real data
- Multi-method comparison (z-score, IQR, moving average)
- Alert rule evaluation with various conditions
- Model training and detection workflow

**Performance benchmarks**:
- Z-score computation throughput (points per second)
- Moving average computation for various window sizes
- Seasonality detection latency
- ML model training time vs data size

### Error Handling

- `InsufficientData`: When data is too short for operation
- `ModelIncompatible`: When model type doesn't match data requirements
- `InvalidParameter`: When parameters are out of valid range
- `ComputationError`: When numerical computation fails (e.g., division by zero)

Use `thiserror` crate for error types with derive macros.

### Implementation Notes

1. Use `derive(Debug, Clone, PartialEq)` for all public types
2. Implement `Display` for AnomalyType and AnomalySeverity
3. Add builder pattern for DetectionConfig for fluent construction
4. Use `Arc<str>` for string deduplication in anomaly_id fields
5. Consider using `rayon` for parallel processing of large datasets
6. Implement custom serializers for timestamp formatting

### Numerical Stability

1. Use Welford's online algorithm for variance computation
2. Handle edge cases (empty data, single point, constant values)
3. Use robust statistical methods (median instead of mean for skewed data)
4. Add epsilon comparisons for floating point equality
5. Handle NaN and infinity values gracefully

### ML Model Considerations

1. **Isolation Forest**: Use for high-dimensional anomaly detection
2. **One-Class SVM**: Use when training data is predominantly normal
3. **Autoencoder**: Use for complex patterns, requires neural network runtime
4. **ARIMA**: Use for time-series with trend and seasonality
5. **Prophet**: Use for business time-series with seasonality and holidays

### Alert Integration

1. **Notification Channels**: Email, Slack, PagerDuty, webhook
2. **Alert Deduplication**: Prevent alert spam with cooldown periods
3. **Alert Aggregation**: Group related anomalies into single alert
4. **Severity Escalation**: Automatically escalate unacknowledged alerts
5. **Alert History**: Maintain audit trail of all alerts

### Production Considerations

1. **Model Retraining**: Periodically retrain baseline models on recent data
2. **Concept Drift**: Detect when data distribution changes significantly
3. **False Positive Rate**: Monitor and tune sensitivity to maintain acceptable rate
4. **Performance**: Anomaly detection must complete within time budget
5. **Scalability**: Handle high-volume time-series data efficiently
