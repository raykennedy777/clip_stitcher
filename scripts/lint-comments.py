#!/usr/bin/env python3

import argparse
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BASELINE = ".comment-ratchet.json"
DEFAULT_GLOBS = (
    "Sources/**/*.swift",
    "CLI/**/*.swift",
    "Tests/**/*.swift",
)
ADR_SIGNPOST_RE = re.compile(r"^//\s+ADR-(\d{4})(?:,\s*ADR-(\d{4}))*$")
ADR_ID_RE = re.compile(r"ADR-(\d{4})")


def discover_adr_ids(root):
    adr_dir = os.path.join(root, "docs", "adr")
    if not os.path.isdir(adr_dir):
        return set()
    ids = set()
    for name in os.listdir(adr_dir):
        m = re.match(r"^(\d{4})-.*\.md$", name)
        if m:
            ids.add(m.group(1))
    return ids


def parse_adr_signpost(kind, raw):
    if kind != "line":
        return None
    if not ADR_SIGNPOST_RE.match(raw.strip()):
        return None
    return ADR_ID_RE.findall(raw)


def lex_swift_comments(text):
    n = len(text)
    i = 0
    line = 1
    comments = []
    interp_stack = []

    def advance(k=1):
        nonlocal i, line
        for _ in range(k):
            if text[i] == "\n":
                line += 1
            i += 1

    def scan_string(hashes, is_multiline):
        delim = ('"""' if is_multiline else '"') + ("#" * hashes)
        esc = "\\" + ("#" * hashes)
        while i < n:
            if text.startswith(esc + "(", i):
                advance(len(esc) + 1)
                interp_stack.append([hashes, is_multiline, 1])
                return
            if text.startswith(esc, i) and i + len(esc) < n:
                advance(len(esc) + 1)
                continue
            if text.startswith(delim, i):
                advance(len(delim))
                return
            if not is_multiline and text[i] == "\n":
                advance(1)
                return
            advance(1)

    while i < n:
        c = text[i]
        if interp_stack:
            if c == "(":
                interp_stack[-1][2] += 1
                advance(1)
                continue
            if c == ")":
                interp_stack[-1][2] -= 1
                advance(1)
                if interp_stack[-1][2] == 0:
                    hashes, is_multiline, _ = interp_stack.pop()
                    scan_string(hashes, is_multiline)
                continue

        if c == "/" and i + 1 < n and text[i + 1] == "/":
            start_idx, start_line = i, line
            while i < n and text[i] != "\n":
                advance(1)
            raw = text[start_idx:i]
            kind = "doc" if raw.startswith("///") else ("mark" if "MARK:" in raw else "line")
            comments.append((start_idx, i, start_line, line, kind, raw))
            continue

        if c == "/" and i + 1 < n and text[i + 1] == "*":
            start_idx, start_line = i, line
            depth = 1
            advance(2)
            while i < n and depth > 0:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    advance(2)
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    advance(2)
                else:
                    advance(1)
            comments.append((start_idx, i, start_line, line, "block", text[start_idx:i]))
            continue

        if c == "#" or c == '"':
            j = i
            while j < n and text[j] == "#":
                j += 1
            hashes = j - i
            if j < n and text[j] == '"':
                if text.startswith('"""', j):
                    advance(hashes + 3)
                    scan_string(hashes, True)
                    continue
                advance(hashes + 1)
                scan_string(hashes, False)
                continue
            advance(1)
            continue

        advance(1)

    return comments


def analyze_file(path, valid_adrs=None):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    lines = text.splitlines(keepends=True)
    all_tokens = lex_swift_comments(text)

    tokens = []
    signposts = []
    broken_signposts = []

    for tok in all_tokens:
        _, _, start_line, _, kind, raw = tok
        adr_ids = parse_adr_signpost(kind, raw)
        if adr_ids is not None:
            signposts.append((start_line, adr_ids, raw))
            if valid_adrs is not None:
                missing = [aid for aid in adr_ids if aid not in valid_adrs]
                if missing:
                    broken_signposts.append((start_line, missing, raw))
        else:
            tokens.append(tok)

    comment_lines = set()
    pure_comment_lines = set()
    blocks = []

    for start_idx, end_idx, start_line, end_line, kind, raw in tokens:
        for ln in range(start_line, end_line + 1):
            comment_lines.add(ln)
        if kind == "block":
            first_prefix = lines[start_line - 1][: start_idx - sum(len(l) for l in lines[: start_line - 1])]
            last_suffix = lines[end_line - 1][end_idx - sum(len(l) for l in lines[: end_line - 1]) :]
            is_full = first_prefix.strip() == "" and last_suffix.strip() == ""
        else:
            is_full = lines[start_line - 1].lstrip().startswith("//")

        if is_full:
            for ln in range(start_line, end_line + 1):
                pure_comment_lines.add(ln)

        if (
            blocks
            and is_full
            and blocks[-1]["is_full"]
            and start_line == blocks[-1]["end_line"] + 1
            and kind != "block"
            and blocks[-1]["kind"] != "block"
            and (kind == "mark") == (blocks[-1]["kind"] == "mark")
        ):
            blocks[-1]["end_line"] = end_line
            blocks[-1]["lines"].append(raw)
        else:
            blocks.append(
                {
                    "start_line": start_line,
                    "end_line": end_line,
                    "kind": kind,
                    "is_full": is_full,
                    "lines": [raw],
                }
            )

    remaining = [ln for idx, ln in enumerate(lines, 1) if idx not in pure_comment_lines]
    cleaned = []
    for ln in remaining:
        if ln.strip() == "":
            if not cleaned:
                continue
            if cleaned[-1].strip() == "":
                continue
            if cleaned[-1].rstrip().endswith("{"):
                continue
        cleaned.append(ln)
    collapsed_blanks = len(remaining) - len(cleaned)

    return {
        "loc": len(lines),
        "comment_line_count": len(comment_lines),
        "comment_lines": sorted(comment_lines),
        "pure_comment_line_count": len(pure_comment_lines),
        "trailing_comment_count": len(comment_lines) - len(pure_comment_lines),
        "collapsed_blanks": collapsed_blanks,
        "blocks": blocks,
        "tokens": tokens,
        "signposts": signposts,
        "broken_signposts": broken_signposts,
    }


def discover_swift_files(root):
    found = set()
    for pattern in DEFAULT_GLOBS:
        for match in glob.glob(os.path.join(root, pattern), recursive=True):
            if os.path.isfile(match):
                found.add(os.path.relpath(match, root))
    return sorted(found)


def load_baseline(baseline_path):
    if not os.path.exists(baseline_path):
        return {}
    with open(baseline_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return dict(data.get("files", {}))


def save_baseline(baseline_path, files_map):
    trimmed = {k: v for k, v in sorted(files_map.items()) if v > 0}
    payload = {"version": 1, "files": trimmed}
    with open(baseline_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def run_check(root, baseline_path):
    baseline = load_baseline(baseline_path)
    valid_adrs = discover_adr_ids(root)
    files = discover_swift_files(root)
    counts = {}
    violations = []
    stale_ratchet = []
    broken = []
    total_signposts = 0

    for rel in files:
        info = analyze_file(os.path.join(root, rel), valid_adrs=valid_adrs)
        count = info["comment_line_count"]
        counts[rel] = count
        total_signposts += len(info["signposts"])
        for line_no, missing, raw in info["broken_signposts"]:
            broken.append((rel, line_no, missing, raw))
        allowed = baseline.get(rel, 0)
        if count > allowed:
            violations.append((rel, count, allowed, info))
        elif rel in baseline and count < allowed:
            stale_ratchet.append((rel, count, allowed))

    for rel, allowed in sorted(baseline.items()):
        if rel not in counts:
            stale_ratchet.append((rel, 0, allowed))

    failed = False

    if broken:
        failed = True
        print("ERROR: Broken ADR signposts (referenced ADR not found in docs/adr/):", file=sys.stderr)
        for rel, line_no, missing, raw in broken:
            missing_fmt = ", ".join(f"ADR-{aid}" for aid in missing)
            print(f"  {rel}:{line_no}: {raw} (missing {missing_fmt})", file=sys.stderr)

    if violations:
        failed = True
        print("ERROR: Code comments are banned (or exceed the ratchet baseline):", file=sys.stderr)
        for rel, count, allowed, info in violations:
            print(f"  {rel}: {count} comment line(s) found (allowed: {allowed})", file=sys.stderr)
            for _, _, s_line, _, _, raw in info["tokens"][:5]:
                snippet = raw.splitlines()[0][:80]
                print(f"    {rel}:{s_line}: {snippet}", file=sys.stderr)
            if len(info["tokens"]) > 5:
                print(f"    ... and {len(info['tokens']) - 5} more", file=sys.stderr)
        print(
            "\nRemove the comments (move decision records to docs/adr/, use bare `// ADR-NNNN` signposts only, and file issues for excuses).",
            file=sys.stderr,
        )

    if stale_ratchet:
        failed = True
        print("ERROR: Comment count dropped below .comment-ratchet.json — ratchet the baseline down:", file=sys.stderr)
        for rel, count, allowed in stale_ratchet:
            print(f"  {rel}: {count} comment line(s) (baseline: {allowed})", file=sys.stderr)
        print("\nRun: python3 scripts/lint-comments.py --ratchet", file=sys.stderr)

    if failed:
        return 1

    total_remaining = sum(counts.values())
    signpost_note = f", {total_signposts} ADR signpost(s)" if total_signposts else ""
    if total_remaining == 0:
        print(f"OK: {len(files)} Swift files checked, 0 comments{signpost_note}.")
    else:
        files_with_comments = sum(1 for v in counts.values() if v > 0)
        print(
            f"OK (ratchet): {len(files)} Swift files checked, "
            f"{total_remaining} baseline comment lines remaining across {files_with_comments} files{signpost_note}."
        )
    return 0


def run_ratchet(root, baseline_path, allow_increase=False):
    baseline = load_baseline(baseline_path)
    valid_adrs = discover_adr_ids(root)
    files = discover_swift_files(root)
    updated = {}
    increases = []

    for rel in files:
        count = analyze_file(os.path.join(root, rel), valid_adrs=valid_adrs)["comment_line_count"]
        allowed = baseline.get(rel, 0)
        if count > allowed and not allow_increase:
            increases.append((rel, count, allowed))
        elif count > 0:
            updated[rel] = count

    if increases:
        print("ERROR: --ratchet only lowers baselines; these files increased:", file=sys.stderr)
        for rel, count, allowed in increases:
            print(f"  {rel}: {count} (baseline: {allowed})", file=sys.stderr)
        return 1

    save_baseline(baseline_path, updated)
    print(
        f"Updated {os.path.relpath(baseline_path, root)}: "
        f"{sum(updated.values())} comment line(s) across {len(updated)} file(s)."
    )
    return 0


def run_stats(root):
    valid_adrs = discover_adr_ids(root)
    files = discover_swift_files(root)
    rows = []
    total_loc = 0
    total_comment_lines = 0
    total_pure = 0
    total_trailing = 0
    total_blanks = 0
    total_blocks = 0
    total_signposts = 0

    for rel in files:
        info = analyze_file(os.path.join(root, rel), valid_adrs=valid_adrs)
        total_loc += info["loc"]
        total_comment_lines += info["comment_line_count"]
        total_pure += info["pure_comment_line_count"]
        total_trailing += info["trailing_comment_count"]
        total_blanks += info["collapsed_blanks"]
        total_blocks += len(info["blocks"])
        total_signposts += len(info["signposts"])
        if info["comment_line_count"] > 0:
            rows.append((info["comment_line_count"], len(info["blocks"]), rel))

    print(f"Swift files scanned: {len(files)} ({total_loc} LOC)")
    print(f"ADR signposts:       {total_signposts}")
    print(f"Comment blocks:      {total_blocks}")
    print(f"Comment lines:       {total_comment_lines} ({total_pure} pure + {total_trailing} trailing)")
    print(f"Estimated LOC shed:  {total_pure + total_blanks} ({total_pure} comment lines + {total_blanks} collapsed blank lines)")
    if rows:
        print("\nTop files with remaining comments:")
        for cl, bl, rel in sorted(rows, reverse=True)[:20]:
            print(f"  {cl:4d} lines ({bl:3d} blocks)  {rel}")
    return 0


def run_list_file(root, target_file):
    abs_path = target_file if os.path.isabs(target_file) else os.path.join(root, target_file)
    info = analyze_file(abs_path, valid_adrs=discover_adr_ids(root))
    print(
        f"{target_file}: {info['comment_line_count']} comment line(s) in {len(info['blocks'])} block(s)"
        f", {len(info['signposts'])} ADR signpost(s)"
    )
    for idx, block in enumerate(info["blocks"], 1):
        print(f"  B{idx:03d} L{block['start_line']}-L{block['end_line']} [{block['kind']}]")
        for line in block["lines"]:
            print(f"    {line}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Enforce a no-comments ratchet across Swift source files.")
    parser.add_argument("--root", default=ROOT, help="Repository root directory.")
    parser.add_argument("--baseline", default=None, help="Path to ratchet baseline JSON.")
    parser.add_argument("--ratchet", action="store_true", help="Lower baseline counts to match current files.")
    parser.add_argument("--bootstrap", action="store_true", help="Initialize or raise baseline from current files.")
    parser.add_argument("--stats", action="store_true", help="Print remaining comment counts and LOC-shed estimate.")
    parser.add_argument("--file", dest="target_file", help="List all comment blocks in one Swift file.")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    baseline_path = args.baseline or os.path.join(root, DEFAULT_BASELINE)

    if args.target_file:
        return run_list_file(root, args.target_file)
    if args.stats:
        return run_stats(root)
    if args.bootstrap:
        return run_ratchet(root, baseline_path, allow_increase=True)
    if args.ratchet:
        return run_ratchet(root, baseline_path, allow_increase=False)
    return run_check(root, baseline_path)


if __name__ == "__main__":
    sys.exit(main())
