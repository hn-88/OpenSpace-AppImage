cd working-dir
export LC_ALL=C
#LC_ALL=C diff -ruN --exclude='build' --exclude='bin' --exclude='*.o' --exclude='*.a' --exclude='*.so' --exclude='*.dylib' --exclude='*.dll' --exclude='*.exe' --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.pdf' --exclude='*.zip' --exclude='*.tar' --exclude='*.gz' --exclude='*.bin' /Users/user/source/OpenSpace ./ | LC_ALL=C sed 's|/Users/user/source/OpenSpace/||g; s|./||g' > changes-to-appimageversion.diff
LC_ALL=C diff -ruN \
  --exclude='build' \
  --exclude='bin' \
  --exclude='.git' \
  --exclude='.DS_Store' \
  /Users/hari/source/OpenSpace ./ > temp_full.diff

python3 << 'EOF' > changes-to-appimageversion.diff
import re

with open('temp_full.diff', 'r', encoding='utf-8', errors='ignore') as f:
    content = f.read()

# Split by diff blocks (using the actual format from diff -ruN)
blocks = re.split(r'(^diff -ruN .*$)', content, flags=re.MULTILINE)

for i in range(1, len(blocks), 2):
    header = blocks[i]
    body = blocks[i+1] if i+1 < len(blocks) else ''
    
    # Skip binary file notices
    if 'Binary files' in (header + body):
        continue
    
    # Check if this diff is for a file we want
    if (header.endswith('.cpp') or header.endswith('.h') or 
        header.endswith('.glsl') or '/shaders/' in header):
        
        # Strip paths
        output = header + body
        output = output.replace('/Users/hari/source/OpenSpace/', '')
        output = output.replace('./', '')
        print(output, end='')
EOF

# rm temp_full.diff

