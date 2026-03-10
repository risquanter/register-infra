# ADR-00X: Architecture Decision Records - Meta Template

**Status:** Active  
**Date:** 2026-01-09  
**Tags:** meta, process, documentation

---

## Purpose

This meta-ADR defines the structure, style, and content depth for all ADRs. 
---

## ADR Template Structure

### Header (Required)
```markdown
# ADR-NNN: [Concise Decision Title]

**Status:** [Proposed | Accepted | Accepted (awaiting implementation)| Deprecated | Superseded by ADR-XXX]
**Date:** YYYY-MM-DD  
**Tags:** [3-5 relevant tags]
```

### Context (3-5 bullet points)
**Purpose:** Establish the problem space and constraints.  
**Style:** Bullet points, not paragraphs. Each point states a core principle or constraint.

**Phrasing:** Describe the inherent trade-offs and constraints that make the problem exist — not the state of any prior or existing implementation. Context must remain valid regardless of what code came before or after.

- ❌ `Current DTOs mix client and server concerns` — describes an implementation snapshot
- ❌ `The existing approach requires full resubmission` — describes prior code
- ✅ `A single DTO shape that serves both create and update creates nullable-field ambiguity` — states the principle
- ✅ `Transmitting full structures on every write is bandwidth-intensive and error-prone` — states the trade-off

Avoid: *current*, *existing*, *previously*, *old approach*, *the old X*. Express the underlying quality attribute or constraint instead.

**Example (from ADR-001):**
```markdown
## Context

- External input (HTTP, JSON) is **untrusted**
- Domain objects must be **correct by construction**
- Validation happens at **domain boundaries**, not scattered throughout
- Internal code trusts validated types
```

### Decision (3-5 numbered patterns)
**Purpose:** State the chosen approach with concrete code examples.  
**Style:** Each pattern has a heading, brief explanation (1-2 sentences), and minimal code example showing the pattern.

**Guidelines:**
- Keep code examples short (10-20 lines max)
- Use actual types/classes from codebase
- Show pattern, not full implementation
- Avoid prose—let code speak

**Example (from ADR-001):**
```markdown
## Decision

### 1. Smart Constructor Pattern

Domain objects expose `create()` returning `Validation[ValidationError, DomainObject]`:

```scala
object RiskLeaf {
  def create(id: String, name: String, ...): Validation[ValidationError, RiskLeaf] = {
    // Layer 1: Iron refinement (per-field)
    val idV = toValidation(ValidationUtil.refineId(id, "id"))
    
    // Layer 2: Business rules (cross-field)
    // e.g., minLoss < maxLoss
    
    Validation.validateWith(idV, ...) { ... => RiskLeaf(...) }
  }
}
```
```

### Code Smells (3-5 anti-patterns)
**Purpose:** Show what NOT to do—violations of the decision.  
**Style:** Each smell has BAD/GOOD code comparison. No explanation beyond the code.

**Guidelines:**
- Start with `### ❌ [Anti-Pattern Name]`
- Show BAD code first, then GOOD code
- Keep examples short (5-10 lines each)
- Comments should be in code, not prose

**Example (from ADR-001):**
```markdown
## Code Smells

### ❌ Validation in Service Layer

```scala
// BAD: Service validates raw types
def computeLEC(nTrials: Int, depth: Int) = {
  val validated = for {
    validTrials <- ValidationUtil.refinePositiveInt(nTrials, "nTrials")
    validDepth <- ValidationUtil.refineNonNegativeInt(depth, "depth")
  } yield (validTrials, validDepth)
  // ...
}

// GOOD: Service trusts Iron types
def computeLEC(nTrials: PositiveInt, depth: NonNegativeInt) = {
  // No validation - types guarantee correctness
}
```
```

### Implementation (Optional table)
**Purpose:** Quick reference to where patterns are implemented.  
**Style:** Table mapping location to pattern. 3-6 rows typical.

**Example (from ADR-001):**
```markdown
## Implementation

| Location | Pattern |
|----------|---------|
| `RiskLeaf.create()` | Smart constructor with Validation |
| `JsonDecoder[RiskLeaf]` | Calls `create()` during parsing |
| `RiskTreeService` | Iron types in signatures, no validation |
```

### Alternatives Rejected (Optional — Approved Extension)
**Purpose:** Record options that were explicitly considered and ruled out, so future readers do not re-litigate closed decisions.  
**Style:** One sub-heading per rejected alternative. Each entry states what the option is, and exactly why it was rejected. Prose is acceptable here (unlike Decision/Code Smells) because trade-off reasoning cannot always be expressed in code.

**Guidelines:**
- Use `### [Alternative Name]` (not ❌/✅ — those belong in Code Smells)
- Lead with a one-line **What** description, then a **Why rejected** block
- Keep each entry to 3-6 lines. Cross-reference the ADR whose principle it violates if applicable
- Omit if only one option was viable — this section exists only when real alternatives were evaluated

**Example:**
```markdown
## Alternatives Rejected

### Reflector operator (emberstack/kubernetes-reflector)
- **What**: annotate source Secret; operator copies to target namespaces automatically
- **Why rejected**: requires cluster-wide Secret R/W RBAC — compromised reflector exposes all namespaces. Mirrors the admin credential rather than provisioning a dedicated role, violating least-privilege (ADR-INFRA-004).
```

> **Schema note:** This section is a deliberate, documented extension to the base ADR schema. It is optional and appears after Implementation, before References. ADRs that capture multi-option decisions (technology choices, operator selection, secret delivery strategies) should include it. ADRs that record a single obvious pattern (e.g., a coding convention) should omit it.

### References (Optional)
**Purpose:** External documentation links.  
**Style:** Bulleted list, 2-4 links maximum.

---

## Sizing Guidelines

**Target:** 100-200 lines total (including code examples)  
**Read time:** Under 10 minutes for humans  
**Context window:** Minimal for AI agents

**Section sizing:**
- Context: 3-5 bullet points
- Decision: 3-5 patterns with code
- Code Smells: 3-5 anti-patterns with examples
- Implementation: 3-6 row table (optional)
- Alternatives Rejected: per-option sub-headings (optional extension — include when ≥2 real options were evaluated)

---

## Writing Style

- **Concise over verbose** - Remove filler words
- **Code over prose** - Show, don't tell
- **Bullets over paragraphs** - Easy scanning
- **Concrete over abstract** - Use actual types from codebase
- **Prescriptive over descriptive** - State what to do, not why it's better
- **Timeless over historical** - Context states enduring constraints, not implementation snapshots; never reference "current", "existing", or "old" code states

---

## Naming Convention

- `ADR-00X` - This meta template
- `ADR-001` to `ADR-999` - Sequential, zero-padded
- Use verb phrases: "Validation Strategy", "Error Handling Pattern", "Dependency Injection Approach"

---

## When to Create

**Do create ADR for:**
- Cross-cutting patterns (validation, error handling)
- Technology choices (libraries, frameworks)
- Architectural constraints (type safety, boundaries)

**Don't create ADR for:**
- Single-feature implementation details
- Temporary workarounds
- Routine refactorings

---

## Reference Implementation

**ADR-001** is the canonical example. When in doubt, match its:
- Structure (Context → Decision → Code Smells → Implementation)
- Depth (concise code examples, minimal prose)
- Style (bullets, code-first, prescriptive)
- Length (~160 lines)

---

## For AI Agents

When creating a new ADR:
1. Copy structure from ADR-001
2. Keep Context to 3-5 bullets stating principles
3. Show 3-5 Decision patterns with minimal code
4. Provide 3-5 Code Smells with BAD/GOOD examples
5. Add Implementation table if helpful
6. Add Alternatives Rejected if ≥2 real options were evaluated (approved optional extension)
7. Target 100-200 lines total
