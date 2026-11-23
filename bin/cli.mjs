#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PACKAGE_ROOT = path.resolve(__dirname, "..");

const CLAUDE_MATCHER = "Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob|Bash";
const SKILL_NAMES = ["install-guardrails", "secret-leak-response"];

function readPackageVersion() {
  const pkgPath = path.join(PACKAGE_ROOT, "package.json");
  const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  return pkg.version || "0.0.0";
}

function printHelp() {
  const version = readPackageVersion();
  process.stdout.write(`agent-secret-guard v${version}

Install defense-in-depth secrets handling and commit guardrails for AI coding agents.

Usage:
  npx agent-secret-guardrails [target-dir] [options]

Runs an interactive wizard (scope, agents, components) when attached to a
terminal. Flags you pass are pre-selected and their questions are skipped.
Use --yes, or run without a TTY (CI, scripts), to install non-interactively.

Options:
  -y, --yes                   Skip the interactive wizard and install with flags/defaults
  --target <dir>              Target project directory (defaults to current directory)
  -p, --project               Install into target project (default)
  -g, --global                Install globally into user home (~/.claude, ~/.gemini/config)
  -a, --agent <name>          Target agent: claude-code (claude), antigravity (agy), or all (default: all)
  --only-hooks                Only install Layer 1 PreToolUse hooks
  --only-skills               Only install agent skills (install-guardrails, secret-leak-response)
  --only-pre-commit           Only install Layer 2 (.pre-commit-config.yaml + pre-commit install)
  --no-pre-commit             Skip Layer 2 (pre-commit) during a project install
  -h, --help                  Show this help message
  -v, --version               Show version
`);
}

function normalizeAgent(value) {
  const lower = String(value || "").toLowerCase();
  if (lower === "claude" || lower === "claude-code") return "claude-code";
  if (lower === "agy" || lower === "antigravity") return "antigravity";
  if (lower === "all") return "all";
  throw new Error(
    `Invalid --agent value '${value}'. Expected: claude-code, antigravity, or all.`
  );
}

function parseArgs(argv) {
  const opts = {
    targetDir: null,
    scope: null,
    agent: "all",
    onlyHooks: false,
    onlySkills: false,
    onlyPreCommit: false,
    noPreCommit: false,
    agentExplicit: false,
    yes: false,
    help: false,
    version: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      opts.help = true;
    } else if (arg === "-y" || arg === "--yes") {
      opts.yes = true;
    } else if (arg === "-v" || arg === "--version") {
      opts.version = true;
    } else if (arg === "-g" || arg === "--global") {
      if (opts.scope === "project") {
        throw new Error("Cannot combine --global and --project.");
      }
      opts.scope = "global";
    } else if (arg === "-p" || arg === "--project") {
      if (opts.scope === "global") {
        throw new Error("Cannot combine --global and --project.");
      }
      opts.scope = "project";
    } else if (arg === "--only-hooks") {
      opts.onlyHooks = true;
    } else if (arg === "--only-skills") {
      opts.onlySkills = true;
    } else if (arg === "--only-pre-commit") {
      opts.onlyPreCommit = true;
    } else if (arg === "--no-pre-commit") {
      opts.noPreCommit = true;
    } else if (arg === "-a" || arg === "--agent") {
      if (i + 1 >= argv.length) {
        throw new Error(`Missing value for ${arg}.`);
      }
      opts.agent = normalizeAgent(argv[++i]);
      opts.agentExplicit = true;
    } else if (arg.startsWith("--agent=")) {
      opts.agent = normalizeAgent(arg.slice("--agent=".length));
      opts.agentExplicit = true;
    } else if (arg === "--target") {
      if (i + 1 >= argv.length) {
        throw new Error("Missing value for --target.");
      }
      opts.targetDir = argv[++i];
    } else if (arg.startsWith("--target=")) {
      opts.targetDir = arg.slice("--target=".length);
    } else if (arg.startsWith("-")) {
      throw new Error(`Unknown option: ${arg}`);
    } else if (!opts.targetDir) {
      opts.targetDir = arg;
    } else {
      throw new Error(`Unexpected positional argument: ${arg}`);
    }
  }

  return {
    ...opts,
    scopeExplicit: opts.scope !== null,
    scope: opts.scope || "project",
    targetDir: path.resolve(opts.targetDir || process.cwd()),
  };
}

function copyFileWithMode(src, dest, modeOverride = null) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
  const mode = modeOverride !== null ? modeOverride : fs.statSync(src).mode;
  fs.chmodSync(dest, mode);
}

function copyDirRecursive(srcDir, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const srcPath = path.join(srcDir, entry.name);
    const destPath = path.join(destDir, entry.name);
    if (entry.isDirectory()) {
      copyDirRecursive(srcPath, destPath);
    } else if (entry.isFile()) {
      copyFileWithMode(srcPath, destPath);
    }
  }
}

function copySkillsTo(skillsRootDir) {
  for (const skill of SKILL_NAMES) {
    const src = path.join(PACKAGE_ROOT, "skills", skill);
    const dest = path.join(skillsRootDir, skill);
    copyDirRecursive(src, dest);
  }
}

function installClaudeCode(baseDir, scope, { hooks, skills }) {
  if (hooks) {
    const hookDest = path.join(baseDir, "hooks", "agent-secret-guard.py");
    copyFileWithMode(
      path.join(PACKAGE_ROOT, "hooks", "guard.py"),
      hookDest,
      0o755
    );

    const settingsPath = path.join(baseDir, "settings.json");
    let settings = {};
    if (fs.existsSync(settingsPath)) {
      const raw = fs.readFileSync(settingsPath, "utf8");
      try {
        settings = JSON.parse(raw);
      } catch (err) {
        throw new Error(
          `Failed to parse existing ${settingsPath}: ${err.message}`
        );
      }
      if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
        throw new Error(
          `Expected JSON object in ${settingsPath}, found ${typeof settings}.`
        );
      }
    }

    if (
      !settings.hooks ||
      typeof settings.hooks !== "object" ||
      Array.isArray(settings.hooks)
    ) {
      settings.hooks = {};
    }
    if (!Array.isArray(settings.hooks.PreToolUse)) {
      settings.hooks.PreToolUse = [];
    }

    const command =
      scope === "project"
        ? '"$CLAUDE_PROJECT_DIR"/.claude/hooks/agent-secret-guard.py'
        : "~/.claude/hooks/agent-secret-guard.py";

    const desiredEntry = {
      matcher: CLAUDE_MATCHER,
      hooks: [
        {
          type: "command",
          command,
          timeout: 10,
        },
      ],
    };

    const existingIdx = settings.hooks.PreToolUse.findIndex(
      (entry) =>
        entry &&
        Array.isArray(entry.hooks) &&
        entry.hooks.some(
          (h) =>
            h &&
            typeof h.command === "string" &&
            h.command.includes("agent-secret-guard")
        )
    );

    if (existingIdx >= 0) {
      settings.hooks.PreToolUse[existingIdx] = desiredEntry;
    } else {
      settings.hooks.PreToolUse.push(desiredEntry);
    }

    fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
    fs.writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
    process.stdout.write(`  [claude-code] hook -> ${hookDest}\n`);
    process.stdout.write(`  [claude-code] settings -> ${settingsPath}\n`);
  }

  if (skills) {
    const skillsDir = path.join(baseDir, "skills");
    copySkillsTo(skillsDir);
    process.stdout.write(`  [claude-code] skills -> ${skillsDir}\n`);
  }
}

function installAntigravity(baseDir, { hooks, skills }) {
  const pluginDir = path.join(baseDir, "plugins", "agent-secret-guard");

  if (hooks) {
    copyFileWithMode(
      path.join(PACKAGE_ROOT, ".antigravity-plugin", "plugin.json"),
      path.join(pluginDir, "plugin.json")
    );
    copyFileWithMode(
      path.join(PACKAGE_ROOT, ".antigravity-plugin", "plugin.json"),
      path.join(pluginDir, ".antigravity-plugin", "plugin.json")
    );
    copyFileWithMode(
      path.join(PACKAGE_ROOT, "hooks.json"),
      path.join(pluginDir, "hooks.json")
    );
    copyFileWithMode(
      path.join(PACKAGE_ROOT, "hooks", "guard.py"),
      path.join(pluginDir, "hooks", "guard.py"),
      0o755
    );
    process.stdout.write(`  [antigravity] plugin hooks -> ${pluginDir}\n`);

    if (skills) {
      const pluginSkillsDir = path.join(pluginDir, "skills");
      copySkillsTo(pluginSkillsDir);
      process.stdout.write(
        `  [antigravity] plugin skills -> ${pluginSkillsDir}\n`
      );
    }
  } else if (skills) {
    const skillsDir = path.join(baseDir, "skills");
    copySkillsTo(skillsDir);
    process.stdout.write(`  [antigravity] skills -> ${skillsDir}\n`);
  }
}

function installPreCommit(targetDir, strictMode) {
  const installer = path.join(
    PACKAGE_ROOT,
    "skills",
    "install-guardrails",
    "scripts",
    "install.sh"
  );
  const res = spawnSync("bash", [installer, targetDir], {
    encoding: "utf8",
  });

  if (res.status === 0) {
    if (res.stdout) process.stdout.write(res.stdout);
    process.stdout.write(`  [pre-commit] installed in ${targetDir}\n`);
    return 0;
  }

  const combined = `${res.stdout || ""}${res.stderr || ""}`;
  if (res.status === 1 && combined.includes("already exists") && !strictMode) {
    process.stdout.write(
      `  [pre-commit] skipping config creation: .pre-commit-config.yaml already exists in ${targetDir}\n`
    );
    return 0;
  }

  if (res.status === 3) {
    if (res.stdout) process.stdout.write(res.stdout);
    if (res.stderr) process.stderr.write(res.stderr);
    return strictMode ? 3 : 0;
  }

  if (!strictMode && res.status === 1 && combined.includes("not a git repository")) {
    process.stdout.write(
      `  [pre-commit] skipping: ${targetDir} is not a git repository\n`
    );
    return 0;
  }

  if (res.stdout) process.stdout.write(res.stdout);
  if (res.stderr) process.stderr.write(res.stderr);
  return res.status ?? 1;
}

function resolveSelection(opts, scope) {
  const hasOnlyFilter =
    opts.onlyHooks || opts.onlySkills || opts.onlyPreCommit;
  return {
    scope,
    claude: opts.agent === "all" || opts.agent === "claude-code",
    antigravity: opts.agent === "all" || opts.agent === "antigravity",
    hooks: hasOnlyFilter ? opts.onlyHooks : true,
    skills: hasOnlyFilter ? opts.onlySkills : true,
    preCommit: hasOnlyFilter
      ? opts.onlyPreCommit
      : scope === "project" && !opts.noPreCommit,
  };
}

function isInteractive(opts) {
  return !opts.yes && Boolean(process.stdin.isTTY && process.stdout.isTTY);
}

async function loadPrompts() {
  try {
    return await import("@clack/prompts");
  } catch (err) {
    throw new Error(
      `Interactive wizard unavailable (${err.message}). Re-run with --yes to install non-interactively.`
    );
  }
}

async function runWizard(opts) {
  const p = await loadPrompts();
  const bail = (value) => {
    if (p.isCancel(value)) {
      p.cancel("Installation cancelled.");
      process.exit(0);
    }
    return value;
  };

  p.intro(`agent-secret-guard v${readPackageVersion()}`);

  let scope = opts.scope;
  if (!opts.scopeExplicit) {
    scope = bail(
      await p.select({
        message: "Installation scope",
        initialValue: "project",
        options: [
          { value: "project", label: "Project", hint: opts.targetDir },
          {
            value: "global",
            label: "Global",
            hint: "~/.claude and ~/.gemini/config",
          },
        ],
      })
    );
  }

  const selection = resolveSelection(opts, scope);

  if (!opts.agentExplicit) {
    const agents = bail(
      await p.multiselect({
        message: "Agents to protect",
        initialValues: ["claude-code", "antigravity"],
        required: true,
        options: [
          { value: "claude-code", label: "Claude Code" },
          { value: "antigravity", label: "Antigravity CLI" },
        ],
      })
    );
    selection.claude = agents.includes("claude-code");
    selection.antigravity = agents.includes("antigravity");
  }

  const componentFlags =
    opts.onlyHooks || opts.onlySkills || opts.onlyPreCommit || opts.noPreCommit;
  if (!componentFlags) {
    const initialValues = ["hooks", "skills"];
    if (scope === "project") initialValues.push("pre-commit");
    const components = bail(
      await p.multiselect({
        message: "Components to install",
        initialValues,
        required: true,
        options: [
          {
            value: "hooks",
            label: "PreToolUse hooks",
            hint: "Layer 1: block secret reads and git bypasses",
          },
          {
            value: "skills",
            label: "Agent skills",
            hint: "install-guardrails, secret-leak-response",
          },
          {
            value: "pre-commit",
            label: "Git pre-commit",
            hint: `Layer 2: gitleaks + detect-private-key in ${opts.targetDir}`,
          },
        ],
      })
    );
    selection.hooks = components.includes("hooks");
    selection.skills = components.includes("skills");
    selection.preCommit = components.includes("pre-commit");
  }

  const agentLabels = [
    selection.claude && "Claude Code",
    selection.antigravity && "Antigravity CLI",
  ].filter(Boolean);
  const componentLabels = [
    selection.hooks && "hooks",
    selection.skills && "skills",
    selection.preCommit && "pre-commit",
  ].filter(Boolean);
  p.note(
    [
      `Scope:      ${scope}`,
      `Target:     ${scope === "global" ? "user home" : opts.targetDir}`,
      `Agents:     ${agentLabels.join(", ") || "none"}`,
      `Components: ${componentLabels.join(", ")}`,
    ].join("\n"),
    "Summary"
  );

  const proceed = bail(
    await p.confirm({ message: "Proceed with installation?", initialValue: true })
  );
  if (!proceed) {
    p.cancel("Installation cancelled.");
    process.exit(0);
  }

  return selection;
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`error: ${err.message}\n`);
    process.exit(1);
  }

  if (opts.help) {
    printHelp();
    process.exit(0);
  }

  if (opts.version) {
    process.stdout.write(`${readPackageVersion()}\n`);
    process.exit(0);
  }

  if (opts.noPreCommit && opts.onlyPreCommit) {
    process.stderr.write(
      "error: Cannot combine --only-pre-commit and --no-pre-commit.\n"
    );
    process.exit(1);
  }

  let selection;
  try {
    selection = isInteractive(opts)
      ? await runWizard(opts)
      : resolveSelection(opts, opts.scope);
  } catch (err) {
    process.stderr.write(`error: ${err.message}\n`);
    process.exit(1);
  }

  const scope = selection.scope;
  const wantHooks = selection.hooks;
  const wantSkills = selection.skills;
  const wantPreCommit = selection.preCommit;

  const homeDir = process.env.HOME || os.homedir();
  const wantClaude = selection.claude;
  const wantAgy = selection.antigravity;

  process.stdout.write(`Installing agent-secret-guard (${scope} scope)...\n`);

  try {
    if ((wantHooks || wantSkills) && wantClaude) {
      const claudeBase =
        scope === "global"
          ? path.join(homeDir, ".claude")
          : path.join(opts.targetDir, ".claude");
      installClaudeCode(claudeBase, scope, {
        hooks: wantHooks,
        skills: wantSkills,
      });
    }

    if ((wantHooks || wantSkills) && wantAgy) {
      const agyBase =
        scope === "global"
          ? path.join(homeDir, ".gemini", "config")
          : path.join(opts.targetDir, ".agents");
      installAntigravity(agyBase, {
        hooks: wantHooks,
        skills: wantSkills,
      });
    }

    if (wantPreCommit) {
      const strictPreCommit =
        opts.onlyPreCommit && !wantHooks && !wantSkills;
      const code = installPreCommit(opts.targetDir, strictPreCommit);
      if (code !== 0) {
        process.exit(code);
      }
    }
  } catch (err) {
    process.stderr.write(`error: ${err.message}\n`);
    process.exit(1);
  }

  process.stdout.write("Done.\n");
}

main();
