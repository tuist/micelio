+++
title = "Faster website shipping"
description = "The Micelio website is published from the main branch through Cloudflare Workers."
template = "page.html"
+++

# 🚀 Faster website shipping

The Micelio website is published from the main branch through Cloudflare
Workers at micelio.dev.

## What changed

Website changes now run through a dedicated deployment workflow. The workflow
installs the static-site and headless-browser tooling, generates social-preview
images, builds the site, and publishes the resulting static assets.

## Why

Documentation and operational guidance are part of the product. A small,
repeatable release path keeps the public site aligned with the source without
adding a separate publishing system.
