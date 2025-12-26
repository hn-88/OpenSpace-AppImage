#!/usr/bin/env python3
"""
Reverse patch script for OpenSpace macOS patches.
Applies patches in reverse without requiring exact line numbers.
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


def find_best_match(content_lines: List[str], search_lines: List[str], 
                    start_hint: int = 0) -> Optional[int]:
    """
    Find the best match for search_lines in content_lines using fuzzy matching.
    Returns the starting line number if found, None otherwise.
    """
    if not search_lines:
        return None
    
    # Remove empty lines and strip whitespace for matching
    search_stripped = [line.strip() for line in search_lines if line.strip()]
    if not search_stripped:
        return None
    
    best_match_pos = None
    best_match_ratio = 0.0
    
    # Search in a window around the hint
    search_start = max(0, start_hint - 100)
    search_end = min(len(content_lines), start_hint + 200)
    
    for i in range(search_start, search_end - len(search_lines) + 1):
        window = content_lines[i:i + len(search_lines)]
        window_stripped = [line.strip() for line in window if line.strip()]
        
        if not window_stripped:
            continue
        
        # Use sequence matcher for fuzzy matching
        matcher = SequenceMatcher(None, search_stripped, window_stripped)
        ratio = matcher.ratio()
        
        if ratio > best_match_ratio and ratio > 0.7:  # 70% similarity threshold
            best_match_ratio = ratio
            best_match_pos = i
    
    return best_match_pos


def apply_reverse_patch(file_path: Path, patch: FilePatch) -> bool:
    """
    Apply a reverse patch to a file (swap old and new content).
    Returns True if successful, False otherwise.
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        content_lines = content.split('\n')
        modified = False
        
        # Process hunks in reverse order to maintain line numbers
        for hunk in reversed(patch.hunks):
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
                print(f"  ✓ Applied hunk at line {start_pos + 1}")
            else:
                print(f"  ⚠ Could not find match for hunk (expected around line {hunk.new_start})")
                # Try a more lenient search
                for i in range(len(content_lines) - len(search_lines) + 1):
                    window = content_lines[i:i + len(search_lines)]
                    if window == search_lines:
                        content_lines[i:i + len(search_lines)] = replace_lines
                        modified = True
                        print(f"  ✓ Found exact match at line {i + 1}")
                        break
        
        if modified:
            # Write the modified content back
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write('\n'.join(content_lines))
            return True
        else:
            print(f"  ℹ No changes applied")
            return False
    
    except Exception as e:
        print(f"  ✗ Error: {e}")
        return False


def main():
    if len(sys.argv) < 2:
        print("Usage: python reverse_patch.py <patch_file> [base_directory]")
        print("  patch_file: Path to the patch file")
        print("  base_directory: Base directory of the OpenSpace repo (default: current directory)")
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
    
    success_count = 0
    fail_count = 0
    
    for patch in patches:
        # Use the new_path since we're reversing
        target_path = normalize_path(patch.new_path, base_dir)
        
        if target_path is None:
            print(f"✗ Could not find file: {patch.new_path}")
            fail_count += 1
            continue
        
        print(f"Patching: {target_path.relative_to(base_dir)}")
        
        if apply_reverse_patch(target_path, patch):
            success_count += 1
        else:
            fail_count += 1
        
        print()
    
    print("=" * 60)
    print(f"Summary: {success_count} succeeded, {fail_count} failed")
    
    #if fail_count > 0:
    #    sys.exit(1)


if __name__ == "__main__":
    main()
