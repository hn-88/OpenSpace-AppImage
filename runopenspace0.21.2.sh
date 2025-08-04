arch=$(uname -m)
if [[ "$arch" == "x86_64" ]]; then
  export QT_PLUGIN_PATH=lib/x86_64-linux-gnu/qt6/plugins/
elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
  export QT_PLUGIN_PATH=lib/aarch64-linux-gnu/qt6/plugins/
fi

export OPENSPACE_USER="$PWD/OpenSpace/user"  # <-- you can change this path to some directory where you have write access
export OPENSPACE_GLOBEBROWSING="$PWD/OpenSpaceData" # <-- you can change this path to some directory where you have write access
./OpenSpace-0.21.2*64.AppImage
