# Prisma Engine — s390x (IBM Z / LinuxONE) Build

> **Maintainer:** Gomathi Bose — Mainframe & Platform Architect, [PopUp Mainframe](https://www.popupmainframe.com)
> **Status:** Production — used in PopUp Mainframe's FastTrack dual-architecture pipeline (x86_64 + s390x)  (https://docs.popup-mainframe.com/FastTrack/#fasttrack-dashboard)

---

## What this is

[Prisma](https://www.prisma.io/) is a modern TypeScript ORM for Node.js. Its core query engine is written in Rust and distributed as platform-specific binaries. As of 2025, Prisma does **not** officially publish a prebuilt binary for `linux-musl-s390x` or `linux-openssl-3.0.x-s390x`.

This repository documents how to cross-compile and package the Prisma query engine binary for **s390x Linux (RHEL 9 / IBM Z and LinuxONE)**, along with the patches, build environment, and integration steps needed to use it within a Node.js application.

This work was developed to support the [FastTrack](https://docs.popup-mainframe.com/FastTrack/#fasttrack-dashboard) application — a web platform for managing on-demand PopUp z/OS environments(perform actions such as starting and stopping the PopUp, taking a snapshot, and switching to a snapshot) — running natively on IBM Z infrastructure.

---

## Supported Platforms

| Platform                    | Architecture | Tested OS          | Status     |
|-----------------------------|--------------|--------------------|------------|
| `linux-openssl-1.1.x`       | x86_64       | Ubuntu 22.04       | ✅ Official |
| `linux-openssl-3.0.x`       | x86_64       | RHEL 9             | ✅ Official |
| `linux-openssl-3.0.x`       | **s390x**    | **RHEL 9.6**       | ✅ This repo |

---

## Problem Statement

When deploying a Node.js + Prisma application on IBM Z (s390x architecture), the standard `npx prisma generate` step fails at runtime because:

1. Prisma downloads prebuilt engine binaries — none of which are compiled for s390x.
2. Attempting to compile the Prisma engine from source on s390x fails due to dependency issues in the `ring` cryptographic crate.
3. The `pkg` packager (used for producing self-contained Node.js binaries) has no s390x target, requiring a custom shell-launcher fallback approach.

---

## Fixes and Patches Applied

| # | Issue | Root Cause | Fix Applied |
|---|-------|-----------|-------------|
| 1 | `ring` crate fails to compile on s390x | `ring` uses platform-specific assembly; s390x not in its supported list | Pinned to `ring = "0.16.20"` + forced `features = ["less-safe-key"]`; alternatively patched `Cargo.toml` to use `aws-lc-rs` as the crypto backend |
| 2 | `openssl-sys` fails to link | RHEL 9 ships OpenSSL 3.x; Prisma engine expects 1.1.x paths by default | Set `OPENSSL_DIR`, `OPENSSL_LIB_DIR`, `OPENSSL_INCLUDE_DIR` env vars explicitly before `cargo build` |
| 3 | `cargo build` fails with linker error for `s390x-unknown-linux-gnu` | Missing cross-linker toolchain | Used native compilation directly on an s390x RHEL 9 host (IBM LinuxONE Community Cloud) rather than cross-compilation |
| 4 | `CARGO_HOME` / `.cargo/registry` path conflicts | Shared build environments have permission issues on `.cargo` cache | Isolated `CARGO_HOME` per build via env override |
| 5 | `pkg` does not support s390x target | `pkg` (Vercel) lacks s390x Node.js SEA target | Replaced with `esbuild` bundle + shell launcher script that resolves and invokes the correct binary at runtime |

---

## Build Environment

- **Host architecture:** s390x (IBM Z / LinuxONE)
- **OS:** Red Hat Enterprise Linux 9.6
- **Rust toolchain:** `stable` via `rustup` (`rustup target add s390x-unknown-linux-gnu`)
- **Cargo version:** 1.78+
- **Node.js:** 20.x LTS
- **Prisma version tested:** 5.x

---

## Build Script


---

## Context: PopUp Mainframe & FastTrack

**PopUp Mainframe** is a product company delivering on-demand z/OS environments built on IBM zD&T/zPDT. **FastTrack** is its web management platform, running natively on IBM Z infrastructure alongside the z/OS workloads it manages.

Enabling Prisma on s390x was a prerequisite for deploying FastTrack as a native s390x service, eliminating the need to run the application layer on x86_64 and routing traffic cross-architecture.

This work is part of a broader dual-architecture (x86_64 + s390x) build pipeline detailed in the blog post **["We Built It Anyway"](https://www.popupmainframe.com)** — an account of what it takes to bring modern Node.js tooling to IBM Z.

---

## Contributing / Upstream Intent

The goal is to see s390x included as an officially supported target in the upstream [prisma/prisma-engines](https://github.com/prisma/prisma-engines) repository. An upstream issue/PR is in preparation — [prisma github issue opened](https://github.com/prisma/prisma-engines/issues/5858)

Community feedback, testing on other s390x distributions (Ubuntu on Z), and collaboration with the [IBM Linux on Z open source team](https://github.com/linux-on-ibm-z) are all welcome.

---

## License

Apache License 2.0 — see [LICENSE](./LICENSE)


---

*Maintained by [Gomathi Bose](https://www.linkedin.com/in/) · [PopUp Mainframe](https://www.popupmainframe.com) · Chennai, India*
