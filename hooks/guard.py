#!/usr/bin/env python3
"""agent-secret-guard — PreToolUse hook for AI coding agents (Claude Code format).

Blocks the agent from reading or editing secret files and from bypassing
git guardrails (pre-commit hooks, force pushes). Pure Python 3 stdlib.

Contract (Claude Code hooks): the payload arrives as JSON on stdin.
  exit 0 -> allow the tool call
  exit 2 -> block it; stderr is shown to the agent as the reason
"""

from __future__ import annotations

import json
import posixpath
import re
import shlex
import sys
from typing import NoReturn

FILE_TOOLS = frozenset(
    {"Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "Grep", "Glob"}
)
SAFE_BASENAMES = frozenset({".env.example", ".env.sample", ".env.template"})
SECRET_BASENAMES = frozenset({".npmrc", ".pypirc", "credentials.json"})
SSH_KEY_PREFIXES = ("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")
SECRET_EXTENSIONS = (".pem", ".key", ".p12", ".pfx")

GIT_GLOBAL_VALUE_OPTS = frozenset(
    {"-C", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--exec-path"}
)
GIT_SUB_VALUE_OPTS = frozenset(
    {
        "-m",
        "--message",
        "-F",
        "--file",
        "-C",
        "--reuse-message",
        "-c",
        "--reedit-message",
        "--author",
        "--date",
        "--trailer",
        "--fixup",
        "--squash",
        "--cleanup",
        "-o",
        "--push-option",
        "--receive-pack",
        "--exec",
        "--repo",
    }
)
SEGMENT_SEPARATORS = frozenset({";", "|", "||", "&", "&&", "\n", "(", ")"})


def block(reason: str) -> NoReturn:
    """Print a guardrail block reason to stderr and exit with code 2."""
    sys.stderr.write(f"agent-secret-guard: blocked: {reason}\n")
    raise SystemExit(2)


def is_secret_path(raw: str) -> bool:
    """Return True when raw looks like a secret file, key, or credential directory."""
    p = raw.rstrip("/") if raw != "/" else "/"
    base = posixpath.basename(p)

    if base in SAFE_BASENAMES or base.endswith(".pub"):
        return False

    parts = [seg for seg in p.split("/") if seg]
    if ".ssh" in parts:
        return True
    if parts and parts[-1] == ".aws":
        return True
    if any(parts[i : i + 2] == [".aws", "credentials"] for i in range(len(parts) - 1)):
        return True
    if any(parts[i : i + 2] == [".config", "gcloud"] for i in range(len(parts) - 1)):
        return True

    if base == ".env" or base.startswith(".env."):
        return True
    if base.startswith(".env") and any(ch in base for ch in "*?["):
        return True
    if base.startswith(SSH_KEY_PREFIXES) or base.endswith(SECRET_EXTENSIONS):
        return True
    if base in SECRET_BASENAMES:
        return True
    return ("service-account" in base or "service_account" in base) and base.endswith(
        ".json"
    )


def check_bash_secrets(command: str) -> None:
    """Block bash commands whose tokens reference a secret path."""
    for tok in re.split(r'[;|&\n<>()"\'`=\s]+', command):
        if tok and is_secret_path(tok):
            block(
                f"command references secret file '{tok}'. "
                "Ask the user to handle secrets outside the agent."
            )


def tokenize_segments(command: str) -> list[list[str]]:
    """Split a shell command into command segments using POSIX shlex rules."""
    lx = shlex.shlex(command, posix=True, punctuation_chars="();<>|&\n")
    lx.whitespace_split = True
    lx.whitespace = " \t\r"
    lx.commenters = ""
    try:
        tokens = list(lx)
    except ValueError:
        block("could not parse shell command (unclosed quote; failing closed)")

    segments: list[list[str]] = []
    cur: list[str] = []
    for tok in tokens:
        if tok in SEGMENT_SEPARATORS or (tok and set(tok) <= set(";|&()\n")):
            if cur:
                segments.append(cur)
                cur = []
        else:
            cur.append(tok)
    if cur:
        segments.append(cur)
    return segments


def check_git_config_opt(opt: str) -> None:
    """Block git -c / --config-env overrides targeting core.hooksPath."""
    if opt.lower().startswith("core.hookspath="):
        block("overriding core.hooksPath disables the repository's git hooks.")


def check_git_segment(tokens: list[str]) -> None:
    """Block git commit/push guardrail bypasses and force pushes in one segment."""
    git_idx = next(
        (i for i, t in enumerate(tokens) if t == "git" or t.endswith("/git")), None
    )
    if git_idx is None:
        return

    sub = ""
    i = git_idx + 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-c":
            if i + 1 < len(tokens):
                check_git_config_opt(tokens[i + 1])
            i += 2
        elif tok.startswith("-c") and len(tok) > 2:
            check_git_config_opt(tok[2:])
            i += 1
        elif tok == "--config-env":
            if i + 1 < len(tokens):
                check_git_config_opt(tokens[i + 1])
            i += 2
        elif tok.startswith("--config-env="):
            check_git_config_opt(tok.split("=", 1)[1])
            i += 1
        elif tok in GIT_GLOBAL_VALUE_OPTS:
            i += 2
        elif tok.startswith("-"):
            i += 1
        else:
            sub = tok
            i += 1
            break

    if sub not in {"commit", "push"}:
        return

    after_double_dash = False
    while i < len(tokens):
        tok = tokens[i]
        if not after_double_dash:
            if tok == "--":
                after_double_dash = True
                i += 1
                continue
            if tok in GIT_SUB_VALUE_OPTS:
                i += 2
                continue
            if tok == "--no-verify":
                block(
                    f"'git {sub} --no-verify' skips the repository's git hooks. "
                    "Fix the hook failure instead."
                )
            if tok == "--force":
                if sub == "push":
                    block(
                        "force push rewrites shared history. "
                        "Use --force-with-lease if you really need it."
                    )
                i += 1
                continue
            if tok.startswith("--"):
                i += 1
                continue
            if tok.startswith("-") and len(tok) > 1:
                flags = tok[1:]
                # Stop scanning short flags at value-taking options like -mfoo.
                for idx, ch in enumerate(flags):
                    if sub == "commit" and ch == "n":
                        block(
                            "'git commit -n' skips the repository's git hooks. "
                            "Fix the hook failure instead."
                        )
                    if sub == "push" and ch == "f":
                        block(
                            "force push rewrites shared history. "
                            "Use --force-with-lease if you really need it."
                        )
                    if sub == "commit" and ch in "mFCc":
                        # If the value is separate (e.g. -am "msg"), consume next token.
                        if idx == len(flags) - 1:
                            i += 1
                        break
                i += 1
                continue

        if sub == "push" and tok.startswith("+"):
            block(f"force-push refspec '{tok}' rewrites shared history.")
        i += 1


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        block("could not parse the hook payload (failing closed)")

    if not isinstance(payload, dict) or not isinstance(payload.get("tool_name"), str):
        block("could not parse the hook payload (failing closed)")

    tool = payload["tool_name"]
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}

    if tool in FILE_TOOLS:
        keys = ["file_path", "notebook_path", "path", "glob"]
        if tool == "Glob":
            keys.append("pattern")
        for key in keys:
            val = tool_input.get(key)
            if isinstance(val, str) and val and is_secret_path(val):
                block(
                    f"{tool} on secret file '{val}'. "
                    "Ask the user to handle secrets outside the agent."
                )
    elif tool == "Bash":
        command = tool_input.get("command")
        if isinstance(command, str) and command:
            check_bash_secrets(command)
            for seg in tokenize_segments(command):
                check_git_segment(seg)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
