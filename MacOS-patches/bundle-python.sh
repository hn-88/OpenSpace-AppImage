#!/bin/bash
#
# Run the following from the bin directory which contains OpenSpace.app
FW="OpenSpace.app/Contents/Frameworks"
SRC="/opt/homebrew/opt/python@3.14/Frameworks/Python.framework"

# copy the whole framework (preserves Versions/3.14/Python structure)
cp -R "$SRC" "$FW/"
chmod -R u+w "$FW/Python.framework"

# fix the framework's own id
install_name_tool -id "@executable_path/../Frameworks/Python.framework/Versions/3.14/Python" \
  "$FW/Python.framework/Versions/3.14/Python"

# rewrite libvapoursynth-script.0.dylib's reference to the new relative location
chmod u+w "$FW/libvapoursynth-script.0.dylib"
install_name_tool -change \
  "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python" \
  "@executable_path/../Frameworks/Python.framework/Versions/3.14/Python" \
  "$FW/libvapoursynth-script.0.dylib"

codesign --force --sign - "$FW/Python.framework/Versions/3.14/Python"
codesign --force --sign - "$FW/Python.framework"
codesign --force --sign - "$FW/libvapoursynth-script.0.dylib" 