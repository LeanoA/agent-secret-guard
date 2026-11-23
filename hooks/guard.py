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
SAFE_SUFFIXES = (".env.example", ".env.sample", ".env.template", ".pub")
SECRET_BASENAMES = frozenset({".npmrc", ".pypirc", "credentials.json"})
SSH_KEY_PREFIXES = ("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")
SECRET_EXTENSIONS = (".pem", ".key", ".p12", ".pfx")

SHELL_NAMES = frozenset({"sh", "bash", "zsh", "dash", "ksh"})
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
SEGMENT_SEPARATORS = frozenset({";", "|", "||", "&", "&&", "\n", "(", ")", "`"})
SECRET_SPLIT_RE = re.compile(r'[;|&\n<>()"\'`=\s{},]+')
GIT_CONFIG_KEY_RE = re.compile(r"^GIT_CONFIG_KEY_\d+=(.+)$")


def block(reason: str) -> NoReturn:
    """Print a guardrail block reason to stderr and exit with code 2."""
    sys.stderr.write(f"agent-secret-guard: blocked: {reason}\n")
    raise SystemExit(2)


def is_secret_path(raw: str) -> bool:
    """Return True when raw looks like a secret file, key, or credential directory."""
    collapsed = re.sub(r"/+", "/", raw)
    p = posixpath.normpath(collapsed)
    base = posixpath.basename(p)

    if base in SAFE_BASENAMES or base.endswith(SAFE_SUFFIXES):
        return False

    parts = [seg for seg in p.split("/") if seg]
    if ".ssh" in parts or ".aws" in parts:
        return True
    if any(parts[i : i + 2] == [".config", "gcloud"] for i in range(len(parts) - 1)):
        return True

    if base == ".env" or base.startswith(".env.") or base.endswith(".env") or ".env." in base:
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


def check_token_secrets(tok: str) -> None:
    """Check one shell token (splitting braces/assignments) for secret paths."""
    for part in SECRET_SPLIT_RE.split(tok):
        if part and is_secret_path(part):
            block(
                f"command references secret file '{part}'. "
                "Ask the user to handle secrets outside the agent."
            )


def strip_line_continuations(command: str) -> str:
    """Remove backslash-newline continuations outside single quotes."""
    out: list[str] = []
    in_single = False
    in_double = False
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if ch == "'" and not in_double:
            in_single = not in_single
            out.append(ch)
            i += 1
        elif ch == '"' and not in_single:
            in_double = not in_double
            out.append(ch)
            i += 1
        elif ch == "\\" and not in_single and i + 1 < n:
            nxt = command[i + 1]
            if nxt == "\n":
                i += 2
                continue
            out.append(ch)
            out.append(nxt)
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def tokenize_segments(command: str) -> list[list[str]]:
    """Split a shell command into command segments using POSIX shlex rules."""
    lx = shlex.shlex(command, posix=True, punctuation_chars="();<>|&\n`")
    lx.whitespace_split = True
    lx.whitespace = " \t\r"
    lx.commenters = ""
    try:
        tokens = list(lx)
    except ValueError:
        check_token_secrets(command)
        block("could not parse shell command (unclosed quote; failing closed)")

    segments: list[list[str]] = []
    cur: list[str] = []
    for tok in tokens:
        if tok in SEGMENT_SEPARATORS or (tok and set(tok) <= set(";|&()\n`")):
            if cur:
                segments.append(cur)
                cur = []
        else:
            cur.append(tok)
    if cur:
        segments.append(cur)
    return segments


def extract_substitutions(text: str) -> list[str]:
    """Extract inner commands from $(...) and `...` inside a token."""
    subs: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == "\\" and i + 1 < n:
            i += 2
            continue
        if text[i : i + 2] == "$(":
            depth = 1
            start = i + 2
            j = start
            while j < n and depth > 0:
                if text[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                j += 1
            if depth == 0:
                subs.append(text[start : j - 1])
            i = j
            continue
        if text[i] == "`":
            end = text.find("`", i + 1)
            if end != -1:
                subs.append(text[i + 1 : end])
                i = end + 1
                continue
        i += 1
    return subs


def check_git_config_opt(opt: str) -> None:
    """Block git -c / --config-env overrides targeting core.hooksPath."""
    if opt.lower().startswith("core.hookspath="):
        block("overriding core.hooksPath disables the repository's git hooks.")


def check_git_env_overrides(tokens: list[str]) -> None:
    """Block GIT_CONFIG_PARAMETERS / GIT_CONFIG_KEY_* targeting core.hooksPath."""
    for tok in tokens:
        if tok.startswith("GIT_CONFIG_PARAMETERS=") and "core.hookspath" in tok.lower():
            block("overriding core.hooksPath via GIT_CONFIG_PARAMETERS is not allowed.")
        m = GIT_CONFIG_KEY_RE.match(tok)
        if m and m.group(1).strip().lower() == "core.hookspath":
            block("overriding core.hooksPath via GIT_CONFIG_KEY is not allowed.")


def is_no_verify_flag(tok: str) -> bool:
    """Match --no-verify and its unambiguous git prefix (--no-veri, --no-verif)."""
    return tok.startswith("--no-veri") and "--no-verify".startswith(tok)


def is_force_flag(tok: str) -> bool:
    """Match --force and its unambiguous prefix (--forc)."""
    return tok.startswith("--forc") and "--force".startswith(tok)


def check_git_segment(tokens: list[str]) -> set[int]:
    """Block git guardrails in one segment; return indices of literal -m message args."""
    check_git_env_overrides(tokens)

    git_idx = next(
        (
            i
            for i, t in enumerate(tokens)
            if "=" not in t and (t == "git" or t.endswith("/git"))
        ),
        None,
    )
    if git_idx is None:
        return set()

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
        return set()

    literal_msg_indices: set[int] = set()
    after_double_dash = False
    while i < len(tokens):
        tok = tokens[i]
        if not after_double_dash:
            if tok == "--":
                after_double_dash = True
                i += 1
                continue
            if tok in {"-m", "--message"}:
                if i + 1 < len(tokens):
                    literal_msg_indices.add(i + 1)
                i += 2
                continue
            if tok.startswith("--message="):
                literal_msg_indices.add(i)
                i += 1
                continue
            if tok in GIT_SUB_VALUE_OPTS:
                i += 2
                continue
            if is_no_verify_flag(tok):
                block(
                    f"'git {sub} {tok}' skips the repository's git hooks. "
                    "Fix the hook failure instead."
                )
            if is_force_flag(tok):
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
                    if (sub == "commit" and ch in "mFCc") or (sub == "push" and ch == "o"):
                        if idx == len(flags) - 1:
                            if sub == "commit" and ch == "m" and i + 1 < len(tokens):
                                literal_msg_indices.add(i + 1)
                            i += 1
                        elif sub == "commit" and ch == "m":
                            literal_msg_indices.add(i)
                        break
                i += 1
                continue

        if sub == "push" and tok.startswith("+"):
            block(f"force-push refspec '{tok}' rewrites shared history.")
        i += 1

    return literal_msg_indices


def check_shell_invocation(tokens: list[str], depth: int) -> None:
    """Inspect nested `sh -c '...'` / `bash -c '...'` scripts recursively."""
    for i, tok in enumerate(tokens):
        if "=" in tok:
            continue
        base = posixpath.basename(tok)
        if base in SHELL_NAMES:
            j = i + 1
            while j < len(tokens):
                arg = tokens[j]
                if arg == "-c" or (arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]):
                    if j + 1 < len(tokens):
                        check_bash_command(tokens[j + 1], depth + 1)
                    return
                if not arg.startswith("-"):
                    return
                j += 1
            return


def check_bash_command(command: str, depth: int = 0) -> None:
    """Validate a Bash command string for secret access and git bypasses."""
    if depth > 4:
        return
    cleaned = strip_line_continuations(command)
    for seg in tokenize_segments(cleaned):
        msg_indices = check_git_segment(seg)
        for idx, tok in enumerate(seg):
            for inner in extract_substitutions(tok):
                check_bash_command(inner, depth + 1)
            if idx not in msg_indices:
                check_token_secrets(tok)
        check_shell_invocation(seg, depth)


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
            check_bash_command(command)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
