+++
title = "Every page now carries its own social preview"
description = "The website creates a deterministic social-preview image for every page during the build."
template = "page.html"
+++

# 🖼️ Every page now carries its own social preview

Micelio now builds a dedicated social-preview image for every page, including
every individual changelog item.

## What changed

The website renders simple 1200 by 630 pixel cards in headless Chrome before
Zola builds the site. Each card uses the same sparse, monospaced visual
language as the website, with the page title and summary in the foreground.

## Why

Links need a useful, recognisable preview when shared in chat, social feeds, or
issue trackers. Keeping the artwork in the repository's build means it stays in
step with the page rather than relying on a manually maintained asset.

## Delivery

The generated images are build artefacts. Local builds and continuous
integration recreate them before the static website is published.
