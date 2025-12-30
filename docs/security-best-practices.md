# Security Best Practices

This document outlines security best practices for NorthstarDB development and deployment.

## Automated Security Scanning

NorthstarDB uses continuous security scanning in CI to catch vulnerabilities early:

### Security Workflow (`.github/workflows/security-scan.yml`)

Runs on:
- Every push to `main`
- Every pull request
- Daily scheduled scan (00:00 UTC)
- Manual trigger via GitHub Actions UI

#### Scans Performed

1. **CodeQL Analysis**
   - Static analysis for code vulnerabilities
   - Uses security-extended and quality queries
   - Blocks PRs on critical findings

2. **Zig Security Audit**
   - Checks for unsafe build configurations
   - Scans for hardcoded secrets/credentials
   - Identifies direct OS calls and HTTP clients

3. **Dependency Vulnerability Scan**
   - Analyzes `build.zig.zon` for dependencies
   - Checks `build.zig` for remote dependency references
   - Alerts on suspicious fetch patterns

4. **Security Linting**
   - Code style consistency (`zig fmt --check`)
   - Identifies security anti-patterns
   - Checks for weak crypto primitives (MD5, SHA1)
   - Warns about unchecked `unreachable` errors

5. **Secret Scanning**
   - Scans full git history for leaked secrets
   - Detects API keys, tokens, passwords
   - Blocks commits with detected secrets

### Dependabot (`.github/dependabot.yml`)

- Checks for GitHub Actions updates weekly
- Opens PRs with dependency updates
- Labels: `dependencies`, `github-actions`, `security`

## Responding to Security Alerts

### Critical Severity (Immediate Action Required)

1. **CodeQL / Secret Scan Alerts**
   - Block: Merge not allowed until fixed
   - Timeline: Fix within 24 hours
   - Escalation: Security team lead

2. **Dependency Vulnerabilities**
   - Assess: Is the vulnerable code actually used?
   - Fix: Update dependency or add workaround
   - Document: Create security advisory if affected

### High Severity

1. Assess impact within 48 hours
2. Schedule fix for next sprint
3. Add security exception if justified

### Medium/Low Severity

1. Add to backlog
2. Address in regular maintenance
3. Track in project board

## Security Development Guidelines

### Code Review Security Checklist

Before merging code, verify:

- [ ] No hardcoded credentials or secrets
- [ ] Proper error handling (no silent failures)
- [ ] Input validation on all external inputs
- [ ] Bounds checking on arrays/slices
- [ ] No use of deprecated crypto (MD5, SHA1, RC4)
- [ ] Proper use of Zig's safety checks (`Debug`, `ReleaseSafe`)
- [ ] No TODO/FIXME in security-critical paths

### Cryptographic Practices

**Do:**
- Use Zig's modern crypto: `std.crypto.auth.hmac.sha256`, `std.crypto.hash.sha2`
- Use authenticated encryption (AEAD) for data at rest
- Validate certificates in TLS connections

**Don't:**
- Roll your own crypto
- Use weak algorithms (MD5, SHA1, RC4, DES)
- Store secrets in code or config files
- Disable certificate validation

### Memory Safety

Zig provides memory safety features:

**Use `Debug` mode for testing:**
```bash
zig build -DDebug
```

**Use `ReleaseSafe` for production (not `ReleaseFast`):**
```bash
zig build -Drelease-safe
```

**Why:** `ReleaseFast` disables runtime safety checks for performance. `ReleaseSafe` keeps bounds checking, overflow checking, etc.

### Error Handling

**Never silently ignore errors:**
```zig
// BAD
const file = std.fs.cwd().openFile("data", .{}) catch unreachable;

// GOOD
const file = std.fs.cwd().openFile("data", .{}) catch |err| {
    std.log.err("Failed to open file: {}", .{err});
    return err;
};
```

**Validate all external inputs:**
```zig
// Validate file paths, user input, network data
if (input.len > MAX_ALLOWED) return error.InputTooLarge;
```

## Dependency Management

### Adding Dependencies

Before adding a new dependency:

1. **Assess necessity:** Is it available in Zig stdlib?
2. **Check security:** Look for open vulnerabilities
3. **Check maintenance:** Last commit within 6 months
4. **Check license:** Must be compatible with project license
5. **Document:** Add to docs/security-dependencies.md

### Updating Dependencies

- Dependabot creates PRs automatically
- Review changelog for security fixes
- Run full test suite after update
- Check for breaking changes

## Incident Response

### Security Vulnerability Disclosure

If you discover a security vulnerability:

1. **Do NOT create a public issue**
2. Email: security@[project-domain].com
3. Include:
   - Description of vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if known)

### Response Process

1. **Triage:** Security team acknowledges within 48 hours
2. **Investigation:** Root cause analysis within 1 week
3. **Fix:** Develop and test patch
4. **Release:** Coordinated security release
5. **Disclosure:** Public advisory with CVE (if applicable)

## Production Deployment Security

### Build Integrity

- Use reproducible builds
- Sign release artifacts
- Verify checksums before deployment

### Runtime Security

- Run as non-root user
- Enable filesystem permissions (read-only where possible)
- Use rate limiting for external connections
- Enable audit logging

### TLS Configuration

- Minimum TLS 1.2
- Strong cipher suites
- Certificate pinning for known endpoints
- Regular certificate rotation

## Continuous Improvement

### Quarterly Security Reviews

1. Review dependency updates
2. Audit high-risk code paths
3. Update threat model
4. Review incident response procedures

### Training

- All devs complete security awareness training
- Review OWASP Top 10 annually
- Stay current on Zig security best practices

## Resources

- [Zig Security Guide](https://ziglang.org/documentation/master/#Security)
- [OWASP Zig Cheat Sheet](https://cheatsheetseries.owasp.org/)
- [GitHub Security Lab](https://securitylab.github.com/)
- [CodeQL Documentation](https://codeql.github.com/docs/)

## Quick Reference

| Scenario | Action |
|----------|--------|
| Secret found in git | Rotate secret immediately, use BFG Repo-Cleaner |
| CodeQL alert fails PR | Fix before merging, or document exception |
| Dependency vulnerability | Update if used, add note if not |
| Crypto needed | Use std.crypto, never roll your own |
| Production build | Use `-Drelease-safe`, not `-Drelease-fast` |
| Input validation | Always validate length, format, range |
| Error handling | Never catch unreachable, propagate errors |

---

**Last Updated:** 2025-12-30
**Maintained By:** Security Team
