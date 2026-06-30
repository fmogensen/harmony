#!/usr/bin/env bash
# Test: domain-launchd installs entries from manifest AND prunes orphan plists
# (the dk.fmogensen.runner cleanup mechanism). Uses a fake launchctl shim so
# the test doesn't require real launchd interaction.

set -e
source "$(dirname "$0")/helpers.sh"

t_setup

# Override LAUNCHD paths to live inside the sandbox.
export HARMONY_LAUNCHD_DIR="${T_FAKE_HOME}/Library/LaunchAgents"
export HARMONY_LAUNCHD_RUNNERS_DIR="${T_FAKE_HOME}/Library/Application Support"
mkdir -p "$HARMONY_LAUNCHD_DIR" "$HARMONY_LAUNCHD_RUNNERS_DIR"

# Fake launchctl: log every invocation to a file, succeed everything except
# `print` for an "unloaded" label.
FAKE_LAUNCHCTL_LOG="${T_TMPDIR}/launchctl.log"
FAKE_LAUNCHCTL_LOADED_FILE="${T_TMPDIR}/launchctl.loaded"
touch "$FAKE_LAUNCHCTL_LOADED_FILE"

FAKE_BIN="${T_TMPDIR}/fakebin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/launchctl" <<'SHIM'
#!/usr/bin/env bash
echo "$@" >> "${FAKE_LAUNCHCTL_LOG}"
case "$1" in
    print)
        # $2 is "gui/$uid/label". Check if label is in loaded set.
        label="${2##*/}"
        grep -qx "$label" "${FAKE_LAUNCHCTL_LOADED_FILE}" && exit 0
        exit 1
        ;;
    bootstrap)
        # bootstrap gui/$uid /path/to/plist.plist
        plist="$3"
        label="$(basename "$plist" .plist)"
        echo "$label" >> "${FAKE_LAUNCHCTL_LOADED_FILE}"
        ;;
    bootout)
        # bootout gui/$uid/label
        label="${2##*/}"
        grep -vx "$label" "${FAKE_LAUNCHCTL_LOADED_FILE}" > "${FAKE_LAUNCHCTL_LOADED_FILE}.tmp" || true
        mv "${FAKE_LAUNCHCTL_LOADED_FILE}.tmp" "${FAKE_LAUNCHCTL_LOADED_FILE}"
        ;;
esac
exit 0
SHIM
chmod +x "${FAKE_BIN}/launchctl"
export FAKE_LAUNCHCTL_LOG FAKE_LAUNCHCTL_LOADED_FILE
export HARMONY_LAUNCHCTL_CMD="${FAKE_BIN}/launchctl"

# Test prefix narrower than default to avoid collisions with anything in tests.
export HARMONY_LABEL_PREFIX="dk.harmonytest"

# ---- Setup: 1 desired entry in manifest + 1 orphan plist already installed ----

# Manifest declares a "wanted" launchd entry.
mkdir -p "${T_FAKE_CONFIG}/launchd"
cat > "${T_FAKE_CONFIG}/launchd/wanted.plist.template" <<'TMPL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dk.harmonytest.wanted</string>
  <key>ProgramArguments</key>
  <array>
    <string>${HOME}/code/harmony-config/launchd/wanted.run.sh</string>
  </array>
</dict>
</plist>
TMPL
cat > "${T_FAKE_CONFIG}/launchd/wanted.run.sh.template" <<'TMPL'
#!/usr/bin/env bash
echo "wanted run for user ${HOME}"
TMPL

t_write_manifest '{
  "_schema_version": 1,
  "marketplaces": [],
  "plugins": [],
  "settings": { "values": {}, "derived": [] },
  "launchd": [
    {
      "label":  "dk.harmonytest.wanted",
      "plist":  "launchd/wanted.plist.template",
      "runner": "launchd/wanted.run.sh.template"
    }
  ]
}'

# Pre-existing orphan plist (simulates the dk.fmogensen.runner leftover).
cat > "${HARMONY_LAUNCHD_DIR}/dk.harmonytest.orphan.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dk.harmonytest.orphan</string>
</dict>
</plist>
EOF
mkdir -p "${HARMONY_LAUNCHD_RUNNERS_DIR}/dk.harmonytest.orphan"
echo "orphan content" > "${HARMONY_LAUNCHD_RUNNERS_DIR}/dk.harmonytest.orphan/run.sh"
echo "dk.harmonytest.orphan" >> "${FAKE_LAUNCHCTL_LOADED_FILE}"

# A plist outside our prefix that must be left alone.
cat > "${HARMONY_LAUNCHD_DIR}/com.apple.something.plist" <<'EOF'
<plist></plist>
EOF

# ---- Run apply ----

"$HARMONY" apply >/dev/null 2>&1 || t_fail "harmony apply exited non-zero"

# ---- Assertions ----

# 1. Wanted plist installed.
[[ -f "${HARMONY_LAUNCHD_DIR}/dk.harmonytest.wanted.plist" ]] \
    || t_fail "wanted plist not installed"

# 2. Wanted runner installed and executable.
[[ -x "${HARMONY_LAUNCHD_RUNNERS_DIR}/dk.harmonytest.wanted/run.sh" ]] \
    || t_fail "wanted runner script not installed/executable"

# 3. Template variables expanded in the runner.
grep -q "${T_FAKE_HOME}" "${HARMONY_LAUNCHD_RUNNERS_DIR}/dk.harmonytest.wanted/run.sh" \
    || t_fail "HOME variable not expanded in runner template"

# 4. launchctl bootstrap was called for wanted.
grep -q "bootstrap.*dk.harmonytest.wanted" "${FAKE_LAUNCHCTL_LOG}" \
    || t_fail "expected launchctl bootstrap for wanted label"

# 5. Orphan plist PRUNED (the runner.plist cleanup mechanism in action).
[[ ! -f "${HARMONY_LAUNCHD_DIR}/dk.harmonytest.orphan.plist" ]] \
    || t_fail "orphan plist NOT pruned"
[[ ! -d "${HARMONY_LAUNCHD_RUNNERS_DIR}/dk.harmonytest.orphan" ]] \
    || t_fail "orphan runner directory NOT pruned"

# 6. launchctl bootout was called for the orphan.
grep -q "bootout.*dk.harmonytest.orphan" "${FAKE_LAUNCHCTL_LOG}" \
    || t_fail "expected launchctl bootout for orphan label"

# 7. SAFETY: out-of-prefix plist was NOT touched.
[[ -f "${HARMONY_LAUNCHD_DIR}/com.apple.something.plist" ]] \
    || t_fail "FATAL: harmony touched a plist outside its label prefix"

# 8. Idempotency: re-apply does nothing harmful.
"$HARMONY" apply >/dev/null 2>&1 || t_fail "harmony apply (2nd) exited non-zero"
[[ -f "${HARMONY_LAUNCHD_DIR}/dk.harmonytest.wanted.plist" ]] \
    || t_fail "wanted plist disappeared on re-apply"

# 9. verify green.
"$HARMONY" verify >/dev/null 2>&1 || t_fail "verify reported drift after apply"

t_pass
