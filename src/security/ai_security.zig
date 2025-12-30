//! AI security and privacy controls for LLM operations
//!
//! Provides comprehensive security controls for AI intelligence layer:
//! - PII redaction and data sanitization
//! - Access control for AI features
//! - Credential management and secure storage
//! - Rate limiting and abuse prevention
//! - Audit logging for security events
//! - Data governance and compliance

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const auth = crypto.auth;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

/// Security level for AI operations
pub const SecurityLevel = enum {
    /// No security (development/testing only)
    none,
    /// Basic sanitization only
    basic,
    /// Standard production security
    standard,
    /// High security (PII, sensitive data)
    high,
    /// Maximum security (regulated industries)
    maximum,
};

/// Data sensitivity classification
pub const SensitivityLevel = enum {
    public,
    internal,
    confidential,
    restricted,
    critical,
};

/// Security event type for audit logging
pub const SecurityEventType = enum {
    pii_redacted,
    access_blocked,
    rate_limit_exceeded,
    credential_invalid,
    sensitive_operation,
    data_export,
    configuration_change,
    authentication,
    authorization,
};

/// AI security manager
pub const AISecurityManager = struct {
    allocator: std.mem.Allocator,
    config: SecurityConfig,
    state: SecurityState,
    pii_detector: *PIIDetector,
    access_control: *AccessControl,
    rate_limiter: *RateLimiter,
    audit_log: *AuditLog,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        config: SecurityConfig,
        pii_detector: *PIIDetector,
        access_control: *AccessControl,
        rate_limiter: *RateLimiter,
        audit_log: *AuditLog
    ) Self {
        const state = SecurityState{
            .active_sessions = std.StringHashMap(Session).init(allocator),
            .blocked_entities = std.StringHashMap(BlockedEntity).init(allocator),
            .security_events = std.ArrayList(SecurityEvent).initCapacity(allocator, 100) catch unreachable,
            .stats = SecurityStatistics{},
        };

        return .{
            .allocator = allocator,
            .config = config,
            .state = state,
            .pii_detector = pii_detector,
            .access_control = access_control,
            .rate_limiter = rate_limiter,
            .audit_log = audit_log,
        };
    }

    pub fn deinit(self: *Self) void {
        var session_it = self.state.active_sessions.iterator();
        while (session_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.state.active_sessions.deinit();

        var blocked_it = self.state.blocked_entities.iterator();
        while (blocked_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.state.blocked_entities.deinit();

        for (self.state.security_events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.state.security_events.deinit(self.allocator);
    }

    /// Sanitize data before sending to LLM
    pub fn sanitizeForLLM(self: *Self, data: []const u8, context: SanitizeContext) !SanitizedData {
        // Check access first
        if (!try self.access_control.checkAccess(self.allocator, context.user_id, .ai_query)) {
            try self.logSecurityEvent(.access_blocked, "Unauthorized AI query attempt", context.user_id);
            return error.AccessDenied;
        }

        // Check rate limits
        if (!try self.rate_limiter.checkLimit(self.allocator, context.user_id, .llm_request)) {
            try self.logSecurityEvent(.rate_limit_exceeded, "LLM rate limit exceeded", context.user_id);
            return error.RateLimitExceeded;
        }

        // Apply PII redaction if enabled
        var redacted_data = data;
        var pii_count: usize = 0;
        var redaction_list = std.ArrayList(PIIInstance).initCapacity(self.allocator, 10) catch unreachable;
        defer {
            for (redaction_list.items) |*r| r.deinit(self.allocator);
            redaction_list.deinit(self.allocator);
        }

        if (self.config.pii_redaction_enabled) {
            const redaction_result = try self.pii_detector.redact(self.allocator, data, .{ .required_level = .basic, .destination = .external });
            defer {
                // Only free the slice itself, instances are transferred to redaction_list
                self.allocator.free(redaction_result.instances);
            }
            redacted_data = redaction_result.redacted_data;
            pii_count = redaction_result.pii_count;

            // Transfer instances to redaction_list
            for (redaction_result.instances) |item| {
                try redaction_list.append(self.allocator, item);
            }

            if (pii_count > 0) {
                try self.logSecurityEvent(.pii_redacted, try std.fmt.allocPrint(self.allocator, "Redacted {} PII instances", .{pii_count}), context.user_id);
            }
        }

        // Apply custom filters
        if (self.config.custom_filters.len > 0) {
            redacted_data = try self.applyCustomFilters(redacted_data);
        }

        // Check size limits
        if (redacted_data.len > self.config.max_data_size) {
            return error.DataTooLarge;
        }

        return SanitizedData{
            .sanitized_data = try self.allocator.dupe(u8, redacted_data),
            .pii_count = pii_count,
            .sensitivity_level = try self.classifySensitivity(redacted_data),
            .requires_review = pii_count > self.config.pii_review_threshold,
        };
    }

    /// Validate response from LLM for security issues
    pub fn validateLLMResponse(self: *Self, response: []const u8, context: SanitizeContext) !ValidationResult {
        var issues = std.ArrayList(SecurityIssue).initCapacity(self.allocator, 10) catch unreachable;
        defer {
            for (issues.items) |*i| i.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        // Check for prompt injection patterns
        const injection_patterns = [_][]const u8{
            "ignore previous instructions",
            "disregard all above",
            "forget everything",
            "new instructions:",
            "system override",
        };

        const lower_response = try self.allocator.alloc(u8, response.len);
        defer self.allocator.free(lower_response);
        for (response, 0..) |c, i| {
            lower_response[i] = std.ascii.toLower(c);
        }

        for (injection_patterns) |pattern| {
            if (mem.indexOf(u8, lower_response, pattern) != null) {
                try issues.append(self.allocator, .{
                    .issue_type = .prompt_injection,
                    .description = try self.allocator.dupe(u8, "Possible prompt injection pattern detected"),
                    .severity = .high,
                });
            }
        }

        // Check for credential leakage
        if (try self.detectCredentialLeakage(response)) {
            try issues.append(self.allocator, .{
                .issue_type = .credential_leakage,
                .description = try self.allocator.dupe(u8, "Possible credential pattern detected"),
                .severity = .critical,
            });
        }

        // Check for malicious code patterns
        if (try self.detectMaliciousCode(response)) {
            try issues.append(self.allocator, .{
                .issue_type = .malicious_code,
                .description = try self.allocator.dupe(u8, "Possible malicious code pattern detected"),
                .severity = .high,
            });
        }

        // Determine if response is safe
        const is_safe = issues.items.len == 0 or
            (self.config.allow_risky_responses and
             !hasCriticalIssue(&issues));

        if (!is_safe) {
            try self.logSecurityEvent(.sensitive_operation, "LLM response validation failed", context.user_id);
        }

        return ValidationResult{
            .is_safe = is_safe,
            .security_issues = try issues.toOwnedSlice(self.allocator),
            .confidence = if (issues.items.len == 0) 1.0 else 0.0,
        };
    }

    /// Create secure session for AI operations
    pub fn createSession(self: *Self, user_id: []const u8, permissions: []const Permission) !SessionToken {
        const token = try self.generateSessionToken();

        const session = Session{
            .token = try self.allocator.dupe(u8, token),
            .user_id = try self.allocator.dupe(u8, user_id),
            .created_at = std.time.nanoTimestamp(),
            .expires_at = std.time.nanoTimestamp() + (self.config.session_timeout_ns),
            .permissions = try self.allocator.dupe(Permission, permissions),
            .operation_count = 0,
        };

        try self.state.active_sessions.put(try self.allocator.dupe(u8, token), session);

        try self.logSecurityEvent(.authentication, "AI security session created", user_id);

        return SessionToken{ .token = token };
    }

    /// Validate and refresh session
    pub fn validateSession(self: *Self, token: []const u8) !?*Session {
        const session = self.state.active_sessions.get(token) orelse return null;

        const now = std.time.nanoTimestamp();
        if (now > session.expires_at) {
            // Session expired
            const old_session = self.state.active_sessions.fetchRemove(token).?;
            old_session.value.deinit(self.allocator);
            return null;
        }

        // Refresh session
        session.expires_at = now + (self.config.session_timeout_ns);
        session.operation_count += 1;

        return session;
    }

    /// Block entity from AI operations
    pub fn blockEntity(self: *Self, entity_id: []const u8, reason: []const u8, duration_ns: i128) !void {
        const blocked = BlockedEntity{
            .entity_id = try self.allocator.dupe(u8, entity_id),
            .blocked_at = std.time.nanoTimestamp(),
            .expires_at = std.time.nanoTimestamp() + duration_ns,
            .reason = try self.allocator.dupe(u8, reason),
        };

        try self.state.blocked_entities.put(try self.allocator.dupe(u8, entity_id), blocked);

        try self.logSecurityEvent(.access_blocked, try std.fmt.allocPrint(self.allocator, "Blocked entity: {s}", .{reason}), entity_id);
    }

    /// Check if entity is blocked
    pub fn isEntityBlocked(self: *const Self, entity_id: []const u8) bool {
        const blocked = self.state.blocked_entities.get(entity_id) orelse return false;

        const now = std.time.nanoTimestamp();
        if (now > blocked.expires_at) {
            // Block expired, but cleanup happens elsewhere
            return false;
        }

        return true;
    }

    /// Get security statistics
    pub fn getStatistics(self: *const Self) SecurityStatistics {
        return self.state.stats;
    }

    /// Export security events for audit
    pub fn exportSecurityEvents(self: *Self, start_time: i128, end_time: i128) ![]SecurityEvent {
        var events = std.array_list.Managed(SecurityEvent).init(self.allocator);

        for (self.state.security_events.items) |event| {
            if (event.timestamp >= start_time and event.timestamp <= end_time) {
                const event_copy = try event.clone(self.allocator);
                try events.append(event_copy);
            }
        }

        return events.toOwnedSlice(self.allocator);
    }

    fn logSecurityEvent(self: *Self, event_type: SecurityEventType, message: []const u8, entity_id: []const u8) !void {
        const event = SecurityEvent{
            .event_type = event_type,
            .timestamp = std.time.nanoTimestamp(),
            .entity_id = try self.allocator.dupe(u8, entity_id),
            .message = try self.allocator.dupe(u8, message),
            .severity = self.getSeverityForEvent(event_type),
        };

        try self.state.security_events.append(self.allocator, event);
        try self.audit_log.logEvent(self.allocator, event);

        // Trim events if needed
        if (self.state.security_events.items.len > self.config.max_security_events) {
            const removed = self.state.security_events.orderedRemove(0);
            removed.deinit(self.allocator);
        }

        // Update stats
        switch (event_type) {
            .pii_redacted => self.state.stats.pii_redactions += 1,
            .access_blocked => self.state.stats.access_denials += 1,
            .rate_limit_exceeded => self.state.stats.rate_limit_hits += 1,
            else => {},
        }
    }

    fn getSeverityForEvent(self: *Self, event_type: SecurityEventType) EventSeverity {
        _ = self;
        return switch (event_type) {
            .access_blocked, .credential_invalid => .critical,
            .rate_limit_exceeded => .warning,
            .pii_redacted => .info,
            .sensitive_operation => .high,
            .data_export, .configuration_change => .medium,
            .authentication, .authorization => .low,
        };
    }

    fn classifySensitivity(self: *Self, data: []const u8) !SensitivityLevel {

        // Check for keywords indicating sensitivity
        const sensitive_keywords = [_]struct { []const u8, SensitivityLevel }{
            .{ "password", .restricted },
            .{ "api key", .restricted },
            .{ "secret", .restricted },
            .{ "confidential", .confidential },
            .{ "internal only", .internal },
        };

        const lower_data = try self.allocator.alloc(u8, data.len);
        defer self.allocator.free(lower_data);
        for (data, 0..) |c, i| {
            lower_data[i] = std.ascii.toLower(c);
        }

        var max_level = SensitivityLevel.public;

        for (sensitive_keywords) |keyword_info| {
            if (mem.indexOf(u8, lower_data, keyword_info[0]) != null) {
                if (@intFromEnum(keyword_info[1]) > @intFromEnum(max_level)) {
                    max_level = keyword_info[1];
                }
            }
        }

        return max_level;
    }

    fn applyCustomFilters(self: *Self, data: []const u8) ![]const u8 {
        var filtered: []const u8 = try self.allocator.dupe(u8, data);

        for (self.config.custom_filters) |filter| {
            if (filter.enabled) {
                const new_filtered = try self.applyFilter(filtered, filter);
                self.allocator.free(filtered);
                filtered = new_filtered;
            }
        }

        return filtered;
    }

    fn applyFilter(self: *Self, data: []const u8, filter: CustomFilter) ![]const u8 {

        // Simple pattern replacement
        var result = data;
        if (filter.pattern) |pattern| {
            if (filter.replacement) |replacement| {
                // Simple find and replace (would use regex in production)
                result = if (mem.indexOf(u8, result, pattern)) |idx|
                    try self.replaceString(result, idx, idx + pattern.len, replacement)
                else
                    result;
            }
        }

        return try self.allocator.dupe(u8, result);
    }

    fn replaceString(self: *Self, original: []const u8, start: usize, end: usize, replacement: []const u8) ![]const u8 {
        const new_len = original.len - (end - start) + replacement.len;
        const result = try self.allocator.alloc(u8, new_len);

        @memcpy(result[0..start], original[0..start]);
        @memcpy(result[start..start + replacement.len], replacement);
        @memcpy(result[start + replacement.len..], original[end..]);

        return result;
    }

    fn generateSessionToken(self: *Self) ![]const u8 {
        // Generate 16 cryptographically secure random bytes (128-bit entropy)
        // Encoded as hex for a 32-character token
        const random_bytes_len = 16;
        const token_len = 32; // hex encoding doubles the length

        var random_bytes: [random_bytes_len]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        const token = try self.allocator.alloc(u8, token_len);

        // Encode as hex
        const hex_chars = "0123456789abcdef";
        for (random_bytes, 0..) |byte, i| {
            token[i * 2] = hex_chars[byte >> 4];
            token[i * 2 + 1] = hex_chars[byte & 0x0f];
        }

        return token;
    }

    fn detectCredentialLeakage(self: *Self, data: []const u8) !bool {
        _ = self;

        const credential_patterns = [_][]const u8{
            "sk-",      // OpenAI secret keys
            "AIza",     // Google API keys
            "AKIA",     // AWS access keys
            "Bearer ",  // Bearer tokens
        };

        for (credential_patterns) |pattern| {
            if (mem.indexOf(u8, data, pattern) != null) {
                return true;
            }
        }

        return false;
    }

    fn detectMaliciousCode(self: *Self, data: []const u8) !bool {
        _ = self;

        const malicious_patterns = [_][]const u8{
            "eval(",
            "exec(",
            "system(",
            "__import__",
            "Runtime.exec",
        };

        for (malicious_patterns) |pattern| {
            if (mem.indexOf(u8, data, pattern) != null) {
                return true;
            }
        }

        return false;
    }
};

fn hasCriticalIssue(issues: *const std.ArrayList(SecurityIssue)) bool {
    for (issues.items) |issue| {
        if (issue.severity == .critical) {
            return true;
        }
    }
    return false;
}

/// Security configuration
pub const SecurityConfig = struct {
    security_level: SecurityLevel = .standard,
    pii_redaction_enabled: bool = true,
    allow_risky_responses: bool = false,
    max_data_size: usize = 100_000, // 100KB default
    pii_review_threshold: usize = 3,
    session_timeout_ns: i128 = 1_000_000_000 * 60 * 30, // 30 minutes
    max_security_events: usize = 10_000,
    custom_filters: []const CustomFilter = &.{},
};

/// Custom filter for data sanitization
pub const CustomFilter = struct {
    name: []const u8,
    pattern: ?[]const u8,
    replacement: ?[]const u8,
    enabled: bool = true,
};

/// Security state
pub const SecurityState = struct {
    active_sessions: std.StringHashMap(Session),
    blocked_entities: std.StringHashMap(BlockedEntity),
    security_events: std.ArrayList(SecurityEvent),
    stats: SecurityStatistics,
};

/// Session for authenticated AI operations
pub const Session = struct {
    token: []const u8,
    user_id: []const u8,
    created_at: i128,
    expires_at: i128,
    permissions: []const Permission,
    operation_count: u64,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.user_id);
        allocator.free(self.permissions);
    }
};

/// Session token
pub const SessionToken = struct {
    token: []const u8,
};

/// Permission for AI operations
pub const Permission = enum {
    ai_query,
    data_export,
    configuration_change,
    admin_access,
    view_analytics,
};

/// Blocked entity
pub const BlockedEntity = struct {
    entity_id: []const u8,
    blocked_at: i128,
    expires_at: i128,
    reason: []const u8,

    pub fn deinit(self: *BlockedEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
        allocator.free(self.reason);
    }
};

/// Security event
pub const SecurityEvent = struct {
    event_type: SecurityEventType,
    timestamp: i128,
    entity_id: []const u8,
    message: []const u8,
    severity: EventSeverity,

    pub fn deinit(self: *const SecurityEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
        allocator.free(self.message);
    }

    pub fn clone(self: *const SecurityEvent, allocator: std.mem.Allocator) !SecurityEvent {
        return .{
            .event_type = self.event_type,
            .timestamp = self.timestamp,
            .entity_id = try allocator.dupe(u8, self.entity_id),
            .message = try allocator.dupe(u8, self.message),
            .severity = self.severity,
        };
    }
};

/// Event severity
pub const EventSeverity = enum {
    info,
    low,
    medium,
    high,
    warning,
    critical,
};

/// Security statistics
pub const SecurityStatistics = struct {
    pii_redactions: u64 = 0,
    access_denials: u64 = 0,
    rate_limit_hits: u64 = 0,
    active_sessions: u64 = 0,
    blocked_entities: u64 = 0,
};

/// Sanitization context
pub const SanitizeContext = struct {
    user_id: []const u8,
    operation_type: []const u8,
    metadata: ?[]const u8 = null,
};

/// Sanitized data result
pub const SanitizedData = struct {
    sanitized_data: []const u8,
    pii_count: usize,
    sensitivity_level: SensitivityLevel,
    requires_review: bool,

    pub fn deinit(self: *const SanitizedData, allocator: std.mem.Allocator) void {
        allocator.free(self.sanitized_data);
    }
};

/// Validation result
pub const ValidationResult = struct {
    is_safe: bool,
    security_issues: []const SecurityIssue,
    confidence: f32,

    pub fn deinit(self: *const ValidationResult, allocator: std.mem.Allocator) void {
        for (self.security_issues) |*i| i.deinit(allocator);
        allocator.free(self.security_issues);
    }
};

/// Security issue
pub const SecurityIssue = struct {
    issue_type: IssueType,
    description: []const u8,
    severity: IssueSeverity,

    pub fn deinit(self: *const SecurityIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
    }

    pub const IssueType = enum {
        prompt_injection,
        credential_leakage,
        malicious_code,
        data_exfiltration,
        unauthorized_access,
    };
};

/// Issue severity
pub const IssueSeverity = enum {
    low,
    medium,
    high,
    critical,
};

// ==================== PII Detection ====================

/// PII detector for identifying and redacting sensitive information
pub const PIIDetector = struct {
    allocator: std.mem.Allocator,
    patterns: []const PIIPattern,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, patterns: []const PIIPattern) Self {
        return .{
            .allocator = allocator,
            .patterns = patterns,
        };
    }

    pub fn redact(self: *Self, allocator: std.mem.Allocator, data: []const u8, context: PIIRedactionContext) !RedactionResult {
        var instances = std.ArrayList(PIIInstance).initCapacity(allocator, 10) catch unreachable;
        errdefer {
            for (instances.items) |*i| i.deinit(allocator);
            instances.deinit(allocator);
        }

        var redacted = try allocator.alloc(u8, data.len);
        @memcpy(redacted, data);

        for (self.patterns) |pattern| {
            if (!pattern.enabled_for_context(context)) continue;

            var start: usize = 0;
            while (mem.indexOfPos(u8, data, start, pattern.pattern)) |idx| {
                try instances.append(allocator, .{
                    .pattern_type = pattern.pattern_type,
                    .start = idx,
                    .end = idx + pattern.pattern.len,
                    .original_text = try allocator.dupe(u8, data[idx..idx + pattern.pattern.len]),
                });

                // Redact
                const redaction_str = pattern.redaction_template orelse "[REDACTED]";
                if (idx + redaction_str.len <= redacted.len) {
                    @memcpy(redacted[idx..idx + redaction_str.len], redaction_str);
                }

                start = idx + 1;
            }
        }

        return RedactionResult{
            .redacted_data = redacted,
            .pii_count = instances.items.len,
            .instances = try instances.toOwnedSlice(allocator),
        };
    }
};

/// PII pattern
pub const PIIPattern = struct {
    pattern_type: PIIType,
    pattern: []const u8,
    redaction_template: ?[]const u8 = null,
    min_context: SecurityLevel = .basic,

    pub fn enabled_for_context(self: *const PIIPattern, context: PIIRedactionContext) bool {
        return @intFromEnum(context.required_level) >= @intFromEnum(self.min_context);
    }
};

/// PII type
pub const PIIType = enum {
    email_address,
    phone_number,
    ssn,
    credit_card,
    ip_address,
    api_key,
    password,
    secret,
};

/// PII redaction context
pub const PIIRedactionContext = struct {
    required_level: SecurityLevel,
    destination: PIDestination,
};

/// PII destination
pub const PIDestination = enum {
    internal,
    external,
    logs,
};

/// PII instance
pub const PIIInstance = struct {
    pattern_type: PIIType,
    start: usize,
    end: usize,
    original_text: []const u8,

    pub fn deinit(self: *const PIIInstance, allocator: std.mem.Allocator) void {
        allocator.free(self.original_text);
    }
};

/// Redaction result
pub const RedactionResult = struct {
    redacted_data: []const u8,
    pii_count: usize,
    instances: []const PIIInstance,
};

// ==================== Access Control ====================

/// Access control for AI features
pub const AccessControl = struct {
    allocator: std.mem.Allocator,
    roles: std.StringHashMap(Role),
    policies: std.StringHashMap(Policy),
    user_roles: std.StringHashMap(std.ArrayList([]const u8)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .roles = std.StringHashMap(Role).init(allocator),
            .policies = std.StringHashMap(Policy).init(allocator),
            .user_roles = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var role_it = self.roles.iterator();
        while (role_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.roles.deinit();

        var policy_it = self.policies.iterator();
        while (policy_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.policies.deinit();

        var user_role_it = self.user_roles.iterator();
        while (user_role_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |role_name| {
                self.allocator.free(role_name);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.user_roles.deinit();
    }

    /// Check if user has permission based on their roles and policies
    pub fn checkAccess(self: *Self, allocator: std.mem.Allocator, user_id: []const u8, permission: Permission) !bool {
        _ = allocator;

        // Get user's roles
        const user_role_entry = self.user_roles.get(user_id) orelse {
            // No roles assigned = no access
            return false;
        };

        // Collect all permissions from user's roles
        var user_permissions = std.ArrayList(Permission).initCapacity(self.allocator, 10) catch unreachable;
        defer user_permissions.deinit(self.allocator);

        for (user_role_entry.items) |role_name| {
            if (self.roles.get(role_name)) |role| {
                for (role.permissions) |perm| {
                    // Add permission if not already present
                    var already_has = false;
                    for (user_permissions.items) |existing| {
                        if (existing == perm) {
                            already_has = true;
                            break;
                        }
                    }
                    if (!already_has) {
                        try user_permissions.append(self.allocator, perm);
                    }
                }
            }
        }

        // Check if user has the required permission
        var has_permission = false;
        for (user_permissions.items) |perm| {
            if (perm == permission) {
                has_permission = true;
                break;
            }
        }

        if (!has_permission) {
            return false;
        }

        // Evaluate policies (deny takes precedence)
        var policy_it = self.policies.iterator();
        while (policy_it.next()) |entry| {
            const policy = entry.value_ptr.*;
            // Check if policy applies to this permission
            const policy_applies = for (policy.permissions) |policy_perm| {
                if (policy_perm == permission) {
                    break true;
                }
            } else false;

            if (policy_applies) {
                // For now, apply policy if permission matches
                // TODO: Check policy conditions against user context
                if (policy.effect == .deny) {
                    return false;
                }
            }
        }

        return true;
    }

    /// Assign a role to a user
    pub fn assignRole(self: *Self, user_id: []const u8, role_name: []const u8) !void {
        const role_entry = try self.user_roles.getOrPut(user_id);
        if (!role_entry.found_existing) {
            role_entry.key_ptr.* = try self.allocator.dupe(u8, user_id);
            role_entry.value_ptr.* = std.ArrayList([]const u8).initCapacity(self.allocator, 5) catch unreachable;
        }

        // Check if user already has this role
        for (role_entry.value_ptr.items) |existing_role| {
            if (std.mem.eql(u8, existing_role, role_name)) {
                return; // Already has role
            }
        }

        // Add role
        try role_entry.value_ptr.append(self.allocator, try self.allocator.dupe(u8, role_name));
    }

    /// Revoke a role from a user
    pub fn revokeRole(self: *Self, user_id: []const u8, role_name: []const u8) !void {
        const user_role_entry_ptr = self.user_roles.getPtr(user_id) orelse {
            return; // No roles to revoke
        };

        // Find and remove the role
        for (user_role_entry_ptr.items, 0..) |existing_role, i| {
            if (std.mem.eql(u8, existing_role, role_name)) {
                const removed = user_role_entry_ptr.orderedRemove(i);
                self.allocator.free(removed);
                return;
            }
        }
    }

    /// Get all permissions for a user
    pub fn getUserPermissions(self: *Self, user_id: []const u8) !std.ArrayList(Permission) {
        var permissions = std.ArrayList(Permission).initCapacity(self.allocator, 10) catch unreachable;

        const user_role_entry = self.user_roles.get(user_id) orelse {
            return permissions;
        };

        for (user_role_entry.items) |role_name| {
            if (self.roles.get(role_name)) |role| {
                for (role.permissions) |perm| {
                    // Add permission if not already present
                    var already_has = false;
                    for (permissions.items) |existing| {
                        if (existing == perm) {
                            already_has = true;
                            break;
                        }
                    }
                    if (!already_has) {
                        try permissions.append(self.allocator, perm);
                    }
                }
            }
        }

        return permissions;
    }

    pub fn addRole(self: *Self, name: []const u8, permissions: []const Permission) !void {
        const role = try Role.init(self.allocator, permissions);
        try self.roles.put(try self.allocator.dupe(u8, name), role);
    }

    pub fn addPolicy(self: *Self, name: []const u8, effect: PolicyEffect, permissions: []const Permission, conditions: []const PolicyCondition) !void {
        const policy = try Policy.init(self.allocator, name, effect, permissions, conditions);
        try self.policies.put(try self.allocator.dupe(u8, name), policy);
    }
};

/// Role for access control
pub const Role = struct {
    permissions: []const Permission,

    pub fn init(allocator: std.mem.Allocator, permissions: []const Permission) !Role {
        const perms = try allocator.dupe(Permission, permissions);
        return .{
            .permissions = perms,
        };
    }

    pub fn deinit(self: *Role, allocator: std.mem.Allocator) void {
        allocator.free(self.permissions);
    }
};

/// Access policy
pub const Policy = struct {
    name: []const u8,
    effect: PolicyEffect,
    permissions: []const Permission,
    conditions: []const PolicyCondition,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, effect: PolicyEffect, permissions: []const Permission, conditions: []const PolicyCondition) !Policy {
        return .{
            .name = try allocator.dupe(u8, name),
            .effect = effect,
            .permissions = try allocator.dupe(Permission, permissions),
            .conditions = try allocator.dupe(PolicyCondition, conditions),
        };
    }

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.permissions);
        allocator.free(self.conditions);
    }
};

/// Policy effect
pub const PolicyEffect = enum {
    allow,
    deny,
};

/// Policy condition
pub const PolicyCondition = struct {
    field: []const u8,
    operator: []const u8,
    value: []const u8,
};

// ==================== Rate Limiting ====================

/// Rate limiter for AI operations
pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    limits: std.StringHashMap(RateLimit),
    usage: std.StringHashMap(UsageTracker),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .limits = std.StringHashMap(RateLimit).init(allocator),
            .usage = std.StringHashMap(UsageTracker).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var limit_it = self.limits.iterator();
        while (limit_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.limits.deinit();

        var usage_it = self.usage.iterator();
        while (usage_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.usage.deinit();
    }

    pub fn checkLimit(self: *Self, allocator: std.mem.Allocator, entity_id: []const u8, operation: RateLimitedOperation) !bool {
        _ = allocator;

        const now = std.time.nanoTimestamp();
        const key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ entity_id, @tagName(operation) });
        defer self.allocator.free(key);

        const gop = try self.usage.getOrPut(key);
        if (!gop.found_existing) {
            // The hashmap stores its own copy of the key
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            gop.value_ptr.* = UsageTracker{
                .count = 0,
                .window_start = now,
                .window_duration = 60_000_000_000, // 1 minute
            };
        }

        // Check if window expired
        if (now - gop.value_ptr.window_start > gop.value_ptr.window_duration) {
            gop.value_ptr.count = 0;
            gop.value_ptr.window_start = now;
        }

        // Check limit
        const limit = self.limits.get("default") orelse return true;
        if (gop.value_ptr.count >= limit.requests_per_window) {
            return false;
        }

        gop.value_ptr.count += 1;
        return true;
    }

    pub fn setLimit(self: *Self, name: []const u8, limit: RateLimit) !void {
        try self.limits.put(try self.allocator.dupe(u8, name), limit);
    }
};

/// Rate limit
pub const RateLimit = struct {
    requests_per_window: u64,
    window_duration_ns: i128,
};

/// Usage tracker
pub const UsageTracker = struct {
    count: u64,
    window_start: i128,
    window_duration: i128,

    pub fn deinit(self: *UsageTracker, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Rate limited operation
pub const RateLimitedOperation = enum {
    llm_request,
    ai_query,
    data_export,
    admin_operation,
};

// ==================== Audit Logging ====================

/// Audit log for security events
pub const AuditLog = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(AuditEntry),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .events = std.ArrayList(AuditEntry).initCapacity(allocator, 100) catch unreachable,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
    }

    pub fn logEvent(self: *Self, allocator: std.mem.Allocator, event: SecurityEvent) !void {
        // AuditEntry makes copies of the data to avoid ownership issues
        const entry = AuditEntry{
            .event_type = event.event_type,
            .timestamp = event.timestamp,
            .entity_id = try allocator.dupe(u8, event.entity_id),
            .message = try allocator.dupe(u8, event.message),
            .severity = event.severity,
        };

        try self.events.append(self.allocator, entry);
    }

    pub fn query(self: *Self, filter: AuditFilter) ![]AuditEntry {
        var results = std.ArrayList(AuditEntry).initCapacity(self.allocator, 10) catch unreachable;

        for (self.events.items) |entry| {
            if (filter.matches(entry)) {
                const entry_copy = try entry.clone(self.allocator);
                try results.append(self.allocator, entry_copy);
            }
        }

        return results.toOwnedSlice(self.allocator);
    }
};

/// Audit entry
pub const AuditEntry = struct {
    event_type: SecurityEventType,
    timestamp: i128,
    entity_id: []const u8,
    message: []const u8,
    severity: EventSeverity,

    pub fn deinit(self: *AuditEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
        allocator.free(self.message);
    }

    pub fn clone(self: *const AuditEntry, allocator: std.mem.Allocator) !AuditEntry {
        return .{
            .event_type = self.event_type,
            .timestamp = self.timestamp,
            .entity_id = try allocator.dupe(u8, self.entity_id),
            .message = try allocator.dupe(u8, self.message),
            .severity = self.severity,
        };
    }
};

/// Audit filter
pub const AuditFilter = struct {
    event_type: ?SecurityEventType = null,
    start_time: ?i128 = null,
    end_time: ?i128 = null,
    entity_id: ?[]const u8 = null,
    min_severity: ?EventSeverity = null,

    pub fn matches(self: *const AuditFilter, entry: AuditEntry) bool {
        if (self.event_type) |et| {
            if (entry.event_type != et) return false;
        }
        if (self.start_time) |st| {
            if (entry.timestamp < st) return false;
        }
        if (self.end_time) |et| {
            if (entry.timestamp > et) return false;
        }
        if (self.min_severity) |ms| {
            if (@intFromEnum(entry.severity) < @intFromEnum(ms)) return false;
        }
        return true;
    }

    pub fn deinit(self: *const AuditFilter, allocator: std.mem.Allocator) void {
        if (self.entity_id) |id| allocator.free(id);
    }
};

// ==================== Credential Management ====================

/// Credential manager for secure API key storage
pub const CredentialManager = struct {
    allocator: std.mem.Allocator,
    credentials: std.StringHashMap(StoredCredential),
    encryption_key: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, encryption_key: []const u8) Self {
        return .{
            .allocator = allocator,
            .credentials = std.StringHashMap(StoredCredential).init(allocator),
            .encryption_key = encryption_key,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.credentials.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.credentials.deinit();
    }

    pub fn storeCredential(self: *Self, name: []const u8, value: []const u8, cred_type: CredentialType) !void {
        const encrypted = try self.encrypt(value);

        const credential = StoredCredential{
            .encrypted_value = encrypted,
            .cred_type = cred_type,
            .created_at = std.time.nanoTimestamp(),
            .last_used = null,
        };

        try self.credentials.put(try self.allocator.dupe(u8, name), credential);
    }

    pub fn getCredential(self: *Self, name: []const u8) !?[]const u8 {
        const stored = self.credentials.get(name) orelse return null;

        const decrypted = try self.decrypt(stored.encrypted_value);

        // Update last used (would need mutable access in real impl)

        return decrypted;
    }

    pub fn rotateCredential(self: *Self, name: []const u8, new_value: []const u8) !void {
        const old_entry = self.credentials.fetchRemove(name) orelse return error.CredentialNotFound;
        old_entry.value.deinit(self.allocator);

        const cred_type = CredentialType.api_key; // Would preserve old type
        try self.storeCredential(name, new_value, cred_type);
    }

    fn encrypt(self: *Self, data: []const u8) ![]const u8 {
        // AES-256-GCM encryption with proper key derivation
        // Derive 256-bit key from encryption_key using PBKDF2
        const key_len = 32; // 256 bits for AES-256
        const derived_key = try self.deriveKey(self.encryption_key, key_len);
        defer self.allocator.free(derived_key);

        // Generate random nonce (96 bits for GCM)
        var nonce_array: [12]u8 = undefined;
        std.crypto.random.bytes(&nonce_array);

        // AES-256-GCM: ciphertext = nonce || ciphertext || tag
        const tag_len = 16; // 128-bit auth tag
        const nonce_len = 12;
        const cipher_result = try self.allocator.alloc(u8, nonce_len + data.len + tag_len);
        errdefer self.allocator.free(cipher_result);

        // Copy nonce to output
        @memcpy(cipher_result[0..nonce_len], &nonce_array);

        // Encrypt with AES-256-GCM
        var key_array: [32]u8 = undefined;
        @memcpy(&key_array, derived_key[0..32]);

        var tag_array: [16]u8 = undefined;
        Aes256Gcm.encrypt(
            cipher_result[nonce_len .. nonce_len + data.len],
            &tag_array,
            data,
            &.{}, // no additional authenticated data
            nonce_array,
            key_array,
        );

        // Append tag
        @memcpy(cipher_result[nonce_len + data.len ..][0..tag_len], &tag_array);

        return cipher_result;
    }

    fn decrypt(self: *Self, data: []const u8) ![]const u8 {
        // AES-256-GCM decryption
        // Format: nonce(12) || ciphertext || tag(16)
        const nonce_len = 12;
        const tag_len = 16;

        if (data.len < nonce_len + tag_len) {
            return error.InvalidCiphertext;
        }

        const ciphertext_len = data.len - nonce_len - tag_len;
        const nonce_bytes = data[0..nonce_len];
        const ciphertext = data[nonce_len .. nonce_len + ciphertext_len];
        const tag_bytes = data[nonce_len + ciphertext_len ..];

        // Derive key
        const key_len = 32;
        const derived_key = try self.deriveKey(self.encryption_key, key_len);
        defer self.allocator.free(derived_key);

        // Decrypt with AES-256-GCM
        var key_array: [32]u8 = undefined;
        @memcpy(&key_array, derived_key[0..32]);

        var nonce_array: [12]u8 = undefined;
        @memcpy(&nonce_array, nonce_bytes[0..12]);

        var tag_array: [16]u8 = undefined;
        @memcpy(&tag_array, tag_bytes[0..16]);

        const result = try self.allocator.alloc(u8, ciphertext_len);
        errdefer self.allocator.free(result);

        Aes256Gcm.decrypt(
            result,
            ciphertext,
            tag_array,
            &.{}, // no additional authenticated data
            nonce_array,
            key_array,
        ) catch {
            return error.DecryptionFailed;
        };

        return result;
    }

    /// Derive cryptographic key from input using PBKDF2-HMAC-SHA256
    fn deriveKey(self: *Self, input: []const u8, len: usize) ![]const u8 {
        // Use PBKDF2 with HMAC-SHA256 to derive a key of specified length
        const salt = "northstar-db-salt-v1"; // In production, should be configurable
        const iterations = 100_000;

        const result = try self.allocator.alloc(u8, len);

        // PBKDF2-HMAC-SHA256 key derivation
        try crypto.pwhash.pbkdf2(result, input, salt, iterations, crypto.auth.hmac.sha2.HmacSha256);

        return result;
    }
};

/// Stored credential
pub const StoredCredential = struct {
    encrypted_value: []const u8,
    cred_type: CredentialType,
    created_at: i128,
    last_used: ?i128,

    pub fn deinit(self: *StoredCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.encrypted_value);
    }
};

/// Credential type
pub const CredentialType = enum {
    api_key,
    oauth_token,
    certificate,
    password,
    secret,
};

// ==================== Tests ====================//

test "AISecurityManager init" {
    var pii_detector = PIIDetector.init(std.testing.allocator, &.{});
    var access_control = AccessControl.init(std.testing.allocator);
    var rate_limiter = RateLimiter.init(std.testing.allocator);
    var audit_log = AuditLog.init(std.testing.allocator);

    var manager = AISecurityManager.init(std.testing.allocator, .{}, &pii_detector, &access_control, &rate_limiter, &audit_log);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.state.active_sessions.count());
}

test "AISecurityManager sanitizeForLLM basic" {
    var pii_detector = PIIDetector.init(std.testing.allocator, &.{});
    var access_control = AccessControl.init(std.testing.allocator);
    defer access_control.deinit();
    var rate_limiter = RateLimiter.init(std.testing.allocator);
    var audit_log = AuditLog.init(std.testing.allocator);

    // Grant test-user the ai_query permission
    try access_control.addRole("user", &.{.ai_query});
    try access_control.assignRole("test-user", "user");

    var manager = AISecurityManager.init(std.testing.allocator, .{
        .pii_redaction_enabled = false,
    }, &pii_detector, &access_control, &rate_limiter, &audit_log);
    defer manager.deinit();

    const context = SanitizeContext{
        .user_id = "test-user",
        .operation_type = "query",
    };

    const result = try manager.sanitizeForLLM("test data", context);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.pii_count);
    try std.testing.expectEqual(SensitivityLevel.public, result.sensitivity_level);
}

test "AISecurityManager validateLLMResponse safe" {
    var pii_detector = PIIDetector.init(std.testing.allocator, &.{});
    var access_control = AccessControl.init(std.testing.allocator);
    var rate_limiter = RateLimiter.init(std.testing.allocator);
    var audit_log = AuditLog.init(std.testing.allocator);

    var manager = AISecurityManager.init(std.testing.allocator, .{}, &pii_detector, &access_control, &rate_limiter, &audit_log);
    defer manager.deinit();

    const context = SanitizeContext{
        .user_id = "test-user",
        .operation_type = "query",
    };

    const result = try manager.validateLLMResponse("This is a safe response", context);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_safe);
}

test "AISecurityManager createSession" {
    var pii_detector = PIIDetector.init(std.testing.allocator, &.{});
    var access_control = AccessControl.init(std.testing.allocator);
    var rate_limiter = RateLimiter.init(std.testing.allocator);
    var audit_log = AuditLog.init(std.testing.allocator);

    var manager = AISecurityManager.init(std.testing.allocator, .{}, &pii_detector, &access_control, &rate_limiter, &audit_log);
    defer manager.deinit();

    const permissions = [_]Permission{.ai_query, .data_export};
    const token = try manager.createSession("user-123", &permissions);
    defer std.testing.allocator.free(token.token);

    try std.testing.expect(token.token.len > 0);
    try std.testing.expectEqual(@as(usize, 1), manager.state.active_sessions.count());
}

test "AISecurityManager blockEntity" {
    var pii_detector = PIIDetector.init(std.testing.allocator, &.{});
    var access_control = AccessControl.init(std.testing.allocator);
    var rate_limiter = RateLimiter.init(std.testing.allocator);
    var audit_log = AuditLog.init(std.testing.allocator);

    var manager = AISecurityManager.init(std.testing.allocator, .{}, &pii_detector, &access_control, &rate_limiter, &audit_log);
    defer manager.deinit();

    try manager.blockEntity("bad-actor", "Malicious activity", 1_000_000_000);

    try std.testing.expect(manager.isEntityBlocked("bad-actor"));
}

test "PIIDetector redact email" {
    const patterns = [_]PIIPattern{
        .{
            .pattern_type = .email_address,
            .pattern = "@",
            .redaction_template = "[REDACTED]",
        },
    };

    var detector = PIIDetector.init(std.testing.allocator, &patterns);

    const context = PIIRedactionContext{
        .required_level = .basic,
        .destination = .external,
    };

    const result = try detector.redact(std.testing.allocator, "user@example.com", context);
    defer {
        std.testing.allocator.free(result.redacted_data);
        for (result.instances) |*i| i.deinit(std.testing.allocator);
        std.testing.allocator.free(result.instances);
    }

    try std.testing.expectEqual(@as(usize, 1), result.pii_count);
}

test "CredentialManager store and retrieve" {
    const encryption_key = "test-key-32-bytes-long-!!!!";
    var manager = CredentialManager.init(std.testing.allocator, encryption_key);
    defer manager.deinit();

    try manager.storeCredential("test-api", "secret-key-123", .api_key);

    const retrieved = try manager.getCredential("test-api");
    defer std.testing.allocator.free(retrieved.?);

    try std.testing.expectEqualStrings("secret-key-123", retrieved.?);
}

test "RateLimiter basic limiting" {
    var limiter = RateLimiter.init(std.testing.allocator);
    defer limiter.deinit();

    try limiter.setLimit("default", .{
        .requests_per_window = 2,
        .window_duration_ns = 1_000_000_000,
    });

    const allowed1 = try limiter.checkLimit(std.testing.allocator, "user1", .llm_request);
    const allowed2 = try limiter.checkLimit(std.testing.allocator, "user1", .llm_request);
    const allowed3 = try limiter.checkLimit(std.testing.allocator, "user1", .llm_request);

    try std.testing.expect(allowed1);
    try std.testing.expect(allowed2);
    try std.testing.expect(!allowed3);
}

test "AccessControl checkAccess" {
    var access = AccessControl.init(std.testing.allocator);
    defer access.deinit();

    // Add role to access control
    try access.addRole("user", &.{.ai_query});

    // Test 1: User without roles should be denied
    const result1 = try access.checkAccess(std.testing.allocator, "user1", .ai_query);
    try std.testing.expect(!result1); // No roles assigned

    // Test 2: User with role should have access
    try access.assignRole("user1", "user");
    const result2 = try access.checkAccess(std.testing.allocator, "user1", .ai_query);
    try std.testing.expect(result2); // Has role with ai_query permission

    // Test 3: User without specific permission should be denied
    const result3 = try access.checkAccess(std.testing.allocator, "user1", .admin_access);
    try std.testing.expect(!result3); // Role doesn't have admin_access permission

    // Test 4: Revoke role and verify access is removed
    try access.revokeRole("user1", "user");
    const result4 = try access.checkAccess(std.testing.allocator, "user1", .ai_query);
    try std.testing.expect(!result4); // Role revoked
}

test "AccessControl deny policy" {
    var access = AccessControl.init(std.testing.allocator);
    defer access.deinit();

    // Define admin role with all permissions
    const admin_role_perms = [_]Permission{
        .ai_query,
        .admin_access,
        .data_export,
    };

    try access.addRole("admin", &admin_role_perms);
    try access.assignRole("admin1", "admin");

    // Test 1: Admin should have access
    const result1 = try access.checkAccess(std.testing.allocator, "admin1", .ai_query);
    try std.testing.expect(result1);

    // Test 2: Add deny policy for ai_query
    try access.addPolicy("deny_ai_query", .deny, &.{.ai_query}, &.{});

    // Test 3: Admin should be denied by policy
    const result2 = try access.checkAccess(std.testing.allocator, "admin1", .ai_query);
    try std.testing.expect(!result2); // Deny policy takes precedence

    // Test 4: Admin should still have other permissions
    const result3 = try access.checkAccess(std.testing.allocator, "admin1", .admin_access);
    try std.testing.expect(result3); // Not affected by deny policy
}

test "AuditLog log and query" {
    var audit = AuditLog.init(std.testing.allocator);
    defer audit.deinit();

    const event = SecurityEvent{
        .event_type = .authentication,
        .timestamp = 1000,
        .entity_id = "user1",
        .message = "Login successful",
        .severity = .info,
    };

    try audit.logEvent(std.testing.allocator, event);

    const filter = AuditFilter{ .event_type = .authentication };
    defer filter.deinit(std.testing.allocator);

    const results = try audit.query(filter);
    defer {
        for (results) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
}
