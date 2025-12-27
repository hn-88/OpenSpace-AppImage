import sys
import os
import re

def parse_diff_file(diff_filename):
    """
    Parses a diff file and returns a list of operations.
    Each operation is a dict: {'file': str, 'find': str, 'replace': str}
    """
    changes = []
    current_file = None
    
    # Regex to capture the filename from "+++ b/path/to/file"
    # We accept a/ or b/ or no prefix, but standard git diffs usually use b/ for the new file
    file_pattern = re.compile(r'^\+\+\+ [ab]/(.*)$')
    
    try:
        with open(diff_filename, 'r', encoding='utf-8') as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        print(f"Error: Diff file '{diff_filename}' not found.")
        sys.exit(1)

    i = 0
    while i < len(lines):
        line = lines[i]

        # 1. Detect the File Path
        if line.startswith('+++ '):
            match = file_pattern.match(line)
            if match:
                current_file = match.group(1)
            else:
                # Fallback if regex doesn't match (e.g. no a/ b/ prefix)
                current_file = line[4:].strip()
            i += 1
            continue

        # 2. Detect a Hunk Header (@@ -x,y +x,y @@)
        if line.startswith('@@ '):
            i += 1
            
            # buffers for the current contiguous block of changes
            find_block = []
            replace_block = []
            
            # Process lines inside this hunk
            while i < len(lines):
                sub_line = lines[i]
                
                # End of hunk detection:
                # If we hit a new diff command, a new file header, or a new hunk header
                if sub_line.startswith('diff ') or sub_line.startswith('+++ ') or sub_line.startswith('@@ '):
                    break
                
                if sub_line.startswith('-'):
                    # This is text to REMOVE (Find)
                    find_block.append(sub_line[1:]) 
                
                elif sub_line.startswith('+'):
                    # This is text to ADD (Replace)
                    replace_block.append(sub_line[1:]) 
                
                elif sub_line.startswith(' '):
                    # This is a CONTEXT line. 
                    # If we have accumulated a block of changes, this context line 
                    # acts as a separator. We must save the previous operation now.
                    if find_block or replace_block:
                        changes.append({
                            'file': current_file,
                            'find': '\n'.join(find_block),
                            'replace': '\n'.join(replace_block)
                        })
                        find_block = []
                        replace_block = []
                
                # Note: We ignore '\ No newline at end of file' markers for this logic
                
                i += 1
            
            # If the hunk ended but we still have data in buffers (e.g. end of file)
            if find_block or replace_block:
                changes.append({
                    'file': current_file,
                    'find': '\n'.join(find_block),
                    'replace': '\n'.join(replace_block)
                })
            
            # Don't increment i here, the outer loop needs to process the line that broke the inner loop
            continue

        i += 1

    return changes

def apply_changes(changes):
    """
    Applies the list of changes to the actual files on disk.
    """
    print(f"Loaded {len(changes)} operations from diff.\n")

    for idx, op in enumerate(changes, 1):
        filepath = op['file']
        find_text = op['find']
        replace_text = op['replace']

        print(f"[{idx}] Patching {filepath}...")

        if not os.path.exists(filepath):
            print(f"    ERROR: File not found: {filepath}. Skipping.")
            continue

        try:
            # Read file
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()

            # 1. Handle Pure Additions (New Files or purely added blocks)
            # If find_text is empty, it's an insertion.
            # However, without context lines, we don't know WHERE to insert.
            # Standard behavior for 'replace' script: 
            # If find_text is empty, we can't replace. 
            # BUT, if the file was empty (or new), we might just overwrite.
            if not find_text and replace_text:
                # Only safe assumption: Append? Or skip?
                # For this specific request, let's assume we only do replacements 
                # where we can match text. 
                if find_text == "":
                    print("    SKIPPING: Pure insertion detected (no 'find' text). This script requires text to replace.")
                    continue

            # 2. Perform Search
            if find_text not in content:
                print("    FAILED: Search text not found in file.")
                # Optional: Print first line of search text to help debug
                first_line = find_text.split('\n')[0] if find_text else "Empty"
                print(f"    (Looked for: '{first_line}...')")
                continue

            # 3. Perform Replacement (First instance only)
            new_content = content.replace(find_text, replace_text, 1)

            # Write back
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(new_content)
            
            print("    Success.")

        except Exception as e:
            print(f"    ERROR: {e}")

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 smart_patcher.py <diff_file>")
        sys.exit(1)

    diff_file = sys.argv[1]
    
    # 1. Parse
    print(f"Parsing {diff_file}...")
    operations = parse_diff_file(diff_file)
    
    # 2. Apply
    apply_changes(operations)

if __name__ == "__main__":
    main()
