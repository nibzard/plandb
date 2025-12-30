# NorthstarDB AI Plugin System - Security Audit Report v0.1.0

**Date**: 2025-12-30
**Auditor**: Autonomous Security Audit
**Scope**: Phase 10.1 - Production Hardening
**Version**: v0.1.0 release

## Executive Summary

This audit reviews the AI intelligence layer of NorthstarDB for security vulnerabilities, focusing on:
- Prompt injection vulnerabilities
- Function calling safety
- API key and credential handling
- Rate limiting and abuse prevention
- Input sanitization

**Overall Assessment**: **MODERATE RISK** - Core security framework is in place but has critical production-readiness gaps.

---

## Critical Findings

### 1. CRITICAL: Weak Encryption in Credential Manager (src/security/ai_security.zig:1126-1143)

**Severity**: P0 - CRITICAL
**Location**: `CredentialManager.encrypt/decrypt`

**Issue**:
```zig
fn encrypt(self: *Self, data: []const u8) ![]const u8 {
    // Simple XOR for demo (would use AES-GCM in production)
    const result = try self.allocator.alloc(u8, data.len);
    for (data, 0..) |byte, i| {
        result[i] = byte ^ 0x42; // FIXED XOR KEY - CRITICAL WEAKNESS
    }
    return result;
}
```

**Impact**:
- All stored credentials are trivially decryptable
- XOR with constant 0x42 provides zero security
- Anyone with database access can extract API keys

**Remediation**:
- Replace XOR with AES-256-GCM
- Use proper key derivation (PBKDF2/Argon2)
- Rotate all existing credentials after fix

---

### 2. HIGH: Weak Session Token Generation (src/security/ai_security.zig:432-442)

**Severity**: P1 - HIGH
**Location**: `AISecurityManager.generateSessionToken`

**Issue**:
```zig
fn generateSessionToken(self: *Self) ![]const u8 {
    const token_len = 32;
    const token = try self.allocator.alloc(u8, token_len);
    var i: usize = 0;
    while (i < token_len) : (i += 1) {
        token[i] = 'a' + @as(u8, @intCast(@rem(std.time.nanoTimestamp(), 26)));
        // ONLY 26 POSSIBLE VALUES - EASILY GUESSABLE
    }
    return token;
}
```

**Impact**:
- ~26^32 possible tokens, but timestamp predictability reduces entropy
- No cryptographic randomness
- Vulnerable to timing attacks

**Remediation**:
- Use `std.crypto.random` for cryptographically secure random bytes
- Encode as hex or base64
- Minimum 128-bit entropy

---

### 3. HIGH: API Key Leakage in Logs (src/llm/providers/openai.zig:419-421)

**Severity**: P1 - HIGH
**Location**: `OpenAIProvider.makeApiCall`

**Issue**:
```zig
std.log.err("OpenAI API returned status {d}: {s}", .{
    @intFromEnum(request.response.status),
    error_body.items
});
// error_body may contain API key in error details
```

**Impact**:
- API keys may be logged in plaintext
- Logs may be shipped to external monitoring services
- Credential exposure in log files

**Remediation**:
- Redact API keys from error messages before logging
- Implement structured logging with field-level redaction

---

### 4. MEDIUM: Missing Input Validation in Plugin Manager (src/plugins/manager.zig:262-269)

**Severity**: P2 - MEDIUM
**Location**: `PluginManager.call_function`

**Issue**:
```zig
pub fn call_function(
    self: *Self,
    function_name: []const u8,
    params: llm.Value
) !llm.FunctionResult {
    const schema = try self.find_function_schema(function_name);
    // NO VALIDATION of params against schema
    return self.llm_provider.call_function(schema, params, self.allocator);
}
```

**Impact**:
- Invalid parameters may cause crashes
- No type safety for function arguments
- Potential for injection via malformed parameters

**Remediation**:
- Validate parameters against JSONSchema before calling
- Reject calls with missing required fields
- Sanitize string arguments for injection patterns

---

### 5. MEDIUM: Timeout Not Enforced in Async Hooks (src/plugins/manager.zig:309-328)

**Severity**: P2 - MEDIUM
**Location**: `async_hook_wrapper`

**Issue**:
```zig
fn async_hook_wrapper(
    allocator: std.mem.Allocator,
    hook: *const fn(std.mem.Allocator, CommitContext) anyerror!PluginResult,
    ctx: CommitContext,
    plugin_name: []const u8,
    timeout_ms: u64,
    result_ptr: *AsyncHookResult,
) void {
    _ = timeout_ms; // TIMEOUT IGNORED - NEVER ENFORCED
    _ = plugin_name;

    const hook_result = hook(allocator, ctx) catch |err| {
        result_ptr.* = AsyncHookResult{ .failed = .{ .err = err } };
        return;
    };
    result_ptr.* = AsyncHookResult{ .success = hook_result.operations_processed };
}
```

**Impact**:
- Malicious or hanging plugins can block indefinitely
- No performance isolation guarantee
- DoS vulnerability via slow LLM responses

**Remediation**:
- Implement actual timeout with thread cancellation
- Use async task cancellation
- Kill threads exceeding timeout

---

## Positive Findings

### 1. EXCELLENT: Comprehensive Security Manager Framework

The `AISecurityManager` (src/security/ai_security.zig:51-482) provides:
- PII detection and redaction
- Access control with roles and policies
- Rate limiting per operation type
- Audit logging for security events
- Session management
- Entity blocking for abuse prevention

**Strengths**:
- Well-structured architecture
- Good separation of concerns
- Comprehensive event types tracked

### 2. GOOD: Prompt Injection Detection in LLM Response Validation

Location: src/security/ai_security.zig:169-234

```zig
const injection_patterns = [_][]const u8{
    "ignore previous instructions",
    "disregard all above",
    "forget everything",
    "new instructions:",
    "system override",
};
```

**Strengths**:
- Detects common prompt injection patterns
- Checks for credential leakage in responses
- Malicious code pattern detection

### 3. GOOD: Modular Plugin System

The plugin system (src/plugins/manager.zig) provides:
- Clean trait-based plugin interface
- Multiple hook types (commit, query, schedule, agent operations)
- Error isolation between plugins
- Performance isolation framework (when timeout is fixed)

### 4. ADEQUATE: Provider-Agnostic Design

- Abstract LLM provider interface (src/llm/client.zig)
- Support for OpenAI, Anthropic, and local models
- Consistent error handling across providers
- Response validation framework

---

## Medium Priority Findings

### 6. MEDIUM: No URL Validation for Custom Endpoints

**Location**: src/llm/client.zig:76-112

**Issue**: Custom endpoints are not validated, allowing potential SSRF attacks.

**Remediation**:
- Validate URLs against allowlist
- Block private/internal IP addresses
- Enforce HTTPS for production

---

### 7. MEDIUM: Rate Limit Uses In-Memory Storage

**Location**: src/security/ai_security.zig:869-937

**Issue**: Rate limits reset on process restart. No distributed coordination.

**Impact**:
- Easy to bypass by restarting process
- No cross-instance rate limiting in distributed deployments

**Remediation**:
- Persist rate limit state to database
- Implement distributed rate limiting for production clusters

---

### 8. MEDIUM: PII Detection is Pattern-Based Only

**Location**: src/security/ai_security.zig:668-719

**Issue**: Simple substring matching, no ML-based detection.

**Limitations**:
- High false positive rate (e.g., "secretary" contains "secret")
- Misses obfuscated PII
- No context-aware detection

**Remediation**:
- Use regex patterns for email, phone, SSN, etc.
- Consider ML-based PII detection for production

---

## Low Priority Findings

### 9. LOW: Access Control Always Returns True

**Location**: src/security/ai_security.zig:811-820

```zig
pub fn checkAccess(self: *Self, allocator: std.mem.Allocator, user_id: []const u8, permission: Permission) !bool {
    // Simplified: grant all permissions for now
    return true;
}
```

**Impact**: No actual access control enforcement

**Remediation**: Implement proper role-based access control before production

---

### 10. LOW: No Request Size Limits on LLM Payloads

**Location**: src/llm/providers/openai.zig:375-431

**Issue**: `makeApiCall` doesn't validate payload size before sending

**Impact**: Potential for large payloads causing cost overruns

**Remediation**: Add max payload size validation

---

## Checklist for Production Readiness

### Must Fix Before Production

- [ ] Replace XOR encryption with AES-256-GCM in CredentialManager
- [ ] Implement cryptographically secure session token generation
- [ ] Enforce actual timeouts in async hook wrapper
- [ ] Redact API keys from error logs
- [ ] Implement input validation for function parameters
- [ ] Add URL validation for custom endpoints
- [ ] Implement proper access control (not always-true)

### Should Fix Before Production

- [ ] Add regex-based PII patterns (email, phone, SSN, credit card)
- [ ] Implement persistent rate limiting
- [ ] Add request size limits for LLM calls
- [ ] Add response size limits for LLM responses
- [ ] Implement plugin sandboxing

### Nice to Have

- [ ] ML-based PII detection
- [ ] Distributed rate limiting
- [ ] Plugin signature verification
- [ ] Security-focused benchmark tests

---

## Security Testing Recommendations

### 1. Unit Tests Needed
- Test credential encryption/decryption with real AES
- Test session token randomness (entropy measurement)
- Test timeout enforcement with slow plugins

### 2. Integration Tests Needed
- End-to-end prompt injection attack tests
- Credential leakage tests in logs
- Rate limit bypass tests

### 3. Fuzzing Tests Needed
- Fuzz function parameter validation
- Fuzz URL parsing for SSRF
- Fuzz JSON parsing in LLM responses

---

## Conclusion

NorthstarDB's AI intelligence layer has a **solid security foundation** with comprehensive frameworks for PII redaction, access control, and audit logging. However, **critical production-readiness issues** exist:

1. **Credential encryption is effectively non-existent** (XOR with constant)
2. **Session tokens are predictable**
3. **Timeouts are not enforced**
4. **API keys may leak into logs**

These issues **must be addressed** before v0.1.0 can be considered production-ready for sensitive workloads.

**Risk Rating**: MODERATE
**Recommendation**: Address all P0 and P1 issues before production deployment

---

## Appendix: Files Reviewed

- src/llm/client.zig - Provider-agnostic LLM client
- src/llm/function.zig - Function schema and calling
- src/llm/types.zig - Core type definitions
- src/llm/providers/openai.zig - OpenAI provider implementation
- src/plugins/manager.zig - Plugin lifecycle and execution
- src/security/ai_security.zig - Security controls (PII, access, rate limiting)

---

**Next Steps**:
1. Create GitHub issues for each critical finding
2. Prioritize fixes based on severity
3. Add security benchmarks to CI pipeline
4. Schedule follow-up audit after fixes are deployed
