# Shared by build.sh. A Developer ID signature is stable, so macOS keeps
# Bluetooth permission across rebuilds. An ad-hoc signature is a new app every time.
resolve_developer_id() {
  if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
    printf '%s\n' "$DEVELOPER_ID_APP"
    return
  fi
  local ids count
  ids="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')"
  count="$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    printf '%s\n' "$ids" | sed '/^$/d'
    return
  fi
  if [[ "$count" == "0" ]]; then
    echo "No Developer ID Application certificate in the login keychain." >&2
    echo "Install the certificate used for GrammarBar, or set DEVELOPER_ID_APP." >&2
    exit 1
  fi
  echo "Several Developer ID certificates. Set DEVELOPER_ID_APP to one of:" >&2
  printf '%s\n' "$ids" >&2
  exit 1
}
