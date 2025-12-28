# NorthstarDB Governance

## Governance Model

NorthstarDB is a meritocratic, open-source project. Governance is based on transparent contribution and demonstrated expertise.

### Principles

1. **Openness**: All discussions happen in public (GitHub issues, PRs, Discord)
2. **Meritocracy**: Influence follows contribution quality and consistency
3. **Technical Excellence**: Technical arguments trump authority
4. **Minimal Process**: Process serves the project, not the reverse

## Decision-Making Process

### Types of Decisions

| Decision Type | Approval Required | Timeline |
|--------------|-------------------|----------|
| Bug fixes | Maintainer review | <48 hours |
| New features | Maintainer approval | 1-2 weeks |
| Breaking changes | Maintainer consensus + RFC | 2-4 weeks |
| Governance changes | Maintainer supermajority (2/3) | 4-8 weeks |

### RFC (Request for Comments) Process

For significant changes:

1. **Draft**: Create RFC PR with motivation, detailed design, and alternatives
2. **Feedback**: Minimum 2-week discussion period
3. **Consensus**: Address concerns, build support
4. **Decision**: Maintainers approve/reject with rationale
5. **Implementation**: Create tracking issues, begin work

### Appealing Decisions

Any rejected decision can be appealed by:
1. Requesting formal review from all maintainers
2. Presenting new technical evidence or use cases
3. Requiring supermajority (3/4) to overturn

## Roles

### Contributor
Anyone who submits PRs, issues, or documentation improvements.

**Expectations**:
- Follow code of conduct
- Write clear PR descriptions
- Respond to review feedback

**Benefits**:
- Recognition in CONTRIBUTORS file
- Voting eligibility (after 5 merged PRs)

### Maintainer
Active contributor with commit access and decision authority.

**Becoming a Maintainer**:
- Minimum 20 merged PRs
- Sustained activity over 6+ months
- Demonstrated technical judgment
- Existing maintainer sponsorship
- Supermajority approval (2/3)

**Responsibilities**:
- Review and merge PRs
- Triage issues and label work
- Participate in RFC discussions
- Mentor new contributors
- Release management (rotating)

**Becoming a Lead Maintainer**:
- Minimum 1 year as maintainer
- Major architectural contributions
- Supermajority approval (3/4)
- Existing lead sponsorship

**Responsibilities**:
- Final authority on deadlocks
- Roadmap and vision
- Security response coordination
- CI/CD infrastructure ownership

### Release Manager
Rotating role among maintainers (monthly term).

**Responsibilities**:
- Version cutting and publishing
- Release note compilation
- Coordinating release freeze
- Managing branches (main, release/*)

## Contribution Recognition

### Recognition Levels

| Level | Criteria | Visibility |
|-------|----------|------------|
| Contributor | 1+ merged PR | CONTRIBUTORS file |
| Active Contributor | 5+ merged PRs | Website contributors page |
| Maintainer | Approved by maintainers | README, website |
| Emeritus | Past maintainer | Hall of Fame page |

### Hall of Fame

Former maintainers and major contributors permanently recognized in:
- `HALL_OF_FAME.md`
- Website "Team" page
- Release notes (historical)

## Conflict Resolution

### Code of Conduct Enforcement

1. **Report**: Email conduct@northstardb.org or DM any maintainer
2. **Review**: Maintainers investigate (within 48 hours)
3. **Action**: Warnings, temporary bans, or permanent bans
4. **Appeal**: Respond to maintainer team within 7 days

### Technical Disputes

1. **Discussion**: GitHub issue/PR comments
2. **Escalation**: Request maintainer review
3. **RFC**: Formal proposal for major disagreements
4. **Vote**: Maintainers vote (deadlock broken by lead)

### Community Health

The maintainer team monitors:
- Response times (target: <48 hours for new issues)
- PR backlog (target: <10 open PRs >2 weeks)
- Contributor retention (quarterly review)

## Project Infrastructure

### Repository Permissions

| Role | Permissions |
|------|-------------|
| Public | Read, comment, open PRs |
| Contributors | Push to non-protected branches |
| Maintainers | Push to main, merge PRs, manage labels/projects |
| Leads | Admin access, branch protection, secrets |

### CI/CD Access

- Maintainers: Can restart workflows, view logs
- Leads: Can modify workflows, manage secrets

### Crisis Management

For security issues or outages:
1. Use `security@northstardb.org` for vulnerabilities
2. Maintainers private channel for incident response
3. Lead maintainer can authorize emergency bypasses
4. Post-incident public report within 7 days

## Revision History

| Date | Change | Author |
|------|--------|--------|
| 2025-12-28 | Initial governance document | Project Lead |

---

**Questions?** Open an issue or start a discussion on GitHub.
