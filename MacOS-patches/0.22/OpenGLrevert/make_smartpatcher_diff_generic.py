#!/usr/bin/env python3
"""
make_smartpatcher_diff.py  (generic)

Turns a git-style diff (possibly hand-edited / slightly imperfect) into a
smart_patcher-compatible diff for ANY source file, satisfying:

    1. a '@@ ... @@' line appears above every -/+ block
    2. every '-' block has a matching '+' block (no pure insertions --
       smart_patcher only does replacement)
    3. every '-' block is unique in the file (smart_patcher doesn't use
       hunk/line-number info, only text matching)

How it works (no knowledge of the file's language/structure required):

  1. Read the CURRENT source file (ground truth "before" text).
  2. Replay the diff's context/-/+ lines against that ground truth to
     reconstruct the intended "after" text. Real unified-diff hunk headers
     ('@@ -a,b +c,d @@') are used as periodic resync anchors; a small
     forward look-ahead is used to self-heal minor slips in the diff
     (dropped/duplicated blank lines, tiny context drift, etc.), so a
     hand-edited diff still produces a correct result. Any '@@ ... @@'
     line that is NOT a real numeric hunk header (e.g. an annotation like
     '@@ contiguous @@') is treated as a pure visual separator and ignored.
  3. Diff the reconstructed "before" and "after" texts against each other
     with difflib to get minimal, non-overlapping change blocks. This
     replaces the need for any file-format-specific "logical unit"
     detection: difflib's opcodes are already maximal contiguous groups of
     change, so adjacent pure-insertions/pure-deletions from the same
     logical edit are automatically merged.
  4. Any remaining pure-insertion block (nothing to delete) is fixed by
     absorbing one adjacent unchanged line into both sides, giving
     smart_patcher a '-' anchor to match against.
  5. Every '-' block is checked for uniqueness against the whole file; if
     it's not unique, the block is grown outward (absorbing more
     unchanged context on either side, which is safe because that
     context is identical on both sides by construction) until it is
     unique, or the file boundary is reached.

Usage:
    python3 make_smartpatcher_diff.py <diff_file> <source_file> <output_file> [--lookahead N]
"""

import re
import sys
import difflib
import argparse

DEFAULT_LOOKAHEAD = 15
HEADER_SNIPPET_LEN = 60

HUNK_RE = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')


# --------------------------------------------------------------------------
# Step 1/2: load files, replay diff against ground truth to get "after" text
# --------------------------------------------------------------------------

def load_diff_body(diff_path):
    """Read the diff and strip git file-header lines / stray blank artifacts."""
    with open(diff_path) as f:
        raw = f.readlines()

    body = []
    for l in raw:
        if (
            l.startswith("diff --git")
            or l.startswith("index ")
            or l.startswith("--- ")
            or l.startswith("+++ ")
        ):
            continue
        if l == "\n":
            # a fully blank line with no +/-/space prefix isn't valid diff
            # content -- treat it as a formatting artifact and drop it
            continue
        body.append(l.rstrip("\n"))
    return body


def find_in_window(lines, cur, content, lookahead):
    limit = min(len(lines), cur + lookahead)
    for k in range(cur, limit):
        if lines[k] == content:
            return k
    for k in range(cur, limit):
        if lines[k].lower() == content.lower():
            return k
    return None


def find_anywhere(lines, cur, content):
    for k in range(cur, len(lines)):
        if lines[k] == content or lines[k].lower() == content.lower():
            return k
    return None


def reconcile_segment(bounded_old, seg_lines, a, warnings):
    """Reconstruct the target text for one hunk's bounded_old range.

    Builds two parallel views of the diff segment -- old_from_diff (context +
    deleted lines) and target_from_diff (context + added lines) -- then
    aligns old_from_diff against bounded_old with difflib.SequenceMatcher.
    Using SequenceMatcher's longest-matching-block alignment (rather than a
    greedy nearest-match scan) is what lets this handle files with many
    repeated short lines (e.g. a lone '}' appearing dozens of times close
    together): the alignment is anchored by the surrounding unique content,
    not just "the next occurrence".
    """
    old_from_diff = []
    target_from_diff = []
    kind = []  # 'ctx' or 'del', parallel to old_from_diff
    old_idx_to_target_idx = {}
    oi = 0
    ti = 0
    for l in seg_lines:
        if l == "":
            continue
        if l.startswith("-"):
            old_from_diff.append(l[1:])
            kind.append("del")
            oi += 1
        elif l.startswith("+"):
            target_from_diff.append(l[1:])
            ti += 1
        elif l.startswith(" "):
            c = l[1:]
            old_from_diff.append(c)
            target_from_diff.append(c)
            kind.append("ctx")
            old_idx_to_target_idx[oi] = ti
            oi += 1
            ti += 1
        else:
            old_from_diff.append(l)
            target_from_diff.append(l)
            kind.append("ctx")
            old_idx_to_target_idx[oi] = ti
            oi += 1
            ti += 1

    sm = difflib.SequenceMatcher(None, bounded_old, old_from_diff, autojunk=False)
    opcodes = sm.get_opcodes()

    # Ground-truth-only content (bounded_old lines the diff never mentions at
    # all, e.g. a dropped blank line) has no position in old_from_diff/kind,
    # so record where to splice it back in: right before old_from_diff[j1].
    insert_before = {}
    for tag, i1, i2, j1, j2 in opcodes:
        if j2 == j1 and i2 > i1:
            insert_before.setdefault(j1, []).extend(bounded_old[i1:i2])
        elif i2 == i1 and j2 > j1:
            # old_from_diff has content with no home in bounded_old at all --
            # the diff refers to text that doesn't exist in the source file
            warnings.append(
                f"diff content near old-line {a + i1 + 1} not found in the source file: "
                f"{old_from_diff[j1:j2]!r}"
            )

    # Walk the diff stream directly, in its original order. '+' lines are
    # always emitted right where they occur (this is what makes pure
    # insertions -- e.g. an added line with no adjacent '-' -- work
    # correctly). ctx/del lines are tracked by their old_from_diff index
    # (oi) purely so ground-truth-only gaps can be spliced back in at the
    # right spot.
    out = []
    oi = 0
    for l in seg_lines:
        if l == "":
            continue
        if l.startswith("+"):
            out.append(l[1:])
            continue
        if oi in insert_before:
            out.extend(insert_before[oi])
        if l.startswith("-"):
            oi += 1  # deleted: consume position, emit nothing
        else:
            content = l[1:] if l.startswith(" ") else l
            out.append(content)
            oi += 1
    if oi in insert_before:
        out.extend(insert_before[oi])

    return out


def reconstruct_target(old_lines, body, lookahead, warnings):
    """Replay the diff body against old_lines (ground truth) to build the new/target text.

    Real hunk headers ('@@ -a,b +c,d @@') give an *exact* old-line range for
    everything until the next hunk header. That range is used as a hard
    boundary for matching, instead of an open-ended forward search -- this
    avoids accidentally matching a short/common line (e.g. a lone '}') to
    the wrong occurrence somewhere later in a large file. Fuzzy look-ahead
    is only used to absorb small drift (dropped/duplicated blank lines etc.)
    *within* that exact bounded range.
    """
    # split body into (header_match_or_None, lines_until_next_header)
    segments = []
    cur_header = None
    cur_lines = []
    for l in body:
        m = HUNK_RE.match(l)
        if m:
            segments.append((cur_header, cur_lines))
            cur_header = m
            cur_lines = []
            continue
        if l.startswith("@@"):
            continue  # synthetic / non-numeric marker, pure visual separator
        cur_lines.append(l)
    segments.append((cur_header, cur_lines))

    out = []
    cur = 0  # absolute position in old_lines, next unconsumed line
    have_real_hunks = any(h is not None for h, _ in segments)

    for header, seg_lines in segments:
        if header is None and not seg_lines:
            continue  # placeholder before the first real hunk header, or trailing empty segment
        if header is not None:
            old_start = int(header.group(1))
            old_count = int(header.group(2)) if header.group(2) is not None else 1
            a = old_start - 1
            b = a + old_count
            if a > cur:
                out.extend(old_lines[cur:a])  # unchanged gap before this hunk
            elif a < cur:
                warnings.append(
                    f"hunk header '@@ -{old_start},{old_count} ...@@' points backward "
                    f"(to old-line {old_start}, but already at {cur + 1}); using it as-is"
                )
            bounded_old = old_lines[a:b]
            local_lookahead = max(lookahead, len(bounded_old))
        else:
            # no real hunk header available (e.g. a fully synthetic diff) --
            # fall back to a bounded window starting at cur
            a = cur
            bounded_old = old_lines[cur:cur + max(len(seg_lines), lookahead)]
            local_lookahead = lookahead
            if seg_lines and not have_real_hunks:
                pass  # expected/normal for a header-less diff
            elif seg_lines:
                warnings.append("segment with no preceding hunk header encountered; using best-effort bounded search")

        if seg_lines:
            out.extend(reconcile_segment(bounded_old, seg_lines, a, warnings))
        else:
            out.extend(bounded_old)
        cur = a + len(bounded_old)

    out.extend(old_lines[cur:])
    return out


# --------------------------------------------------------------------------
# Step 3/4: diff old vs. reconstructed new, merge into blocks, fix pure inserts
# --------------------------------------------------------------------------

def build_change_blocks(old_lines, new_lines):
    """Return merged [i1, i2, j1, j2] change blocks (old_lines[i1:i2] -> new_lines[j1:j2])."""
    sm = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    opcodes = sm.get_opcodes()

    merged = []
    cur_group = None
    for tag, i1, i2, j1, j2 in opcodes:
        if tag == "equal":
            if cur_group:
                merged.append(cur_group)
                cur_group = None
            continue
        if cur_group is None:
            cur_group = [i1, i2, j1, j2]
        else:
            cur_group[1] = i2
            cur_group[3] = j2
    if cur_group:
        merged.append(cur_group)

    # fix pure insertions (i1 == i2): absorb one adjacent unchanged line
    fixed = []
    for i1, i2, j1, j2 in merged:
        if i1 == i2:
            if i1 > 0:
                i1 -= 1
                j1 -= 1
            elif i2 < len(old_lines):
                i2 += 1
                j2 += 1
            # if the file is literally empty, there's nothing to anchor to;
            # leave as-is (shouldn't happen in practice)
        fixed.append([i1, i2, j1, j2])
    return fixed


# --------------------------------------------------------------------------
# Step 5: enforce global uniqueness of every '-' block
# --------------------------------------------------------------------------

def count_occurrences(sub_lines, all_lines):
    """Count occurrences of sub_lines as a run of consecutive lines, using the
    same text-substring semantics a text-based tool like smart_patcher will
    use. This deliberately does NOT just compare line-lists: joining lines
    with '\\n' means a block ending in a blank line only asserts "followed by
    a newline", not "followed by an empty line" -- so two blocks that look
    different as line-lists can still collide as raw text. Comparing the
    joined text (as done here) is what actually predicts smart_patcher
    ambiguity.
    """
    needle = "\n".join(sub_lines)
    if needle == "":
        return 0
    haystack = "\n".join(all_lines)
    count = 0
    start = 0
    while True:
        idx = haystack.find(needle, start)
        if idx == -1:
            break
        count += 1
        start = idx + 1  # allow overlapping matches, to be conservative
    return count


def ensure_unique(old_lines, block, warnings):
    """Grow a single block until its '-' text is unique, ignoring neighbors.

    Only safe to use in isolation (no other blocks nearby to collide with);
    ensure_all_unique() is the neighbor-aware version actually used by main().
    """
    i1, i2, j1, j2 = block
    guard = 0
    while count_occurrences(old_lines[i1:i2], old_lines) != 1 and guard < 100000:
        guard += 1
        grew = False
        if guard % 2 == 1:
            if i1 > 0:
                i1 -= 1
                j1 -= 1
                grew = True
            elif i2 < len(old_lines):
                i2 += 1
                j2 += 1
                grew = True
        else:
            if i2 < len(old_lines):
                i2 += 1
                j2 += 1
                grew = True
            elif i1 > 0:
                i1 -= 1
                j1 -= 1
                grew = True
        if not grew:
            break
    final_count = count_occurrences(old_lines[i1:i2], old_lines)
    if final_count != 1:
        warnings.append(
            f"could not make block unique even after growing to the full file "
            f"(old-lines {i1 + 1}-{i2}); occurs {final_count} times. "
            "smart_patcher may match the wrong location for this block."
        )
    return [i1, i2, j1, j2]


def ensure_all_unique(old_lines, blocks, warnings):
    """Grow every block until its '-' text is unique, WITHOUT growing past a
    neighboring block's edge (which would silently corrupt the mapping,
    since a neighbor's range is not unchanged/equal context). If a block
    still isn't unique once it has grown to touch a neighbor, the two
    blocks are merged into one instead of creeping further.
    """
    blocks = sorted([list(b) for b in blocks], key=lambda b: b[0])
    i = 0
    while i < len(blocks):
        b = blocks[i]
        guard = 0
        while count_occurrences(old_lines[b[0]:b[1]], old_lines) != 1 and guard < 200000:
            guard += 1
            prev_limit = blocks[i - 1][1] if i > 0 else 0
            next_limit = blocks[i + 1][0] if i + 1 < len(blocks) else len(old_lines)
            can_left = b[0] > prev_limit
            can_right = b[1] < next_limit

            if not can_left and not can_right:
                # no more room to grow without touching a neighbor -- merge
                # with whichever neighbor is closer (or the only one available)
                left_gap = b[0] - (blocks[i - 1][1] if i > 0 else -1) if i > 0 else None
                right_gap = (blocks[i + 1][0] if i + 1 < len(blocks) else None)
                merge_left = i > 0 and (i + 1 >= len(blocks) or (b[0] - blocks[i - 1][1]) <= (blocks[i + 1][0] - b[1]))
                if merge_left:
                    prev = blocks[i - 1]
                    b[0], b[2] = prev[0], prev[2]
                    del blocks[i - 1]
                    i -= 1
                elif i + 1 < len(blocks):
                    nxt = blocks[i + 1]
                    b[1], b[3] = nxt[1], nxt[3]
                    del blocks[i + 1]
                else:
                    break  # entire file is one block and still not unique -- give up
                continue

            if guard % 2 == 1 and can_left:
                b[0] -= 1
                b[2] -= 1
            elif can_right:
                b[1] += 1
                b[3] += 1
            elif can_left:
                b[0] -= 1
                b[2] -= 1

        final_count = count_occurrences(old_lines[b[0]:b[1]], old_lines)
        if final_count != 1:
            warnings.append(
                f"could not make block unique even after growing to the full file "
                f"(old-lines {b[0] + 1}-{b[1]}); occurs {final_count} times. "
                "smart_patcher may match the wrong location for this block."
            )
        i += 1
    return blocks






# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def make_header(old_lines, i1, i2):
    for l in old_lines[i1:i2]:
        s = l.strip()
        if s:
            if len(s) > HEADER_SNIPPET_LEN:
                s = s[:HEADER_SNIPPET_LEN].rstrip() + "..."
            return s
    return f"line {i1 + 1}"


def main():
    ap = argparse.ArgumentParser(description="Generate a smart_patcher-compatible diff from any diff + source file.")
    ap.add_argument("diff_file")
    ap.add_argument("source_file", help="the CURRENT (unpatched) version of the file, ground truth")
    ap.add_argument("output_file")
    ap.add_argument("--lookahead", type=int, default=DEFAULT_LOOKAHEAD,
                     help=f"how many lines ahead to search when re-syncing on a slightly-off diff (default {DEFAULT_LOOKAHEAD})")
    args = ap.parse_args()

    with open(args.source_file) as f:
        old_text = f.read()
    old_lines = old_text.split("\n")

    body = load_diff_body(args.diff_file)

    warnings = []
    new_lines = reconstruct_target(old_lines, body, args.lookahead, warnings)

    if warnings:
        print(f"{len(warnings)} warning(s) while reconstructing the target text:")
        for w in warnings:
            print("  " + w)
        print()

    blocks = build_change_blocks(old_lines, new_lines)
    print(f"{len(blocks)} change block(s) found")

    uniq_warnings = []
    unique_blocks = ensure_all_unique(old_lines, blocks, uniq_warnings)

    if uniq_warnings:
        print(f"\n{len(uniq_warnings)} uniqueness warning(s):")
        for w in uniq_warnings:
            print("  " + w)
        print()

    with open(args.output_file, "w") as f:
        for i1, i2, j1, j2 in unique_blocks:
            header = make_header(old_lines, i1, i2)
            f.write(f"@@ {header} @@\n")
            for l in old_lines[i1:i2]:
                f.write(f"-{l}\n")
            for l in new_lines[j1:j2]:
                f.write(f"+{l}\n")
            f.write("\n")

    print(f"Wrote {len(unique_blocks)} block(s) to {args.output_file}")


if __name__ == "__main__":
    main()
