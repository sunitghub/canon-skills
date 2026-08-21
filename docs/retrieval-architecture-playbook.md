---
title: Retrieval Architecture Playbook
description: Four ordered tests for choosing between vector RAG and Graph RAG
updated: 2026-08-21
---

# Retrieval Architecture Playbook

Most teams pick a retrieval architecture by corpus size. That is the wrong axis.

The question is not how much data you have. It is whether the answer can exist inside a single chunk. A million flat documents is a chunking and reranking problem. Eight documents whose answer only emerges by chaining three of them together is an architecture problem. This playbook gives you four tests, cheapest first, each with a stopping rule.

---

## The Principle

**The composition has to happen somewhere.**

When an answer spans multiple documents, someone must join them. There are exactly two places that can happen:

| | Composed at query time | Composed at build time |
|---|---|---|
| Who joins | the model, per question | code, once |
| Behaviour | stochastic — fails differently each run | deterministic — fails identically forever |
| Cost | per query, grows with reasoning depth | one-time, per document |
| Error visibility | per-answer, inspectable | frozen in a derived store, invisible |
| Obligation created | none | **verification** |

Graph RAG is not smarter retrieval. It moves composition earlier and pays for it with a verification obligation. Every test below exists to find out whether that trade is worth making — and the fourth exists because most teams take the trade without noticing the obligation.

---

## Test 1 — The Single-Chunk Test

**Goal:** Establish whether you have a retrieval problem or a composition problem.

**Method:** Take 20–30 real questions from actual users, not invented ones. For each, try to highlight one contiguous passage in one document that contains the whole answer. Count.

| Share answerable from one passage | Architecture |
|---|---|
| **> 80%** | Vector RAG. **Stop here.** Do not build a graph. |
| **40–80%** | Vector RAG + reranker; route the multi-hop minority separately. Hybrid, not graph. |
| **< 40%** | The answer is structurally relational. Continue to test 2. |

**What it is NOT:** Counting documents, tokens, or embeddings. Corpus size does not appear in this test. The single most durable finding in the published benchmark literature is that the advantage of relationship-aware retrieval "grew with reasoning complexity — not with dataset size" (*GraphRAG in Practice*, TigerGraph, Jul 2026, p.16).

This test costs an afternoon and eliminates most candidates.

---

## Test 2 — Are The Edges Already Materialised?

**Goal:** Avoid building a graph you already have.

**Method:** For each relationship your questions traverse, ask where it already lives. Foreign keys. A CRM's account hierarchy. Issue-tracker link types. Git commit trailers. A standard's published reference-data library. If the edge exists as structured data, query it and put the result in the prompt.

**Stopping rule:** If every traversal your questions need is already expressed in a system of record, you are done. No extraction, no ontology, no graph database, no drift.

**What it is NOT:** A reason to skip the graph when the edges are genuinely latent in prose. But most "we need Graph RAG" turns out to be "we need to join two tables into the context window."

canon's own `tkt why` is this test's answer in practice: it traverses `git log --follow` and reads each ticket's recorded decisions. Same traversal shape as a graph query, over primary data, with no derived store to go stale.

---

## Test 3 — Is The Ontology Stable?

**Goal:** Price the maintenance you are signing up for.

**Method:** Try to write down the closed entity and relation vocabulary *before* looking at the questions. Then ask whether it will still be right in six months.

Graph RAG requires a fixed schema — the vocabulary must be settled before documents are modelled. Every schema change is a re-extraction of the whole corpus. Vector RAG has no schema, so it absorbs domain drift for free.

**Stopping rule:** If the vocabulary is still moving, stop. You will pay the extraction bill repeatedly, and each payment is an opportunity to introduce the error described in test 4.

**Strong signal in favour:** an ontology that is *governed externally* — an industry standard, a regulatory taxonomy, a published reference-data library. Someone else has already paid for schema stability and maintains it. This is the condition that most often flips a borderline case into a clear yes.

**What it is NOT:** A judgment about whether you *could* model the domain. You almost always could. The question is whether the model holds still.

---

## Test 4 — Is There A Gate On The Extraction?

**Goal:** Find out whether your graph can be wrong without anyone noticing.

This is the test nobody runs, and it is the reason the other three matter. A derived store built by an LLM will serve a wrong fact forever, with the authority of structure, and nothing in a typical pipeline objects.

**Method:** Break your own extraction on purpose, two ways, and observe what the build does.

The following was run against [`Glitch-Cat-Club/graph-memory-starter`](https://github.com/Glitch-Cat-Club/graph-memory-starter) — a minimal, honest reference implementation: three SQLite tables, one recursive CTE, one prompt hook.

**Structural break** — rename an edge endpoint so it resolves to no node:

```
$ python3 src/build_graph.py
built graph.db: 13 entities, 12 relations, 10 aliases from 8 docs
  skipped edge in refund-policy.md: Refund approvals --[approved_by]--> Operations Manager (unknown endpoint)
$ echo "exit=$?"
exit=0
```

Caught — and **exit status 0**. The signal exists but is advisory, so no CI step fails. That is a free gate left on the floor; a wrapper that greps for `skipped edge` and exits non-zero costs one line.

**Semantic break** — keep the structure valid, and substitute a threshold from a document explicitly marked *superseded*:

```
$ python3 src/build_graph.py
built graph.db: 13 entities, 13 relations, 10 aliases from 8 docs

$ python3 src/recall.py "A customer wants an £800 refund in March. Who signs it off?"
memory: 8 facts recalled in 1 ms
...
where:
  Refund approvals: Refunds over £250 require director approval; under £250 any team member
```

Builds clean. Thirteen relations, zero warnings. The wrong fact is then injected into every subsequent prompt under a `memory:` header. The graph does not merely fail to catch the error — it launders it into authoritative-looking context and freezes it there. (The elapsed-time figure is machine-dependent; the counts and the served text are not.)

**Stopping rule:** if you cannot gate the extraction, do not build the graph. You are not choosing between two retrieval architectures at that point; you are choosing between a system whose errors are visible per-answer and one whose errors are permanent and dressed as structure.

**What a gate looks like:**

- *Mechanical:* no unresolved edges (exit non-zero, not a printed warning); every golden question returns its expected answer; extraction is deterministic for unchanged input.
- *Judgment:* every fact traces to a line in a **non-superseded** source document. A script cannot do this one. It needs a reader with no stake in the extraction — which is the same argument canon makes for a fresh-context evaluator at sprint close.

One honest boundary on that last point: spotting that a fluent, correctly-formatted fact was lifted from a superseded revision is citation judgment, not an exit code. Whether a small, cheap model can do it reliably is **untested here** — `claude-haiku-4-5` was unavailable in the harness this playbook was written from. Budget the gate on the assumption it needs a capable reader until you have measured otherwise.

---

## Signal Table

| Signal | Vector RAG | Graph RAG |
|---|---|---|
| Answer lives in one passage | ✅ | overkill |
| Answer must be composed from ≥2 docs that don't cite each other | ✗ | ✅ |
| Corpus is large but flat | ✅ (rerank) | no help |
| Vocabulary still moving | ✅ | expensive |
| Ontology governed externally | fine | ✅ strong |
| Edges already in a database | ✅ query it | unnecessary |
| No gate on extraction | ✅ safer | ⚠️ don't |
| Errors must be auditable per answer | ✅ | needs a build-time gate |

---

## Reading The Vendor Literature

The most-cited benchmark in this space is *GraphRAG in Practice* (TigerGraph, Jul 2026, 36pp). Its taxonomy of workload shapes is genuinely useful, and it deserves credit for naming where its own product does not help — single-document Q&A, FAQ and helpdesk systems, and "independent records" such as equipment manuals or contracts reviewed in isolation all showed little advantage.

Discount its effect sizes, for three reasons.

**It is hackathon data.** The paper states retrieval architecture was "the only intentional variable" while also stating teams "selected their own use cases, modeled their own data, and designed retrieval workflows." Each team built both the graph and its own vector baseline, at a Graph RAG hackathon. Nobody tunes the baseline they are trying to beat. The confound is never addressed.

**The headline is not like-for-like.** The 80.7% average token reduction compares a hand-modelled traversal against an untuned top-*k* chunk dump. Most of that gap is reachable in plain vector RAG with a reranker and a smaller *k*. The paper never tests a reranked baseline.

**The build side is absent.** A term audit across all 36 pages returns zero occurrences of every term a costing of Graph RAG would require:

```
extract 0    ontolog 0   schema 0    reindex 0   stale 0
chunk 0      rerank 0    hop count 0 win rate 0  statistical 0
confidence interval 0    baseline tun 0
```

Reproduce it against your own copy of the PDF — the counts above are the only claim in this playbook you cannot check from a public repo:

```bash
pdftotext -layout GraphRAG.pdf - | grep -ic <term>
```

("entity resolution" appears once — in the About-TigerGraph blurb, not the methodology.) Extraction cost, ontology design, entity resolution, and re-extraction on document change are the line items where Graph RAG projects actually fail, and none is priced. Quality claims are qualitative throughout: the findings chapter contains two numbers, both about tokens.

One further caution. Scoring connected evidence with LLM-as-a-Judge is structurally sympathetic to connected evidence — a fluent answer carrying a clean relationship chain reads better whether or not it is correct. The metric and the treatment share a mechanism, which is the same defect canon's README describes in a test that reads its expected value from the code it is testing.

Treat the paper as a good taxonomy of workload shapes and a poor source of effect sizes.

---

## Worked Example — canon Itself

canon fails test 1 at the first question. `sprint start` reads the whole ticket into context, so at single-ticket scope there is nothing to retrieve; every answer is already co-present. It fails test 2 as well: the relationships a "why is this file like this?" question traverses are already materialised in `git log` and in `.tickets/`, which is what `tkt why` walks.

Both conclusions were reached independently before this playbook existed and are recorded in `DECISIONS.md` — `t-cdeb` (2026-07-31) rejected a derived SQLite store as "a second, driftable store plus an embedding-dependency chain," and `t-3b69` (2026-08-13) parked ranked recall as a non-fix at single-ticket scope. This playbook does not revisit those decisions; it explains the general procedure that produces them.

The reverse case is worth stating because it is easy to over-generalise from canon's own answer. A corpus governed by an external standard — where requirements cross-reference each other, exceptions reference other exceptions, and taxonomies are published hierarchies — passes tests 1, 2 and 3 cleanly, with test 3 passing for the strongest possible reason: a standards body maintains the ontology. Such a domain earns a graph. It also inherits test 4's obligation in full, because its characteristic failure is not a crash but a fluent, well-cited answer that is wrong because a threshold came from a superseded revision.

That is where the two halves compose: a graph for retrieval, and an independent reader gating the extraction.

---

## Summary

1. **Single-chunk test** — can one passage answer it? >80% yes, stop, use vector RAG.
2. **Already materialised?** — if the edges are in a system of record, query it; build nothing.
3. **Ontology stable?** — if the vocabulary still moves, the extraction bill repeats. Externally governed ontologies are the strongest yes.
4. **Gate on extraction?** — if not, don't build the graph. Query-time errors are visible; build-time errors are permanent.

Corpus size appears in none of them.
