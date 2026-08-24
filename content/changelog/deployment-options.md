+++
title = "More ways to deploy"
description = "Micelio added one-click deployment routes for several cloud platforms."
template = "page.html"
+++

# ⚡ More ways to deploy

Micelio now includes one-click deployments for Render, DigitalOcean, Heroku,
Azure, and Vercel.

## What changed

Each deployment starts a small single-node installation and asks for the object
store and authentication configuration it needs. The write-ahead log remains
the durable source of truth even in this smallest deployment shape.

## Why

Trying Micelio should not require assembling an infrastructure stack before
the Git workflow is visible. The deployment options make a small, explicit
starting point available while retaining the same storage model as larger
clusters.
