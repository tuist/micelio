# Mimic stubs are declared here so they are copied before any test loads.
#
# The list is short on purpose. Almost everything in this suite runs against
# the real thing — a real `git` binary, a real object store, a real HTTP
# server — because that is what catches the bugs that matter. Stubs are
# reserved for conditions that cannot otherwise be produced on demand: an
# identity provider that is unreachable, object storage that fails mid-write.
Mimic.copy(Micelio.Auth.JWKS)
Mimic.copy(Micelio.ObjectStore)
Mimic.copy(Req)

ExUnit.start(capture_log: true)
