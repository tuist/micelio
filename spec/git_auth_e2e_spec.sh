# shellcheck shell=bash

Describe 'browser Git authentication onboarding'
  It 'registers a public client and authenticates a real push without touching user Git configuration'
    repo=$(new_repo)
    source=$(make_source)
    clone=$(mktemp -d)/clone

    When run bash -c "
      set -euo pipefail
      test \"\$GIT_CONFIG_GLOBAL\" = \"\$E2E_GITCONFIG\"
      test ! -e \"\$HOME/.gitconfig\" || test \"\$GIT_CONFIG_GLOBAL\" != \"\$HOME/.gitconfig\"
      git config --global http.\"\$E2E_HTTPS_URL\".sslCAInfo \"\$CURL_CA_BUNDLE\"
      PATH=\"\$E2E_GIT_HELPER_DIR:\$PATH\" ./scripts/configure-micelio-git --url \"\$E2E_HTTPS_URL\" --dynamic-registration
      test \"\$(git config --global --get credential.\"\$E2E_HTTPS_URL\".oauthClientId)\" = e2e-dynamic-client
      admin \"\$NODE1_ADMIN_URL\" POST /repositories -d '{\"repository\":\"$repo\"}' >/dev/null
      cd '$source'
      git remote add origin \"\$E2E_HTTPS_URL/$repo.git\"
      PATH=\"\$E2E_GIT_HELPER_DIR:\$PATH\" git push -q origin main
      PATH=\"\$E2E_GIT_HELPER_DIR:\$PATH\" git clone -q \"\$E2E_HTTPS_URL/$repo.git\" '$clone'
      cat '$clone/README.md'
    "

    The status should equal 0
    The output should include '# e2e'
  End
End
