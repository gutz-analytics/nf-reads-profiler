#!/usr/bin/env bash
# .claude/hooks/guardrails.sh — PreToolUse hook for nf-reads-profiler
# Blocks destructive operations; soft-prompts risky ones.
# Exit 0 = allow (or JSON with permissionDecision)
# Exit 2 + stderr = hard block with message shown to user
set -o pipefail

REPO_ROOT="/home/ubuntu/github/nf-reads-profiler"
CLAUDE_DIR="/home/ubuntu/.claude"

HOOK_DATA=$(cat)
TOOL_NAME=$(echo "$HOOK_DATA" | jq -r '.toolName // empty')
COMMAND=$(echo "$HOOK_DATA" | jq -r '.tool_input.command // empty')
FILE_PATH=$(echo "$HOOK_DATA" | jq -r '.tool_input.file_path // empty')

block() {
  echo "GUARDRAIL BLOCKED: $1" >&2
  exit 2
}

soft_ask() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# ── Bash command guardrails ──────────────────────────────────────────────────

if [ "$TOOL_NAME" = "Bash" ] && [ -n "$COMMAND" ]; then

  # Docker destruction
  if echo "$COMMAND" | grep -qE 'docker\s+compose\s+down\s+.*-v|docker\s+compose\s+down\s+-v'; then
    block "docker compose down -v would destroy database volumes"
  fi
  if echo "$COMMAND" | grep -qE 'docker\s+volume\s+(rm|prune)'; then
    block "docker volume rm/prune would destroy database volumes"
  fi
  if echo "$COMMAND" | grep -qE 'docker\s+system\s+prune'; then
    block "docker system prune would destroy images and volumes"
  fi

  # Runaway EC2 — block direct instance launches
  if echo "$COMMAND" | grep -qE 'aws\s+ec2\s+run-instances'; then
    block "Direct ec2 run-instances is not allowed — use Batch"
  fi
  if echo "$COMMAND" | grep -qE 'aws\s+ec2\s+request-spot-instances'; then
    block "Direct spot instance requests are not allowed — use Batch"
  fi

  # Batch MaxvCpus escalation — block if value > 64
  if echo "$COMMAND" | grep -qE 'aws\s+batch\s+update-compute-environment'; then
    VCPU_VAL=$(echo "$COMMAND" | grep -oiE 'maxvcpus[=:]\s*[0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -n "$VCPU_VAL" ] && [ "$VCPU_VAL" -gt 64 ] 2>/dev/null; then
      block "MaxvCpus=$VCPU_VAL exceeds guardrail limit of 64 — raise intentionally via CFN parameter"
    fi
  fi

  # CFN stack deletion
  if echo "$COMMAND" | grep -qE 'aws\s+cloudformation\s+delete-stack'; then
    block "CloudFormation stack deletion is blocked — tear down manually if needed"
  fi

  # Disk bombs
  if echo "$COMMAND" | grep -qE '\bdd\s+if='; then
    block "dd with if= could fill disk"
  fi
  if echo "$COMMAND" | grep -qE '\bfallocate\b'; then
    block "fallocate could fill disk"
  fi
  if echo "$COMMAND" | grep -qE '\bmkfs\b'; then
    block "mkfs would destroy a filesystem"
  fi

  # Destructive operations outside the repo
  if echo "$COMMAND" | grep -qE '\brm\s+-[rR]'; then
    # Extract paths after rm flags — block if any path is outside repo
    RM_PATHS=$(echo "$COMMAND" | grep -oE 'rm\s+(-[^ ]+\s+)*(.+)' | sed 's/rm\s\+\(-[^ ]*\s\+\)*//')
    for P in $RM_PATHS; do
      # Resolve relative paths
      case "$P" in
        /*) ABS="$P" ;;
        ~/*) ABS="/home/ubuntu/${P#\~/}" ;;
        *) ABS="$REPO_ROOT/$P" ;;
      esac
      case "$ABS" in
        "$REPO_ROOT"/*|/tmp/*) ;; # allow inside repo or /tmp
        *) block "rm -r targeting path outside repo: $P" ;;
      esac
    done
  fi

  # Git destruction on main/master
  if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force.*\s+(main|master)\b|git\s+push\s+--force\s+.*\b(main|master)\b'; then
    block "Force-push to main/master is not allowed"
  fi
  if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard.*\b(main|master)\b'; then
    block "git reset --hard on main/master is not allowed"
  fi

  # Pipeline launch on AWS — soft prompt, not hard block
  if echo "$COMMAND" | grep -qE 'nextflow\s+run\b.*-profile\s+aws'; then
    soft_ask "This will launch a pipeline run on AWS Batch (costs money). Confirm?"
  fi
fi

# ── Write/Edit file guardrails ───────────────────────────────────────────────

if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  if [ -n "$FILE_PATH" ]; then

    # Sensitive files
    case "$FILE_PATH" in
      *.env|*.env.*) block "Writing to .env files is blocked — secrets risk" ;;
      *credentials*) block "Writing to credentials files is blocked" ;;
      *_key.pem|*.key) block "Writing to key files is blocked" ;;
    esac

    # Outside repo — allow repo and ~/.claude/ paths only
    case "$FILE_PATH" in
      "$REPO_ROOT"/*) ;; # inside repo, OK
      "$CLAUDE_DIR"/*) ;; # claude config, OK
      /tmp/*) ;; # temp files, OK
      *) block "Write/Edit outside repo: $FILE_PATH — only files under $REPO_ROOT are allowed" ;;
    esac
  fi
fi

# ── Default: allow ───────────────────────────────────────────────────────────
exit 0
