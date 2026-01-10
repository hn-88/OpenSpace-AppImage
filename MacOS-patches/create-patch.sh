cd working-dir
export LC_ALL=C
LC_ALL=C diff -ruN --exclude='build' --exclude='bin' --exclude='*.o' --exclude='*.a' --exclude='*.so' --exclude='*.dylib' --exclude='*.dll' --exclude='*.exe' --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.pdf' --exclude='*.zip' --exclude='*.tar' --exclude='*.gz' --exclude='*.bin' /Users/user/source/OpenSpace ./ | LC_ALL=C sed 's|/Users/user/source/OpenSpace/||g; s|./||g' > changes-to-appimageversion.diff
