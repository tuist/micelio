+++
title = "Changelog"
template = "page.html"
+++

# ✨ Changelog

Small notes about the improvements we are shipping. New entries appear here as
they land.

## 2026-08-20

### 🌐 A home for Micelio

Micelio now has a public website with focused guides for getting started,
working with agents, hosting, and operating a cluster. The repository's full
technical reference remains the place for detailed design notes.

### ⚡ More ways to deploy

The repository now includes one-click deployments for Render, DigitalOcean,
Heroku, Azure, and Vercel. Each starts a small single-node installation and
asks for its object-storage and authentication settings.

### 🚀 Faster website shipping

The website is served from Cloudflare Workers at
[micelio.dev](https://micelio.dev). The project now includes a deployment
workflow for website changes that reach the main branch.
