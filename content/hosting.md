+++
title = "Host Micelio"
template = "page.html"
+++

# ☸️ Host Micelio

Micelio runs as an ordinary Kubernetes Deployment, not a stateful set. The
local disk can be ephemeral because every repository can be rebuilt from object
storage. Give each pod fast local storage for its warm cache, and make the log
bucket durable.

The object store must support conditional reads and writes. Amazon Simple
Storage Service, MinIO, Tigris, Cloudflare R2, and Ceph are suitable choices.

## ⚡ Deploy one node

These deployment flows configure one Micelio node, expose it on port `4000`,
and ask for the object-store credentials while the service is created. The
platform's local disk remains only a disposable cache, while the object store
keeps the repositories.

<div class="deploy-buttons">
  <a href="https://render.com/deploy?repo=https%3A%2F%2Fgithub.com%2Ftuist%2Fmicelio" aria-label="Deploy Micelio on Render">
    <img src="https://render.com/images/deploy-to-render-button.svg" alt="Deploy to Render">
  </a>
  <a href="https://cloud.digitalocean.com/apps/new?repo=https://github.com/tuist/micelio/tree/main" aria-label="Deploy Micelio on DigitalOcean App Platform">
    <img src="https://www.deploytodo.com/do-btn-blue.svg" alt="Deploy to DigitalOcean">
  </a>
  <a href="https://www.heroku.com/deploy?template=https://github.com/tuist/micelio/tree/main" aria-label="Deploy Micelio on Heroku">
    <img src="https://www.herokucdn.com/deploy/button.svg" alt="Deploy to Heroku">
  </a>
  <a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Ftuist%2Fmicelio%2Fmain%2Finfra%2Fazuredeploy.json" aria-label="Deploy Micelio on Azure">
    <img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure">
  </a>
  <a href="https://vercel.com/new/clone?repository-url=https%3A%2F%2Fgithub.com%2Ftuist%2Fmicelio&amp;project-name=micelio&amp;env=MICELIO_S3_BUCKET%2CMICELIO_S3_ENDPOINT%2CMICELIO_S3_ACCESS_KEY_ID%2CMICELIO_S3_SECRET_ACCESS_KEY%2CMICELIO_AUTH_TOKENS%2CMICELIO_ADMIN_TOKEN&amp;envLink=https%3A%2F%2Fmicelio.dev%2Fhosting%2F" aria-label="Deploy Micelio on Vercel">
    <img src="https://vercel.com/button" alt="Deploy to Vercel">
  </a>
</div>

All five forms require an object-store bucket, endpoint, access key, and secret
key. They also request `MICELIO_AUTH_TOKENS`, using the format
`token=account:read,write`; keep that token somewhere safe. The launch
configuration uses static tokens for a small single-node installation. For
OpenID Connect or a multi-node cluster, use the Kubernetes chart below.

Heroku builds the repository Dockerfile. Azure deploys the published Micelio
container image as one Container App. Vercel can run the same release image,
but its request-based containers are best kept to small evaluations rather than
large clones or long pushes. Railway's deploy button needs a published Railway
Template identifier, which cannot be created from a repository alone.

```sh
helm install micelio oci://ghcr.io/tuist/charts/micelio \
  --set objectStore.bucket=micelio \
  --set objectStore.endpoint=https://s3.eu-west-1.amazonaws.com \
  --set objectStore.existingSecret=micelio-s3 \
  --set auth.oidc.kubernetes=true \
  --set auth.oidc.audience=micelio
```

Start with one replica if you only need durability. Add replicas when you need
more read capacity. Scaling down is safe: an evicted cache simply rebuilds on
the next request.

## 🔐 Authenticate people and workloads

Micelio validates tokens but never issues them. In Kubernetes, the easiest path
is to use each workload's projected service account token. Turn on the
Kubernetes OpenID Connect provider in the chart, set an audience, and a pod
receives access to its own namespace's repositories by default.

```sh
git -c http.extraHeader="Authorization: Bearer $(cat /var/run/secrets/micelio/token)" \
  clone https://micelio.internal/acme/ios-app.git
```

For people and external services, point Micelio at your existing OpenID Connect
issuer. You can also grant read or write patterns from an account policy in the
same object store as the log.

The [chart values](https://github.com/tuist/micelio/blob/main/charts/micelio/values.yaml)
and [authentication reference](https://github.com/tuist/micelio/blob/main/docs/multi-tenancy.md)
cover the complete configuration.
