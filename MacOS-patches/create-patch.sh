cd working-dir
LC_ALL=C diff -ruN /full/path/to/old-dir/ ./ | sed 's|/full/path/to/old-dir/||g; s|./||g' > changes.diff
