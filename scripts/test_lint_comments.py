#!/usr/bin/env python3

import importlib.util
import json
import os
import tempfile
import unittest

SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lint-comments.py")
SPEC = importlib.util.spec_from_file_location("lint_comments", SCRIPT_PATH)
LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINT)


class SwiftCommentLexerTests(unittest.TestCase):
    def test_ignores_slashes_inside_strings_and_raw_strings(self):
        src = '\n'.join([
            'let url = "https://example.com/a//b/*c*/"',
            'let raw = #"not // a comment /* nope */"#',
            'let multi = """',
            '  // still a string',
            '  /* also a string */',
            '"""',
        ]) + '\n'
        self.assertEqual(LINT.lex_swift_comments(src), [])

    def test_detects_line_doc_mark_and_nested_block_comments(self):
        src = '\n'.join([
            '// plain comment',
            '/// doc comment',
            '// MARK: - Section',
            '/* outer /* nested */ outer */',
            'let x = 1 // trailing',
        ]) + '\n'
        tokens = LINT.lex_swift_comments(src)
        self.assertEqual([t[4] for t in tokens], ["line", "doc", "mark", "block", "line"])
        self.assertEqual([t[2] for t in tokens], [1, 2, 3, 4, 5])

    def test_handles_string_interpolation_with_nested_strings_and_comments(self):
        src = 'let s = "prefix \\("http://ok") suffix"\n'
        self.assertEqual(LINT.lex_swift_comments(src), [])
        src_with_comment = 'let s = "prefix \\(1 /* inline */ + 2) // not comment"\n'
        tokens = LINT.lex_swift_comments(src_with_comment)
        self.assertEqual(len(tokens), 1)
        self.assertEqual(tokens[0][4], "block")


class RatchetBehaviorTests(unittest.TestCase):
    def make_repo(self, files):
        tmp = tempfile.TemporaryDirectory()
        for rel, content in files.items():
            full = os.path.join(tmp.name, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as f:
                f.write(content)
        return tmp

    def test_passes_with_zero_comments_and_empty_baseline(self):
        with self.make_repo({"Sources/A.swift": "let a = 1\n"}) as root:
            baseline = os.path.join(root, ".comment-ratchet.json")
            LINT.save_baseline(baseline, {})
            self.assertEqual(LINT.run_check(root, baseline), 0)

    def test_fails_when_new_comment_added(self):
        with self.make_repo({"Sources/A.swift": "// nope\nlet a = 1\n"}) as root:
            baseline = os.path.join(root, ".comment-ratchet.json")
            LINT.save_baseline(baseline, {})
            self.assertEqual(LINT.run_check(root, baseline), 1)

    def test_allows_bare_adr_signposts_for_existing_adrs_only(self):
        repo_files = {
            "docs/adr/0009-boundary.md": "# Boundary\n",
            "docs/adr/0034-runner.md": "# Runner\n",
            "Sources/A.swift": "// ADR-0009\n// ADR-0009, ADR-0034\nlet a = 1\n",
        }
        with self.make_repo(repo_files) as root:
            baseline = os.path.join(root, ".comment-ratchet.json")
            LINT.save_baseline(baseline, {})
            self.assertEqual(LINT.run_check(root, baseline), 0)

            with open(os.path.join(root, "Sources/A.swift"), "w", encoding="utf-8") as f:
                f.write("// ADR-0009 because prose is not allowed\nlet a = 1\n")
            self.assertEqual(LINT.run_check(root, baseline), 1)

            with open(os.path.join(root, "Sources/A.swift"), "w", encoding="utf-8") as f:
                f.write("/// ADR-0009\nlet a = 1\n")
            self.assertEqual(LINT.run_check(root, baseline), 1)

            with open(os.path.join(root, "Sources/A.swift"), "w", encoding="utf-8") as f:
                f.write("// ADR-9999\nlet a = 1\n")
            self.assertEqual(LINT.run_check(root, baseline), 1)

    def test_ratchet_enforces_downward_only_movement(self):
        with self.make_repo({"Sources/A.swift": "// one\n// two\nlet a = 1\n"}) as root:
            baseline = os.path.join(root, ".comment-ratchet.json")
            self.assertEqual(LINT.run_ratchet(root, baseline, allow_increase=True), 0)
            self.assertEqual(LINT.run_check(root, baseline), 0)

            with open(os.path.join(root, "Sources/A.swift"), "w", encoding="utf-8") as f:
                f.write("// one\n// two\n// three\nlet a = 1\n")
            self.assertEqual(LINT.run_check(root, baseline), 1)
            self.assertEqual(LINT.run_ratchet(root, baseline, allow_increase=False), 1)

            with open(os.path.join(root, "Sources/A.swift"), "w", encoding="utf-8") as f:
                f.write("// one\nlet a = 1\n")
            self.assertEqual(LINT.run_check(root, baseline), 1)
            self.assertEqual(LINT.run_ratchet(root, baseline, allow_increase=False), 0)
            self.assertEqual(LINT.run_check(root, baseline), 0)
            with open(baseline, "r", encoding="utf-8") as f:
                self.assertEqual(json.load(f)["files"], {"Sources/A.swift": 1})

            with open(os.path.join(root, "Sources/A.swift"), "w", encoding="utf-8") as f:
                f.write("let a = 1\n")
            self.assertEqual(LINT.run_ratchet(root, baseline, allow_increase=False), 0)
            with open(baseline, "r", encoding="utf-8") as f:
                self.assertEqual(json.load(f)["files"], {})


if __name__ == "__main__":
    unittest.main()
