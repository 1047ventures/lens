#!/bin/zsh
# Run this yourself, once, on Sean's Mac:   ./tools/setup-github-secrets.sh
# It asks for each secret (what you type is hidden) and stores it encrypted in GitHub with `gh`.
# Nothing is written to disk except a temporary certificate export that is deleted right away.
set -euo pipefail
REPO="1047ventures/lens"
SIGNING="$HOME/Desktop/Lens signing"

echo "Setting up the secrets GitHub needs to build Emma's requests and ship updates."
echo

echo "1/5  Anthropic API key for the coding agent (console.anthropic.com → API Keys; make a separate one named 'Lens GitHub'):"
read -rs VALUE; echo; gh secret set ANTHROPIC_API_KEY -R "$REPO" --body "$VALUE"; unset VALUE

echo "2/5  Choose a password to protect the exported signing certificate (any strong password; you won't need it again):"
read -rs P12PW; echo
TMP=$(mktemp -d)
/usr/bin/openssl x509 -inform der -in "$SIGNING/developer_id.cer" -out "$TMP/cert.pem"
P12PW="$P12PW" /usr/bin/openssl pkcs12 -export -inkey "$SIGNING/developer_id.key" -in "$TMP/cert.pem" \
  -name "Developer ID Application: sean kelly (J55RP92WN6)" -out "$TMP/cert.p12" -passout env:P12PW
base64 -i "$TMP/cert.p12" | gh secret set DEVELOPER_ID_P12 -R "$REPO"
gh secret set DEVELOPER_ID_P12_PASSWORD -R "$REPO" --body "$P12PW"
rm -rf "$TMP"; unset P12PW

echo "3/5  Your Apple ID email (the developer account):"
read -r VALUE; gh secret set APPLE_ID -R "$REPO" --body "$VALUE"; unset VALUE

echo "4/5  An app-specific password for notarizing (appleid.apple.com → Sign-In and Security → App-Specific Passwords):"
read -rs VALUE; echo; gh secret set APPLE_APP_PASSWORD -R "$REPO" --body "$VALUE"; unset VALUE

echo "5/5  A GitHub token for publishing releases: github.com/settings/personal-access-tokens/new →"
echo "     Only select repositories: 1047ventures/lens-releases → Permissions: Contents: Read and write. Paste it:"
read -rs VALUE; echo; gh secret set RELEASES_TOKEN -R "$REPO" --body "$VALUE"; unset VALUE

echo
echo "Done. Last step: install the Claude app on the repo: https://github.com/apps/claude → Configure → 1047ventures/lens"
