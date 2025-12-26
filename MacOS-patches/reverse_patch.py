#!/usr/bin/env python3
"""
Reverse patch script for OpenSpace macOS patches.
Applies patches in reverse without requiring exact line numbers.
Modifications:
1. Searches globally if local context match fails (handles moved code).
2. Non-blocking: Prints notices for skipped hunks/files instead of exiting with error.
"""

import sys
import re
from pathlib import Path
from typing import List, Tuple, Optional
from difflib import SequenceMatcher


class PatchHunk:
    """Represents a single hunk in a patch file."""
    
    def __init__(self, old_start: int, old_count: int, new_start: int, new_count: int):
        self.old_start = old_start
        self.old_count = old_count
        self.new_start = new_start
        self.new_count = new_count
        self.old_lines: List[str] = []
        self.new_lines: List[str] = []


class FilePatch:
    """Represents patches for a single file."""
    
    def __init__(self, old_path: str, new_path: str):
        self.old_path = old_path
        self.new_path = new_path
        self.hunks: List[PatchHunk] = []


def parse_patch_file(patch_content: str) -> List[FilePatch]:
    """Parse a unified diff patch file."""
    patches = []
    current_patch = None
    current_hunk = None
    
    lines = patch_content.split('\n')
    i = 0
    
    while i < len(lines):
        line = lines[i]
        
        # File header
        if line.startswith('--- '):
            old_path = line[4:].split('\t')[0]
            i += 1
            if i < len(lines) and lines[i].startswith('+++ '):
                new_path = lines[i][4:].split('\t')[0]
                current_patch = FilePatch(old_path, new_path)
                patches.append(current_patch)
        
        # Hunk header
        elif line.startswith('@@'):
            match = re.match(r'@@ -(\d+),?(\d*) \+(\d+),?(\d*) @@', line)
            if match:
                old_start = int(match.group(1))
                old_count = int(match.group(2)) if match.group(2) else 1
                new_start = int(match.group(3))
                new_count = int(match.group(4)) if match.group(4) else 1
                
                current_hunk = PatchHunk(old_start, old_count, new_start, new_count)
                if current_patch:
                    current_patch.hunks.append(current_hunk)
        
        # Hunk content
        elif current_hunk is not None:
            if line.startswith('-'):
                current_hunk.old_lines.append(line[1:])
            elif line.startswith('+'):
                current_hunk.new_lines.append(line[1:])
            elif line.startswith(' '):
                # Context line
                current_hunk.old_lines.append(line[1:])
                current_hunk.new_lines.append(line[1:])
        
        i += 1
    
    return patches


def normalize_path(patch_path: str, base_dir: Path) -> Optional[Path]:
    """
    Normalize a patch path to find the actual file.
    Handles different base paths and finds the correct file location.
    """
    # Remove the MacOS-patches/ prefix if present
    if patch_path.startswith('MacOS-patches/'):
        patch_path = patch_path[14:]
    
    # Remove /home/runner/source/OpenSpace/ prefix if present
    if 'OpenSpace/' in patch_path:
        patch_path = patch_path.split('OpenSpace/', 1)[1]
    
    # Try to find the file relative to base_dir
    target = base_dir / patch_path
    if target.exists():
        return target
    
    # Try searching for the file by name in the base directory
    filename = Path(patch_path).name
    matches = list(base_dir.rglob(filename))
    
    # Filter matches to find the most likely candidate
    for match in matches:
        rel_path = str(match.relative_to(base_dir))
        if patch_path.endswith(rel_path) or rel_path.endswith(patch_path):
            return match
    
    return None


def match_window(content_lines: List[str], search_stripped: List[str], 
                 start_idx: int, end_idx: int) -> Optional[int]:
    """Helper to perform fuzzy matching within a specific range of lines."""
    best_match_pos = None
    best_match_ratio = 0.0
    search_len = len(search_stripped)

    # Sanity check
    if end_idx > len(content_lines):
        end_idx = len(content_lines)
    if start_idx < 0:
        start_idx = 0
        
    for i in range(start_idx, end_idx - search_len + 1):
        window = content_lines[i:i + search_len]
        window_stripped = [line.strip() for line in window if line.strip()]
        
        if not window_stripped:
            continue
        
        # Use sequence matcher for fuzzy matching
        matcher = SequenceMatcher(None, search_stripped, window_stripped)
        ratio = matcher.ratio()
        
        # High confidence match
        if ratio > best_match_ratio and ratio > 0.8:
            best_match_ratio = ratio
            best_match_pos = i
            
            # Optimization: If it's a perfect match, stop looking
            if ratio == 1.0:
                return i

    return best_match_pos


def find_best_match(content_lines: List[str], search_lines: List[str], 
                    start_hint: int = 0) -> Optional[int]:
    """
    Find the best match for search_lines in content_lines.
    Priority:
    1. Fuzzy match near start_hint.
    2. Strict match (ignoring whitespace) ANYWHERE in file.
    3. Fuzzy match ANYWHERE in file.
    """
    if not search_lines:
        return None
    
    # Remove empty lines and strip whitespace for matching
    search_stripped = [line.strip() for line in search_lines if line.strip()]
    if not search_stripped:
        return None
    
    # Strategy 1: Search in a window around the hint (Fuzzy)
    # This preserves the original logic for speed and likely location
    search_start = max(0, start_hint - 100)
    search_end = min(len(content_lines), start_hint + 200)
    
    pos = match_window(content_lines, search_stripped, search_start, search_end)
    if pos is not None:
        return pos

    # Strategy 2: Search GLOBALLY for an exact match (ignoring whitespace)
    # This handles code that moved significantly up or down
    for i in range(len(content_lines) - len(search_lines) + 1):
        window = content_lines[i:i + len(search_lines)]
        window_stripped = [line.strip() for line in window if line.strip()]
        if window_stripped == search_stripped:
             return i

    # Strategy 3: Search GLOBALLY (Fuzzy)
    # Last resort: Code moved AND changed slightly
    # (Searching the whole file with SequenceMatcher is slow, but necessary here)
    return match_window(content_lines, search_stripped, 0, len(content_lines))


def apply_reverse_patch(file_path: Path, patch: FilePatch) -> Tuple[bool, int]:
    """
    Apply a reverse patch to a file.
    Returns (True if file was written to, count of skipped hunks).
    """
    skipped_hunks = 0
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        content_lines = content.split('\n')
        modified = False
        
        # Process hunks in reverse order to maintain line numbers
        for hunk_idx, hunk in enumerate(reversed(patch.hunks)):
            # In reverse mode, we want to replace new_lines with old_lines
            search_lines = hunk.new_lines
            replace_lines = hunk.old_lines
            
            # Find the location of the content to replace
            start_pos = find_best_match(content_lines, search_lines, hunk.new_start - 1)
            
            if start_pos is not None:
                # Replace the content
                end_pos = start_pos + len(search_lines)
                content_lines[start_pos:end_pos] = replace_lines
                modified = True
                
                # Check if location was unexpected
                diff = abs(start_pos - (hunk.new_start - 1))
                if diff > 100:
                     print(f"  ✓ Applied hunk #{len(patch.hunks)-hunk_idx} (found moved by {diff} lines)")
                else:
                     print(f"  ✓ Applied hunk #{len(patch.hunks)-hunk_idx}")
            else:
                # NOTICE ONLY - Do not fail
                print(f"  [NOTICE] Skipping hunk #{len(patch.hunks)-hunk_idx}: Content not found.")
                print(f"           Expected around line {hunk.new_start}")
                skipped_hunks += 1

        if modified:
            # Write the modified content back
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write('\n'.join(content_lines))
            return True, skipped_hunks
        else:
            print(f"  ℹ No changes applied to file")
            return False, skipped_hunks
    
    except Exception as e:
        print(f"  [NOTICE] Exception processing file: {e}")
        return False, len(patch.hunks)


def main():
    if len(sys.argv) < 2:
        print("Usage: python reverse_patch.py <patch_file> [base_directory]")
        sys.exit(1)
    
    patch_file_path = Path(sys.argv[1])
    base_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else Path.cwd()
    
    if not patch_file_path.exists():
        print(f"Error: Patch file '{patch_file_path}' not found")
        sys.exit(1)
    
    if not base_dir.is_dir():
        print(f"Error: Base directory '{base_dir}' not found")
        sys.exit(1)
    
    print(f"Reading patch file: {patch_file_path}")
    print(f"Base directory: {base_dir}")
    print()
    
    with open(patch_file_path, 'r', encoding='utf-8') as f:
        patch_content = f.read()
    
    patches = parse_patch_file(patch_content)
    print(f"Found {len(patches)} file(s) to patch")
    print()
    
    files_patched = 0
    files_skipped = 0
    total_skipped_hunks = 0
    
    for patch in patches:
        # Use the new_path since we're reversing
        target_path = normalize_path(patch.new_path, base_dir)
        
        if target_path is None:
            print(f"  [NOTICE] Could not find file: {patch.new_path} - Skipping.")
            files_skipped += 1
            continue
        
        print(f"Patching: {target_path.relative_to(base_dir)}")
        
        was_modified, skipped_count = apply_reverse_patch(target_path, patch)
        
        if was_modified:
            files_patched += 1
        
        total_skipped_hunks += skipped_count
        print()
    
    print("=" * 60)
    print(f"Summary: {files_patched} files modified.")
    print(f"         {files_skipped} files not found.")
    print(f"         {total_skipped_hunks} individual hunks skipped (not found).")
    
    # Explicitly exit 0 even if things were skipped, as requested
    print("Patch process completed.")
    sys.exit(0)


if __name__ == "__main__":
    main()
