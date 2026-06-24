# SQL Server Performance Optimization — Case Studies

Hands-on query tuning on a **50 GB SQL Server database**, documented end to end:
**problem → diagnosis → fix → measured result.**

Each case study takes a slow, production-style query and makes it measurably
faster — with before/after metrics and execution plans attached. The focus is a
**repeatable diagnostic process**, not one-off tricks.

---

## Case studies

| #  | Problem (symptom)            | Logical reads (before → after) | Duration (before → after) | Technique |
|----|------------------------------|--------------------------------|---------------------------|-----------|
| [01](case-01-slow-user-profile/README.md) | Slow user-profile page | 4,186,198 → 7 | 19,402 ms → 6 ms | Covering index on `Posts (OwnerUserId, CreationDate DESC)`; eliminates both the scan and the Top N Sort |
| [02](case-02-slow-tag-page/README.md) | Slow tag page (tag listing) | 4,186,226 → 34 | ≈27,000 ms → ≈100 ms | Non-SARGable `LIKE '%<tag>%'` diagnosis + ordered covering index keyed on `CreationDate DESC` for an early-exit scan |

Logical reads is the headline metric because it is deterministic and
hardware-independent — anyone can reproduce these numbers on any machine.
Duration is reported as a secondary, hardware-dependent metric.

> Each row links to a full case write-up (problem → baseline → diagnosis → fix →
> validation → takeaway) with execution plans in its `results/` folder.

---

## The dataset

I use the [Stack Overflow 2013 public data dump](https://www.brentozar.com/archive/2015/10/how-to-download-the-stack-overflow-database-via-bittorrent/)
(~50 GB) as a stand-in for a real client database. It has real data
distributions, real skew, and minimal indexing — close to what an untuned
production system actually looks like.

Key tables: `Posts` (~17M rows), `Votes` (~53M rows), `Comments` (~24M rows),
`Users` (~2.5M rows), `Badges`.

The full inventory of the database — sizes, row counts, existing indexes,
relationships, statistics state, and server configuration — is in
[`discovery/discovery-findings.md`](discovery/discovery-findings.md), produced by
the read-only [`scripts/discovery.sql`](scripts/discovery.sql).

## Engagement scenario

> **Client:** a growing Q&A community platform. The database has grown to ~50 GB.
>
> **Symptoms:** user-profile pages, question lists, and tag pages load slowly,
> with occasional timeouts under load.
>
> **Constraints:** no dedicated DBA — the dev team shipped features but never
> tuned the database. Application code is off-limits; index additions are allowed.
>
> **Goal:** find the worst-performing queries, fix them with measurable proof,
> and deliver a short report the team can understand.

Every case below maps to a symptom from this scenario.

## Methodology

1. **Discovery** — inventory the database (sizes, row counts, existing indexes,
   relationships, statistics, server config) without changing anything.
   See [`scripts/discovery.sql`](scripts/discovery.sql) and the written findings
   in [`discovery/discovery-findings.md`](discovery/discovery-findings.md).
2. **Baseline** — capture the original state and the "before" metrics for each
   target query (each case has its own `baseline.sql`).
3. **Diagnose** — read the execution plan and wait stats; identify the root
   cause (missing index, non-SARGable predicate, key lookups, bad estimates,
   parameter sniffing, stale statistics…).
4. **Optimize** — apply **one** change, then re-measure, so every gain is
   attributable.
5. **Validate** — confirm the improvement and check for regressions (write cost,
   side effects on other queries).
6. **Report** — document the case with a before/after metrics table and plans,
   using [`templates/case-template-README.md`](templates/case-template-README.md).

Full measurement rules (cold cache, three-run protocol, what goes in `results/`)
are in [`lab-protocol.md`](lab-protocol.md).

## Repository structure

```
.
├── README.md                       ← this file
├── lab-protocol.md                 ← how every measurement is taken
├── discovery/
│   └── discovery-findings.md       ← full database inventory (Phase 1)
├── scripts/
│   └── discovery.sql               ← read-only inventory script
├── templates/
│   └── case-template-README.md     ← the write-up template each case follows
├── case-01-slow-user-profile/
│   ├── README.md                   ← full case write-up
│   ├── baseline.sql                ← measurement script (before & after)
│   └── results/                    ← .sqlplan files, plan screenshots, raw IO/TIME
└── case-02-slow-tag-page/
    ├── README.md
    ├── baseline.sql
    └── results/
```

## Environment

- SQL Server 2019 (15.0), Enterprise Evaluation Edition
- Database compatibility level 150
- Query Store enabled for plan/metric history
- All measurements taken on an isolated lab instance (never production)

## Tooling

- [First Responder Kit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)
  (`sp_Blitz`, `sp_BlitzIndex`, `sp_BlitzCache`)
- [`sp_WhoIsActive`](https://github.com/amachanic/sp_whoisactive)
- Query Store
- SQL Server Management Studio (SSMS)

---

*This repository is a portfolio of demonstration work on a public dataset. It
does not contain any real client data. The "client" and engagement scenario are
illustrative framing for the case studies.*
