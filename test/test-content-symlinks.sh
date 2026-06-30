#!/usr/bin/env bash
# Test: domain-content creates symlinks, replaces wrong ones, backs up real files.

set -e
source "$(dirname "$0")/helpers.sh"

t_setup

# Set up content in the fake config repo.
mkdir -p "${T_FAKE_CONFIG}/content/skills/sample-skill"
echo "# sample skill" > "${T_FAKE_CONFIG}/content/skills/sample-skill/SKILL.md"

mkdir -p "${T_FAKE_CONFIG}/content/agents"
echo "# agent: alfred" > "${T_FAKE_CONFIG}/content/agents/alfred.md"

mkdir -p "${T_FAKE_CONFIG}/content/commands"
echo "# /watch" > "${T_FAKE_CONFIG}/content/commands/watch.md"

mkdir -p "${T_FAKE_CONFIG}/settings"
echo "# global instructions" > "${T_FAKE_CONFIG}/settings/global-CLAUDE.md"

# Pre-existing state in ~/.claude/: a STALE symlink (wrong target) and a
# REAL file (must be backed up) — to test both replacement paths.
ln -s "/nonexistent/old/path/skills" "${T_FAKE_HOME}/.claude/skills"
mkdir -p "${T_FAKE_HOME}/.claude/commands"  # real dir in the way
echo "real file" > "${T_FAKE_HOME}/.claude/commands/legacy.md"

t_write_manifest '{
  "_schema_version": 1,
  "marketplaces": [],
  "plugins": [],
  "settings": { "values": {}, "derived": [] },
  "content": {
    "skills":         "content/skills",
    "agents":         "content/agents",
    "commands":       "content/commands",
    "globalClaudeMd": "settings/global-CLAUDE.md"
  }
}'

"$HARMONY" apply >/dev/null 2>&1 || t_fail "harmony apply exited non-zero"

# Assertions:

# 1. skills symlink correct (was a wrong symlink).
[[ -L "${T_FAKE_HOME}/.claude/skills" ]] || t_fail "skills is not a symlink"
actual_skills="$(readlink "${T_FAKE_HOME}/.claude/skills")"
expected_skills="${T_FAKE_CONFIG}/content/skills"
t_assert_eq "$actual_skills" "$expected_skills" "skills relinked"

# 2. agents symlink created (didn't exist).
[[ -L "${T_FAKE_HOME}/.claude/agents" ]] || t_fail "agents is not a symlink"
actual_agents="$(readlink "${T_FAKE_HOME}/.claude/agents")"
t_assert_eq "$actual_agents" "${T_FAKE_CONFIG}/content/agents" "agents linked"

# 3. commands replaced (was a real dir; should be backed up).
[[ -L "${T_FAKE_HOME}/.claude/commands" ]] || t_fail "commands is not a symlink"
t_assert_eq "$(readlink "${T_FAKE_HOME}/.claude/commands")" "${T_FAKE_CONFIG}/content/commands" "commands linked"
# Backup must exist with the legacy.md content intact.
backup_dir="$(ls -d "${T_FAKE_HOME}/.claude/commands.backup."* 2>/dev/null | head -1)"
[[ -n "$backup_dir" ]] || t_fail "no backup of original commands dir"
[[ -f "${backup_dir}/legacy.md" ]] || t_fail "legacy file not preserved in backup"

# 4. CLAUDE.md symlink created.
[[ -L "${T_FAKE_HOME}/.claude/CLAUDE.md" ]] || t_fail "CLAUDE.md is not a symlink"
actual_md="$(readlink "${T_FAKE_HOME}/.claude/CLAUDE.md")"
t_assert_eq "$actual_md" "${T_FAKE_CONFIG}/settings/global-CLAUDE.md" "CLAUDE.md linked"

# 5. Reading through the symlink works.
content="$(cat "${T_FAKE_HOME}/.claude/CLAUDE.md")"
t_assert_eq "$content" "# global instructions" "content readable via symlink"

# 6. Idempotency: re-apply is a no-op (no new backups).
"$HARMONY" apply >/dev/null 2>&1 || t_fail "harmony apply (2nd run) exited non-zero"
new_backup_count="$(ls -d "${T_FAKE_HOME}/.claude/commands.backup."* 2>/dev/null | wc -l | tr -d ' ')"
t_assert_eq "$new_backup_count" "1" "no new backup on idempotent run"

# 7. verify green.
"$HARMONY" verify >/dev/null 2>&1 || t_fail "verify reported drift after apply"

# 8. Removing a skill from the repo: link still points at the dir; skill gone.
rm -rf "${T_FAKE_CONFIG}/content/skills/sample-skill"
[[ ! -e "${T_FAKE_HOME}/.claude/skills/sample-skill" ]] || \
    t_fail "removed skill still visible through symlink"

t_pass
