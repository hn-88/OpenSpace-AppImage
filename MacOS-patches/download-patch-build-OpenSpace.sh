#!/bin/bash

# OpenSpace macOS Build Script
# This script automates the building of OpenSpace on macOS with single-precision patches

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OPENSPACE_VERSION="0.21.3plus"
BUILD_TYPE="Release"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}OpenSpace macOS Build Script${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Step 1: Check for Homebrew
print_info "Checking for Homebrew..."
if ! command -v brew &> /dev/null; then
    print_error "Homebrew is not installed!"
    echo ""
    echo "Please install Homebrew first by running:"
    echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo ""
    echo "Or visit: https://brew.sh"
    exit 1
else
    print_success "Homebrew found: $(brew --version | head -n1)"
fi

# Step 2: Check for Xcode Command Line Tools
print_info "Checking for Xcode Command Line Tools..."
if ! xcode-select -p &> /dev/null; then
    print_error "Xcode Command Line Tools are not installed!"
    echo ""
    echo "Please install them by running:"
    echo "xcode-select --install"
    echo ""
    echo "Or install full Xcode from the App Store: https://apps.apple.com/us/app/xcode/id497799835"
    exit 1
else
    print_success "Xcode Command Line Tools found at: $(xcode-select -p)"
fi

# Check for CMake
print_info "Checking for CMake..."
if ! command -v cmake &> /dev/null; then
    print_warning "CMake not found. Installing via Homebrew..."
    brew install cmake
else
    print_success "CMake found: $(cmake --version | head -n1)"
fi

echo ""
print_info "All prerequisites satisfied!"
echo ""

# Step 3: Determine OpenSpace source location
print_info "OpenSpace Source Location Setup"
echo ""
echo "Do you want to:"
echo "  1) Clone OpenSpace to a new directory"
echo "  2) Use an existing OpenSpace clone"
echo ""
read -p "Enter choice [1-2]: " clone_choice

case $clone_choice in
    1)
        read -p "Enter directory path to clone into (default: ~/source/OpenSpace): " openspace_path
        openspace_path=${openspace_path:-"$HOME/source/OpenSpace"}
        
        # Expand tilde
        openspace_path="${openspace_path/#\~/$HOME}"
        
        if [ -d "$openspace_path" ]; then
            print_error "Directory already exists: $openspace_path"
            read -p "Delete and re-clone? [y/N]: " delete_confirm
            if [[ $delete_confirm =~ ^[Yy]$ ]]; then
                rm -rf "$openspace_path"
            else
                print_error "Build cancelled."
                exit 1
            fi
        fi
        
        print_info "Cloning OpenSpace to: $openspace_path"
        mkdir -p "$(dirname "$openspace_path")"
        git clone --recursive https://github.com/OpenSpace/OpenSpace.git "$openspace_path"
        cd "$openspace_path"
        git checkout "296081379b18da62686d2c0635c2478daae1b68b" --recurse-submodules
        ;;
    2)
        read -p "Enter path to existing OpenSpace directory: " openspace_path
        openspace_path="${openspace_path/#\~/$HOME}"
        
        if [ ! -d "$openspace_path" ]; then
            print_error "Directory does not exist: $openspace_path"
            exit 1
        fi
        
        if [ ! -f "$openspace_path/CMakeLists.txt" ]; then
            print_error "This doesn't appear to be an OpenSpace directory (no CMakeLists.txt found)"
            exit 1
        fi
        
        cd "$openspace_path"
        print_success "Using existing OpenSpace at: $openspace_path"
        ;;
    *)
        print_error "Invalid choice"
        exit 1
        ;;
esac

# Create build directory
mkdir -p build

echo ""
print_success "OpenSpace source ready at: $openspace_path"
echo ""

# Step 4: Install Homebrew dependencies
print_info "Installing Homebrew dependencies..."
echo "This may take some time..."
echo ""

brew update

DEPS="python glm glew boost freeimage mpv vulkan-headers vulkan-loader brotli gdal qt@6"
for dep in $DEPS; do
    if brew list "$dep" &>/dev/null; then
        print_success "$dep already installed"
    else
        print_info "Installing $dep..."
        brew install "$dep"
    fi
done

print_success "All dependencies installed!"
echo ""

# Step 5: Apply patches
print_info "Setting up patch files..."
echo ""

PATCHES_REPO_DIR="$openspace_path/OpenSpace-AppImage"

if [ -d "$PATCHES_REPO_DIR" ]; then
    print_info "OpenSpace-AppImage directory exists, updating..."
    cd "$PATCHES_REPO_DIR"
    git pull
    cd "$openspace_path"
else
    print_info "Cloning OpenSpace-AppImage repository..."
    git clone https://github.com/hn-88/OpenSpace-AppImage/ "$PATCHES_REPO_DIR"
fi

patches_dir="$PATCHES_REPO_DIR/MacOS-patches"

if [ ! -d "$patches_dir" ]; then
    print_error "MacOS-patches directory not found in cloned repository"
    exit 1
fi

print_success "Patch files ready at: $patches_dir"
echo ""

read -p "Apply macOS reverse patches? [Y/n]: " apply_reverse
apply_reverse=${apply_reverse:-Y}

if [[ $apply_reverse =~ ^[Yy]$ ]]; then
    print_info "Applying reverse patches..."
    cp -v "$patches_dir/reverse_patch.py" "$openspace_path/"
    cp -v "$patches_dir/MacOS-reverse-diff-edited.patch" "$openspace_path/"
    python3 reverse_patch.py MacOS-reverse-diff-edited.patch
    print_success "Reverse patches applied"
fi

read -p "Apply macOS smart patches? [Y/n]: " apply_smart
apply_smart=${apply_smart:-Y}

if [[ $apply_smart =~ ^[Yy]$ ]]; then
    print_info "Applying smart patches..."
    cp -v "$patches_dir/smart_patcher.py" "$openspace_path/"
    cp -v "$patches_dir/MacOS-patches.txt" "$openspace_path/"
    python3 smart_patcher.py MacOS-patches.txt
    print_success "Smart patches applied"
fi

read -p "Apply single-precision patches? [Y/n]: " apply_single
apply_single=${apply_single:-Y}
if [[ $apply_single =~ ^[Yy]$ ]]; then
    print_info "Setting up single-precision patches..."
    
    SINGLE_PRECISION_DIR="$openspace_path/OpenSpace-single-precision"
    
    if [ -d "$SINGLE_PRECISION_DIR" ]; then
        print_info "OpenSpace-single-precision directory exists, updating..."
        cd "$SINGLE_PRECISION_DIR"
        git pull
        cd "$openspace_path"
    else
        print_info "Cloning single-precision patches repository..."
        git clone https://github.com/hn-88/OpenSpace-single-precision.git "$SINGLE_PRECISION_DIR"
    fi
    
    cd "$SINGLE_PRECISION_DIR"
    cp -v ghoul-patches/* "$openspace_path/"
    cp -v diff-files/* "$openspace_path/"
    cd "$openspace_path"
    
    mv -v uniform_conversion.h ext/ghoul/src/opengl/uniform_conversion.h
    mv -v ghoul-src-opengl-programobject.cpp ext/ghoul/src/opengl/programobject.cpp
    
    python3 smart_patcher.py applesilicon.diffedited.txt
    
    print_info "Checking for double precision types in GLSL files..."
    GREP_OUTPUT=$(grep -rEn --include="*.glsl" --include="*.hglsl" --color=always "\b(double|dvec[234]?|dmat[234]?)\b" . || true)
    if [ -n "$GREP_OUTPUT" ]; then
        print_warning "Found double precision types in GLSL files:"
        echo "$GREP_OUTPUT"
    else
        print_success "No double precision types found in GLSL files"
    fi
    
    print_info "Fixing shaders..."
    python3 smart_patcher.py changes-to-shaders.diff
    
    print_info "Fixing ghoul_assert in setUniform functions..."
    find . -type f -name "*.cpp" -exec grep -l 'ghoul_assert(location != -1, "Location must not be -1");' {} + | while read file; do
        echo "Fixing: $file"
        sed -i '' 's/ghoul_assert(location != -1, "Location must not be -1");/if (location == -1){ if (_ignoreUniformLocationError){ return; }ghoul_assert(false, "Location must not be -1");return;}/g' "$file"
    done
    
    print_success "Single-precision patches applied"
fi

echo ""
print_success "All patches applied successfully!"
echo ""

# Step 6: Configure CMake
print_info "Configuring CMake..."
cd "$openspace_path/build"

cmake -G Xcode \
    -Wno-dev \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_CXX_STANDARD=20 \
    -DONLY_ACTIVE_ARCH=YES \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_CXX_FLAGS="-Wno-error -D_FILE_OFFSET_BITS=64" \
    -DCMAKE_C_FLAGS="-Wno-error -D_FILE_OFFSET_BITS=64" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_PREFIX_PATH=/opt/homebrew \
    -DBUILD_TESTS=OFF \
    -DCOMPILE_WARNING_AS_ERROR=OFF \
    -DOPENSPACE_HAVE_TESTS=OFF \
    -DSGCT_BUILD_TESTS=OFF \
    -DSGCT_DEP_INCLUDE_LIBPNG=OFF \
    -DPNG_PNG_INCLUDE_DIR=$(brew --prefix libpng)/include \
    "$openspace_path"

print_success "CMake configuration complete!"
echo ""

# Step 7: Build
print_info "Building OpenSpace..."
echo "This can take a considerable amount of time (3 to 30+ minutes)..."
echo ""

read -p "Proceed with build? [Y/n]: " proceed_build
proceed_build=${proceed_build:-Y}

if [[ ! $proceed_build =~ ^[Yy]$ ]]; then
    print_warning "Build cancelled by user"
    echo ""
    echo "To build later, run:"
    echo "cd $openspace_path/build"
    echo "cmake --build . --config $BUILD_TYPE" --parallel  --
    exit 0
fi
echo "Starting build at "
date;cmake --build . --config Release --parallel  --
echo "Finished build process at "
date

print_success "Build complete!"
echo ""


# Final summary
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Build Successful!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "OpenSpace.app has been built at:"
echo "$openspace_path/bin/Release/OpenSpace.app"
echo ""
echo "To run OpenSpace, execute:"
echo "cd $openspace_path/bin/Release"
echo "./OpenSpace.app/Contents/MacOS/OpenSpace"
echo ""
echo -e "${YELLOW}Note:${NC} If macOS prevents running the app due to security settings,"
echo "go to System Preferences > Security & Privacy and allow the app to run."
echo ""
echo "See: https://github.com/hn-88/OpenSpace-AppImage/wiki/How-to-run-unsigned-apps-on-Mac"
echo ""
