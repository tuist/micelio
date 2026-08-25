+++
title = "Changelog"
template = "page.html"
+++

# ✨ Changelog

Small notes about the improvements we are shipping. New entries appear here as
they land.

## 2026-08-25

### 👀 [A clearer view of a running node](@/changelog/observability.md)

Micelio now traces public requests, Git pushes, replica work, and object-store
operations. Operators can use trace-linked logs and bounded Prometheus metrics
to understand latency, failures, and throughput without exposing repository
identifiers in metric labels.

## 2026-08-24

### 🧰 [Maintenance work stays off the serving path](@/changelog/maintenance-roles.md)

Micelio now separates serving, maintenance, and future event-consumer
capabilities. Maintenance workers coordinate compaction and lookup rebuilding
without requiring a cluster leader, so a node that serves Git traffic does not
also need to run background work.

### 🖼️ [Every page now carries its own social preview](@/changelog/social-previews.md)

The website now builds a Portable Network Graphics social-preview image for
every page, using the same restrained, terminal-inspired visual language as the
site. The images are regenerated locally and in continuous integration before
Zola builds the website.

## 2026-08-20

### 🌐 [A home for Micelio](@/changelog/website-launch.md)

Micelio now has a public website with focused guides for getting started,
working with agents, hosting, and operating a cluster. The repository's full
technical reference remains the place for detailed design notes.

### ⚡ [More ways to deploy](@/changelog/deployment-options.md)

The repository now includes one-click deployments for Render, DigitalOcean,
Heroku, Azure, and Vercel. Each starts a small single-node installation and
asks for its object-storage and authentication settings.

### 🚀 [Faster website shipping](@/changelog/website-deployment.md)

The website is served from Cloudflare Workers at
[micelio.dev](https://micelio.dev). The project now includes a deployment
workflow for website changes that reach the main branch.
