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

**Status:** [Proposed | Accepted | Deprecated | Superseded by ADR-XXX]  
**Date:** YYYY-MM-DD  
**Tags:** [3-5 relevant tags]
```

### Context (3-5 bullet points)
**Purpose:** Establish the problem space and constraints.  
**Style:** Bullet points, not paragraphs. Each point states a core principle or constraint.

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

---

## Writing Style

- **Concise over verbose** - Remove filler words
- **Code over prose** - Show, don't tell
- **Bullets over paragraphs** - Easy scanning
- **Concrete over abstract** - Use actual types from codebase
- **Prescriptive over descriptive** - State what to do, not why it's better

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
6. Target 100-200 lines total
