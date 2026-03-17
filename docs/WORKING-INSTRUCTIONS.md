# Working Instructions

This document defines the working protocol for implementing the ADR proposals.

---

## Governance

### Progress Control

- **User is in charge** of progress approval, review, and decisions
- Each phase requires **explicit approval** before proceeding to the next
- Agent will **ask questions** when facing ambiguity rather than making assumptions
- Agent will **not proceed** to the next phase without user's "proceed" confirmation

### Decision Protocol

1. Agent presents options or proposed approach
2. User reviews and either approves, requests changes, or asks questions
3. Agent implements only after approval
4. Agent presents results for review before marking phase complete

---

## Code Standards

### Scala / ZIO

- Code must be **idiomatic Scala 3** with ZIO 2.x patterns
- Follow existing codebase conventions (check existing files for style)
- Use ZIO Prelude types where applicable (`Identity`, `Validation`, etc.)
- Prefer `for` comprehensions for ZIO effect composition
- Use Iron refined types for domain validation (per ADR-001)

### OCaml

- **Minimize OCaml code** — prefer using Irmin as an external service
- Only write OCaml if absolutely necessary for Irmin integration
- **Notify user before generating OCaml** — will establish OCaml-specific preferences at that time
- Goal: Irmin exposes GraphQL API; ZIO consumes it as a client

---

## ADR Compliance

### Mandatory Review Process

**ALL proposed code changes MUST be reviewed against existing ADRs** at two critical points:

#### 1. Planning Phase (Before Implementation)

Before writing any code, agent must:

1. **Review all accepted ADRs** to understand current architecture
2. **Identify potential conflicts** with proposed changes
3. **Document alignment or deviations** in planning proposal
4. **Notify user immediately** if any deviation is detected:
   ```markdown
   ⚠️ **ADR Deviation Detected**
   
   **Affected ADR:** ADR-XXX (Title)
   **Deviation:** [Specific conflict description]
   **Proposed approach:** [What you plan to do]
   **ADR states:** [What the ADR requires]
   
   **Options:**
   - A) Modify proposal to comply with ADR-XXX
   - B) Update ADR-XXX to accommodate new requirements
   - C) [Other alternatives]
   
   **Decision required:** How should we proceed?
   ```
5. **Wait for user decision** before proceeding

#### 2. Review Phase (After Implementation)

After implementing changes, agent must:

1. **Re-validate all code** against accepted ADRs
2. **Check for unintended deviations** introduced during implementation
3. **Document compliance** in completion report
4. **Notify user immediately** if any deviation is found:
   ```markdown
   ⚠️ **ADR Compliance Issue Detected**
   
   **Affected ADR:** ADR-XXX (Title)
   **Issue:** [What was violated]
   **Code location:** `path/to/file.scala:line`
   **Current implementation:** [What was done]
   **ADR requirement:** [What should have been done]
   
   **Remediation options:**
   - A) Refactor code to comply with ADR-XXX
   - B) Update ADR-XXX if requirements have changed
   
   **Decision required:** How should we resolve this?
   ```
5. **Wait for user decision** before marking phase complete

### Validation Requirements

At each phase, validate implementation against:

1. **Accepted ADRs** (currently implemented):
   - ADR-001: Validation with Iron types & smart constructors
   - ADR-002: Logging strategy (ZIO logging + OpenTelemetry)
   - ADR-003: Provenance & reproducibility (HDR seeds)
   - ADR-009: Compositional Risk Aggregation via Identity
   - ADR-010: Error Handling Strategy (hybrid error channels)
   - ADR-011: Import Conventions (top-level imports, no FQNs)

2. **Proposals being implemented** (validate as they're accepted):
   - ADR-004a-proposal: Persistence Architecture (SSE)
   - ADR-004b-proposal: Persistence Architecture (WebSocket)
   - ADR-005-proposal: Cached Subtree Aggregates
   - ADR-006-proposal: Real-Time Collaboration
   - ADR-007-proposal: Scenario Branching
   - ADR-008-proposal: Error Handling & Resilience
   - ADR-012: Service Mesh Strategy (Istio Ambient Mode)

### ADR Lifecycle

```
Proposal → Implementation → Review → Accepted
                ↓
         (rename -proposal.md to .md)
         (update Status: Accepted)
```

When a phase completes and its ADR is validated:
1. Remove `-proposal` suffix from filename
2. Update status from "Proposed" to "Accepted"
3. Add acceptance date
4. Include in validation set for subsequent phases

---

## Implementation Principles

### Incremental Approach

- Small, reviewable changes per phase
- Each phase produces **working, testable code**
- Tests accompany implementation (not deferred)
- Compile and test before presenting for review

### Dependency Order

Implement in order of dependencies:
1. Foundation (error types, data models)
2. Infrastructure (clients, connections)
3. Services (business logic)
4. API layer (endpoints, SSE/WebSocket)
5. Frontend integration

### Irmin Strategy

- Treat Irmin as **external service** with GraphQL API
- ZIO backend is a **GraphQL client** to Irmin
- Avoid embedding OCaml in Scala build
- If Irmin requires custom schema or resolvers → notify user for OCaml discussion

---

## Communication Format

### Phase Presentation

```markdown
## Phase X: [Title]

### Objective
[What this phase accomplishes]

### ADR References
[Which proposals this implements]

### ADR Compliance Review (Planning Phase)
**Reviewed ADRs:** ADR-001, ADR-002, ADR-003, ADR-009, ADR-010, ADR-011
**Deviations detected:** None / [List of deviations with decisions required]
**Alignment notes:** [How this phase aligns with existing ADRs]

### Validation Checklist
- [ ] Compliant with ADR-001 (Iron types)
- [ ] Compliant with ADR-002 (Logging)
- [ ] Compliant with ADR-003 (Provenance)
- [ ] Compliant with ADR-009 (Identity aggregation)
- [ ] Compliant with ADR-010 (Error handling)
- [ ] Compliant with ADR-011 (Import conventions)
- [ ] [Additional validations as ADRs are accepted]

### Tasks
1. [Specific task]
2. [Specific task]
...

### Questions for User (if any)
- [Question about ambiguity]

### Approval Checkpoint
- [ ] ADR compliance verified at planning stage
- [ ] Code compiles
- [ ] Tests pass
- [ ] **Integration verified** (see Integration Verification below)
- [ ] User approves
```

### Integration Verification

After implementation, verify that new components are **actually connected** to the application:

#### For New Controllers:
- [ ] Controller wired into `HttpApi.makeControllers`
- [ ] Controller's routes included in `gatherRoutes` output
- [ ] Required layers added to `Application.appLayer`

#### For New Endpoints:
- [ ] Endpoint accessible via curl or HTTP client
- [ ] Endpoint appears in Swagger documentation (`/docs`)
- [ ] At least one test hits the actual HTTP layer (not just unit test)

#### For New Services:
- [ ] Service layer added to `Application.appLayer`
- [ ] Service injected into dependent components
- [ ] Service tested via integration test (not just unit test)

#### Verification Commands:
```bash
# List registered endpoints (after server starts)
curl http://localhost:8090/docs/openapi.json | jq '.paths | keys'

# Verify specific endpoint exists
curl -I http://localhost:8090/w/{key}/events/tree/1

# Run all tests including integration
sbt test
```

**If any integration check fails, the phase is NOT complete.**

### Completion Report

```markdown
## Phase X Complete

### Implemented
- [List of what was built]

### Files Changed
- `path/to/file.scala` — [description]

### Tests Added
- [Test file and coverage]

### ADR Compliance Review (Post-Implementation)
**Re-validated ADRs:** ADR-001, ADR-002, ADR-003, ADR-009, ADR-010, ADR-011
**Compliance status:** ✅ All ADRs compliant / ⚠️ [Deviations found - see below]
**Issues detected:** None / [List of compliance issues requiring user decision]

### ADR Status
- [Proposal name]: Ready for acceptance / Needs more work

### Ready for Review
[Summary for user to review]
```

---

## Questions Protocol

When agent encounters ambiguity:

1. **Stop implementation** at the unclear point
2. **Present context** — what was being attempted
3. **List options** — if applicable
4. **Ask specific question** — not open-ended
5. **Wait for answer** — do not assume

---

## Checkpoints

User will confirm at these points:

- [ ] Working instructions reviewed and approved
- [ ] Implementation plan reviewed and approved
- [ ] **ADR compliance verified at planning phase** (mandatory before implementation)
- [ ] Each phase completion approved
- [ ] **ADR compliance re-verified post-implementation** (mandatory before phase sign-off)
- [ ] **Agent re-reads `docs/WORKING-INSTRUCTIONS.md` before marking phase complete** (mandatory guardrail)
- [ ] Each ADR acceptance approved
- [ ] Final integration approved

---

## Decision Triggers

**STOP and ASK the user before proceeding** when encountering ANY of these:

1. **Schema/API changes** — Any change affecting OpenAPI/Swagger output
2. **Workarounds** — Using `Schema.any`, `asInstanceOf`, unsafe casts, or "escape hatches"
3. **New dependencies** — Adding imports from libraries not already in use
4. **Type changes** — Modifying case class fields, adding/removing parameters
5. **Behavioral changes** — Changing how existing code works (not just adding new code)
6. **"It works but..."** — Any solution with tradeoffs, limitations, or caveats
7. **Recursive/complex types** — Types that require special handling for serialization

**Litmus test:** If the change affects anything a user/consumer of the API would notice → ASK FIRST.

**Format for decision requests:**
```markdown
⚠️ **Decision Required**

**Context:** [What I was implementing]
**Issue:** [What problem arose]

**Options:**
- A) [Option with tradeoffs]
- B) [Alternative with different tradeoffs]
- C) [Other alternatives]

**My assessment:** [Which I'd lean toward and why]
**Decision needed:** Which option should I implement?
```

---

## Memory Enforcement

**Problem:** Agent context can lose track of this document mid-session.

**Mitigation:** User may issue these commands at any time:

- `"Re-read WORKING-INSTRUCTIONS.md"` — Agent must re-read and acknowledge
- `"Decision check"` — Agent must verify current action doesn't require a decision
- `"Protocol check"` — Agent must state which protocol section applies to current work

**Agent self-check:** Before ANY file edit, mentally verify:
1. Is this a decision trigger? → If yes, STOP and ask
2. Does this deviate from an ADR? → If yes, STOP and ask
3. Am I assuming user approval? → If yes, STOP and ask

---

## ADR Deviation Protocol Summary

**Agent must NEVER:**
- Implement code that deviates from accepted ADRs without user approval
- Assume deviation is acceptable without asking
- Proceed with implementation if deviation is detected at planning stage

**Agent must ALWAYS:**
- Review ALL accepted ADRs before proposing any code changes
- Notify user immediately when deviation is detected (planning OR review phase)
- Present clear options and wait for user decision
- Document all deviations and resolutions in phase reports

---

## CRITICAL STOP POINTS

Before ANY of these actions, STOP and ask for explicit approval:
- [ ] Deleting files
- [ ] Removing methods/functions
- [ ] Changing service interfaces
- [ ] Modifying layer wiring
- [ ] Removing tests

Format: "I propose to [ACTION]. Approve? (Y/N)"

---

*Document created: 2026-01-17*  
*Last updated: 2026-01-17*  
*Status: Awaiting user approval*
