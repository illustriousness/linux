#!/usr/bin/env python3
"""
Generate a directory exclude list from compile_commands.json and update a
VS Code workspace file.

Usage:
  compile_commands_exclude.py [compile_commands_path]
"""

import json
import os
import shlex
import sys

# User config
# Default to current working directory; you can override via CLI arg.
COMPILE_COMMANDS_PATH = "compile_commands.json"
FORCE_KEEP_PATHS = [
    "board/linker_scripts",
    "busybox"
]

SOURCE_SUFFIXES = (
    ".c",
    ".cc",
    ".cpp",
    ".cxx",
    ".c++",
    ".s",
    ".asm",
)

OPTS_WITH_ARG = {
    "-I",
    "/I",
    "-isystem",
    "-include",
    "-imacros",
    "-iquote",
    "-isysroot",
    "--sysroot",
    "-idirafter",
    "-iprefix",
    "-iwithprefix",
    "-iwithprefixbefore",
    "-L",
    "-B",
    "-T",
}

OPTS_WITH_PREFIX = (
    "-I",
    "/I",
    "-isystem",
    "-include",
    "-imacros",
    "-iquote",
    "-isysroot",
    "-idirafter",
    "-iprefix",
    "-iwithprefix",
    "-iwithprefixbefore",
    "-L",
    "-B",
    "-T",
)


def norm_abs(path: str) -> str:
    return os.path.normpath(os.path.abspath(path))


def resolve_path(path: str, base_dir: str) -> str:
    if not path:
        return ""
    path = path.strip("\"'")
    if path.startswith("@"):
        path = path[1:]
    if os.path.isabs(path):
        return norm_abs(path)
    return norm_abs(os.path.join(base_dir, path))


def is_under_root(path: str, root_path: str) -> bool:
    try:
        return os.path.commonpath([path, root_path]) == root_path
    except ValueError:
        return False


def iter_command_tokens(entry: dict) -> list:
    args = entry.get("arguments")
    if isinstance(args, list):
        return args
    cmd = entry.get("command")
    if isinstance(cmd, str):
        try:
            return shlex.split(cmd)
        except ValueError:
            return cmd.split()
    return []


def extract_paths_from_tokens(tokens, base_dir, root_path):
    paths = set()

    def add_path(raw):
        resolved = resolve_path(raw, base_dir)
        if resolved and is_under_root(resolved, root_path):
            paths.add(resolved)

    i = 0
    while i < len(tokens):
        tok = tokens[i]

        if tok in OPTS_WITH_ARG:
            if i + 1 < len(tokens):
                add_path(tokens[i + 1])
                i += 2
                continue

        if tok.startswith("--sysroot="):
            add_path(tok.split("=", 1)[1])
            i += 1
            continue

        if tok.startswith("-Wl,"):
            subargs = tok[len("-Wl,") :].split(",")
            j = 0
            while j < len(subargs):
                sub = subargs[j]
                if sub in ("-T", "--script"):
                    if j + 1 < len(subargs):
                        add_path(subargs[j + 1])
                        j += 2
                        continue
                if sub.startswith("-T") and len(sub) > 2:
                    add_path(sub[2:])
                if sub.startswith("--script="):
                    add_path(sub.split("=", 1)[1])
                j += 1
            i += 1
            continue

        handled = False
        for opt in OPTS_WITH_PREFIX:
            if tok.startswith(opt) and tok != opt:
                add_path(tok[len(opt) :].lstrip("="))
                handled = True
                break
        if handled:
            i += 1
            continue

        if not tok.startswith("-"):
            add_path(tok)

        i += 1

    return paths


def extract_keep_paths(compile_commands, root_path):
    keep_paths = set()

    for entry in compile_commands:
        base_dir = entry.get("directory") or root_path
        base_dir = norm_abs(base_dir)

        file_path = entry.get("file")
        if file_path:
            resolved = resolve_path(file_path, base_dir)
            if resolved and is_under_root(resolved, root_path):
                keep_paths.add(resolved)

        tokens = iter_command_tokens(entry)
        keep_paths.update(extract_paths_from_tokens(tokens, base_dir, root_path))

    return keep_paths


def extract_compiled_files(compile_commands, root_path):
    compiled_files = set()
    for entry in compile_commands:
        base_dir = entry.get("directory") or root_path
        base_dir = norm_abs(base_dir)
        file_path = entry.get("file")
        if not file_path:
            continue
        resolved = resolve_path(file_path, base_dir)
        if resolved and is_under_root(resolved, root_path):
            compiled_files.add(resolved)
    return compiled_files


def looks_like_file(path: str) -> bool:
    base = os.path.basename(path)
    if not base or base in (".", ".."):
        return False
    return "." in base and not base.startswith(".")


def add_keep_dirs(keep_dirs, path):
    norm = norm_abs(path)
    if os.path.isdir(norm) or not looks_like_file(norm):
        keep_dirs.add(norm)
    keep_dirs.add(os.path.dirname(norm))


def expand_ancestors(keep_dirs, root_path):
    ancestors = set()
    root_path = norm_abs(root_path)
    for d in keep_dirs:
        if not is_under_root(d, root_path):
            continue
        cur = norm_abs(d)
        while True:
            ancestors.add(cur)
            if cur == root_path:
                break
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent
    ancestors.add(root_path)
    return ancestors


def collect_exclude_dirs(root_path, keep_ancestors):
    exclude_dirs = set()
    for current, dirs, _ in os.walk(root_path):
        current_norm = norm_abs(current)
        if current_norm not in keep_ancestors:
            exclude_dirs.add(current_norm)
            dirs[:] = []
            continue

        pruned = []
        for d in dirs:
            dpath = norm_abs(os.path.join(current_norm, d))
            if dpath not in keep_ancestors:
                exclude_dirs.add(dpath)
                pruned.append(d)
        for d in pruned:
            dirs.remove(d)

    return exclude_dirs


def is_source_file(path: str) -> bool:
    name = os.path.basename(path)
    lower = name.lower()
    for suffix in SOURCE_SUFFIXES:
        if lower.endswith(suffix):
            return True
    return False


def collect_exclude_files(root_path, keep_ancestors, compiled_files, force_keep_files):
    exclude_files = set()
    for current, dirs, files in os.walk(root_path):
        current_norm = norm_abs(current)
        if current_norm not in keep_ancestors:
            dirs[:] = []
            continue
        for fname in files:
            fpath = norm_abs(os.path.join(current_norm, fname))
            if fpath in compiled_files or fpath in force_keep_files:
                continue
            if is_source_file(fpath):
                exclude_files.add(fpath)
    return exclude_files


def to_rel_posix(path, root_path):
    rel = os.path.relpath(path, root_path)
    if rel == ".":
        return ""
    return rel.replace(os.path.sep, "/")


def resolve_user_path(path, root_path):
    if not path:
        return ""
    if os.path.isabs(path):
        return norm_abs(path)
    return norm_abs(os.path.join(root_path, path))


def resolve_compile_commands(root_path: str, user_path: str):
    if user_path:
        resolved = resolve_user_path(user_path, root_path)
        if os.path.isdir(resolved):
            resolved = os.path.join(resolved, COMPILE_COMMANDS_PATH)
        return norm_abs(resolved)

    return norm_abs(resolve_user_path(COMPILE_COMMANDS_PATH, root_path))


def to_posix_path(path: str) -> str:
    return path.replace(os.path.sep, "/")


def clangd_compile_commands_dir(compile_commands_path: str, root_path: str) -> str:
    compile_commands_dir = norm_abs(os.path.dirname(compile_commands_path))
    try:
        rel = os.path.relpath(compile_commands_dir, root_path)
    except ValueError:
        rel = compile_commands_dir
    if rel == ".":
        return "."
    return to_posix_path(rel)


def write_workspace_file(root_path: str, rel_excludes, compile_commands_path: str):
    workspace_name = os.path.basename(os.getcwd())
    workspace_filename = f"{workspace_name}.code-workspace"
    workspace_path = os.path.join(root_path, workspace_filename)

    workspace_data = {}
    if os.path.isfile(workspace_path):
        with open(workspace_path, "r") as f:
            workspace_data = json.load(f)

    if not isinstance(workspace_data, dict):
        workspace_data = {}

    if "folders" not in workspace_data:
        workspace_data["folders"] = [{"path": "."}]

    settings = workspace_data.get("settings")
    if not isinstance(settings, dict):
        settings = {}
        workspace_data["settings"] = settings

    existing_args = settings.get("clangd.arguments")
    if not isinstance(existing_args, list):
        existing_args = []
    clangd_args = []
    for arg in existing_args:
        if not isinstance(arg, str):
            clangd_args.append(arg)
            continue
        if arg.startswith("--compile-commands-dir="):
            continue
        if arg.startswith("--header-insertion="):
            continue
        clangd_args.append(arg)
    clangd_args.append(
        f"--compile-commands-dir={clangd_compile_commands_dir(compile_commands_path, root_path)}"
    )
    clangd_args.append("--header-insertion=never")
    settings["clangd.arguments"] = clangd_args

    files_exclude = settings.get("files.exclude")
    if not isinstance(files_exclude, dict):
        files_exclude = {}
    for p in rel_excludes:
        files_exclude[p] = True
    settings["files.exclude"] = files_exclude

    with open(workspace_path, "w") as f:
        json.dump(workspace_data, f, indent=4)
    print(f"Wrote workspace to {workspace_path}")


def main():
    root_path = norm_abs(os.getcwd())
    user_compile_commands = sys.argv[1] if len(sys.argv) > 1 else ""
    compile_commands_path = resolve_compile_commands(root_path, user_compile_commands)

    if not os.path.isfile(compile_commands_path):
        raise FileNotFoundError(
            f"compile_commands.json not found. Tried: {compile_commands_path}"
        )

    with open(compile_commands_path, "r") as f:
        compile_commands = json.load(f)

    keep_paths = extract_keep_paths(compile_commands, root_path)
    compiled_files = extract_compiled_files(compile_commands, root_path)

    keep_dirs = set()
    for p in keep_paths:
        add_keep_dirs(keep_dirs, p)

    force_keep_files = set()
    for p in FORCE_KEEP_PATHS:
        resolved = resolve_user_path(p, root_path)
        add_keep_dirs(keep_dirs, resolved)
        if os.path.isfile(resolved):
            force_keep_files.add(norm_abs(resolved))

    keep_ancestors = expand_ancestors(keep_dirs, root_path)
    exclude_dirs = collect_exclude_dirs(root_path, keep_ancestors)
    exclude_files = collect_exclude_files(
        root_path, keep_ancestors, compiled_files, force_keep_files
    )

    rel_excludes = []
    for p in sorted(exclude_dirs):
        rel = to_rel_posix(p, root_path)
        if rel:
            rel_excludes.append(rel)

    rel_exclude_files = []
    for p in sorted(exclude_files):
        rel = to_rel_posix(p, root_path)
        if rel:
            rel_exclude_files.append(rel)

    rel_excludes_all = sorted(set(rel_excludes + rel_exclude_files))
    print(
        f"Found {len(rel_excludes)} exclude dirs, {len(rel_exclude_files)} exclude files"
    )

    write_workspace_file(root_path, rel_excludes_all, compile_commands_path)


if __name__ == "__main__":
    main()
