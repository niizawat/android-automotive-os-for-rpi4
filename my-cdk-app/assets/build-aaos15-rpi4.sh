#!/usr/bin/env bash
# 
# Android 15 AAOS for Raspberry Pi 4 Build Script
# Target: aosp_rpi4_car-bp1a-userdebug (Android Automotive)
# 
# Based on documentation:
# https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/refs/heads/android-15.0/README.md
#

set -euo pipefail

# ===== Configuration =====
BUILD_DIR="${BUILD_DIR:-/build/android-15.0_rpi4_car}"
readonly BUILD_DIR
readonly TARGET="aosp_rpi4_car-bp1a-userdebug"
LOG_FILE="${BUILD_DIR}/build-$(date +%Y%m%d_%H%M%S).log"
readonly LOG_FILE


# ===== Logging Configuration =====
log() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$message" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $*" >&2
    exit 1
}

# ===== Android Build Dependencies Installation =====
install_android_build_dependencies() {
    log "=== Installing Android Build Dependencies ==="
    
    # Update package lists
    sudo apt-get update -y
    
    # Enable multiarch support for i386 packages if needed
    log "Enabling multiarch support..."
    sudo dpkg --add-architecture i386
    sudo apt-get update -y
    
    # Install essential build tools
    sudo apt-get install -y \
        build-essential \
        git \
        curl \
        python3 \
        python3-pip \
        python-is-python3 \
        libxml2-utils \
        zip \
        unzip \
        flex \
        bison \
        gperf \
        libssl-dev \
        libc6-dev \
        libncurses5-dev \
        x11proto-core-dev \
        libx11-dev \
        libreadline-dev \
        libgl1-mesa-dev \
        g++-multilib \
        mingw-w64 \
        tofrodos \
        python3-markdown \
        xsltproc \
        zlib1g-dev \
        ccache \
        bc \
        rsync \
        dosfstools \
        e2fsprogs \
        fdisk \
        kpartx \
        mtools
    
    # Install i386 packages separately (optional for Android 15)
    log "Installing 32-bit support libraries..."
    sudo apt-get install -y zlib1g-dev:i386 || {
        log "WARNING: Failed to install zlib1g-dev:i386. This may not be required for Android 15 build."
    }
    
    # Install OpenJDK 17 (required for Android 15)
    sudo apt-get install -y openjdk-17-jdk
    
    # Set Java 17 as default
    sudo update-alternatives --install /usr/bin/java java /usr/lib/jvm/java-17-openjdk-amd64/bin/java 1
    sudo update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/java-17-openjdk-amd64/bin/javac 1
    
    log "Android build dependencies installation completed"
}

# ===== Environment Variables Setup =====
setup_environment_variables() {
    log "=== Setting up Environment Variables ==="
    
    # Set HOME environment variable if not already set
    if [ -z "${HOME:-}" ]; then
        # Try to determine home directory from current user
        if [ -n "${USER:-}" ]; then
            HOME="/home/${USER}"
        elif [ -n "$(whoami 2>/dev/null)" ]; then
            HOME="/home/$(whoami)"
        else
            # Fallback to root home if unable to determine user
            HOME="/root"
        fi
        export HOME
        log "HOME environment variable set to: $HOME"
    else
        log "HOME environment variable already set: $HOME"
    fi
    
    # Ensure HOME directory exists
    if [ ! -d "$HOME" ]; then
        log "Creating HOME directory: $HOME"
        sudo mkdir -p "$HOME"
        sudo chown "$(whoami):$(whoami)" "$HOME" 2>/dev/null || true
    fi
    
    # Set other commonly needed environment variables for AOSP build
    export LANG="${LANG:-en_US.UTF-8}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
    
    # Verify critical environment variables
    log "Environment variables verification:"
    log "  HOME: ${HOME}"
    log "  USER: ${USER:-$(whoami)}"
    log "  LANG: ${LANG}"
    log "  LC_ALL: ${LC_ALL}"
    
    log "Environment variables setup completed"
}

# ===== System Requirements Check =====
check_prerequisites() {
    log "=== Checking System Requirements ==="
    
    # Check Ubuntu version
    if ! grep -q "22.04" /etc/os-release 2>/dev/null; then
        log "WARNING: Operation not guaranteed on non-Ubuntu 22.04 LTS systems"
    fi
    
    # Check required commands (should be available after dependency installation)
    local required_commands=(git curl python3 make gcc g++ java javac)
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Required command '$cmd' not found. Please ensure dependencies are properly installed."
        fi
    done
    
    # Verify Java version
    local java_version
    java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
    if [ "$java_version" != "17" ]; then
        log "WARNING: Java 17 is recommended for Android 15 build (current: Java $java_version)"
    fi
    
    # Check disk space (minimum 300GB required)
    local available_space
    available_space=$(df "$BUILD_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    local required_space=$((300 * 1024 * 1024)) # 300GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "WARNING: Insufficient disk space (available: $(($available_space / 1024 / 1024))GB, required: 300GB)"
    fi
    
    log "System requirements check completed"
}


# ===== Git Configuration =====
configure_git() {
    log "=== Configuring Git ==="
    
    # Verify HOME environment variable is set
    if [ -z "${HOME:-}" ]; then
        error "HOME environment variable is not set. This is required for git configuration."
    fi
    
    # Default git configuration values (can be overridden by environment variables)
    local git_username="${GIT_USERNAME:-android-builder}"
    local git_email="${GIT_EMAIL:-android-builder@example.com}"
    local git_color_ui="${GIT_COLOR_UI:-auto}"
    
    # Configure git username
    if ! git config --global user.name &> /dev/null; then
        log "Setting git user.name to: $git_username"
        git config --global user.name "$git_username"
    else
        local current_name
        current_name=$(git config --global user.name)
        log "Git user.name already configured: $current_name"
    fi
    
    # Configure git email
    if ! git config --global user.email &> /dev/null; then
        log "Setting git user.email to: $git_email"
        git config --global user.email "$git_email"
    else
        local current_email
        current_email=$(git config --global user.email)
        log "Git user.email already configured: $current_email"
    fi
    
    # Configure git color output
    log "Setting git color.ui to: $git_color_ui"
    git config --global color.ui "$git_color_ui"
    
    # Additional useful git configurations for AOSP development
    log "Setting additional git configurations for AOSP development..."
    git config --global color.branch auto
    git config --global color.diff auto
    git config --global color.status auto
    git config --global core.autocrlf false
    git config --global core.filemode false
    
    log "Git configuration completed"
}

# ===== Repo Tool Installation =====
install_repo_tool() {
    log "=== Installing Repo Tool ==="
    
    # Check if repo command already exists
    if command -v repo &> /dev/null; then
        log "Repo tool is already installed"
        return 0
    fi
    
    # Download repo tool from official source
    log "Downloading repo tool from https://storage.googleapis.com/git-repo-downloads/repo"
    sudo curl -o /usr/local/bin/repo \
        -L https://storage.googleapis.com/git-repo-downloads/repo
    
    # Set executable permissions
    sudo chmod a+x /usr/local/bin/repo
    
    # Verify installation
    if command -v repo &> /dev/null; then
        local repo_version
        repo_version=$(repo --version 2>&1 | head -1 || echo "unknown")
        log "Repo tool installation completed: $repo_version"
    else
        error "Failed to install repo tool"
    fi
}

# ===== Repo Initialization =====
initialize_repo() {
    log "=== Initializing Repo ==="
    
    # Verify HOME environment variable is set (required for repo tool)
    if [ -z "${HOME:-}" ]; then
        error "HOME environment variable is not set. This is required for repo tool operation."
    fi
    
    # Create build directory
    sudo mkdir -p "$BUILD_DIR"
    sudo chown -R "$(whoami):$(whoami)" "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # Initialize repo (shallow clone + remove unnecessary projects for faster setup)
    log "Initializing Android 15.0.0_r32 manifest..."
    repo init -u https://android.googlesource.com/platform/manifest -b android-15.0.0_r32 --depth=1
    
    # Create local_manifests directory and fetch manifests
    curl -o .repo/local_manifests/manifest_brcm_rpi.xml \
        -L https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/android-15.0/manifest_brcm_rpi.xml \
        --create-dirs
    
    # Remove unnecessary projects (reduces download size)
    curl -o .repo/local_manifests/remove_projects.xml \
        -L https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/android-15.0/remove_projects.xml
    
    log "Repo initialization completed"
}

# ===== Source Code Synchronization =====
sync_source_code() {
    log "=== Starting Source Code Synchronization ==="
    
    cd "$BUILD_DIR"
    
    # Set parallel job count (based on CPU core count)
    local jobs
    jobs=$(nproc)
    log "Parallel jobs: $jobs"
    
    # Execute source code synchronization
    repo sync -c --optimized-fetch --prune
    
    log "Source code synchronization completed"
}

# ===== Build Environment Setup =====
setup_build_environment() {
    log "=== Setting up Build Environment ==="
    
    cd "$BUILD_DIR"
    
    # Temporarily disable unbound variable checking for Android build environment
    # Android's build/envsetup.sh uses some undefined variables internally
    set +u
    
    # Setup Android build environment
    log "Sourcing build/envsetup.sh..."
    source build/envsetup.sh
    
    # Select build target
    log "Build target: $TARGET"
    lunch "$TARGET"
    
    # Re-enable unbound variable checking
    set -u
    
    log "Build environment setup completed"
}

# ===== Android Compilation =====
compile_android() {
    log "=== Starting Android 15 AAOS Compilation ==="
    
    cd "$BUILD_DIR"
    
    # Temporarily disable unbound variable checking for Android build environment
    set +u
    
    # Re-setup environment
    log "Re-sourcing build environment for compilation..."
    source build/envsetup.sh
    lunch "$TARGET"
    
    # Re-enable unbound variable checking
    set -u
    
    # Set parallel job count
    local jobs
    jobs=$(nproc)
    log "Compilation parallel jobs: $jobs"
    
    # Execute compilation (temporarily disable unbound variable checking for make)
    log "Building bootimage, systemimage, vendorimage..."
    set +u
    make bootimage systemimage vendorimage -j"$jobs"
    set -u
    
    log "Compilation completed"
}

# ===== Flashable Image Creation =====
create_flashable_image() {
    log "=== Creating Flashable Image ==="
    
    cd "$BUILD_DIR"
    
    # Execute Raspberry Pi 4 image creation script
    if [ -x "./rpi4-mkimg.sh" ]; then
        log "Running rpi4-mkimg.sh..."
        ./rpi4-mkimg.sh
        log "Flashable image creation completed"
    else
        log "WARNING: rpi4-mkimg.sh not found or skipped"
    fi
}

# ===== Build Results Check and Display =====
show_build_results() {
    log "=== Build Results ==="
    
    cd "$BUILD_DIR"
    
    # Check created files
    log "Created image files:"
    find out/ -name "*.img" -o -name "*.zip" -o -name "*.tar.gz" 2>/dev/null | while read -r file; do
        local size
        size=$(du -h "$file" | cut -f1)
        log "  - $(basename "$file") ($size)"
    done
    
    # Build artifacts are ready for external processing
    
    # Build statistics
    local end_time
    end_time=$(date)
    log "Build completion time: $end_time"
    log "Log file: $LOG_FILE"
    log ""
    log "🎉 Android 15 AAOS for Raspberry Pi 4 build completed!"
    log ""
    log "Next steps:"
    log "1. Flash the created image to an SD card"
    log "2. Insert the SD card into Raspberry Pi 4 and boot"
    log "3. Verify Android Automotive OS (AAOS) operation"
}


# ===== Error Handling =====
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "ERROR: An error occurred during build (exit code: $exit_code)"
        log "Please check the log file: $LOG_FILE"
    fi
    exit $exit_code
}

# ===== Main Execution =====
main() {
    local start_time
    start_time=$(date)
    
    # Setup error handling
    trap cleanup EXIT
    
    # Create log directory
    mkdir -p "$(dirname "$LOG_FILE")"
    
    log "=========================================="
    log "Android 15 AAOS for Raspberry Pi 4 build started"
    log "Target: $TARGET"
    log "Build directory: $BUILD_DIR"
    log "Start time: $start_time"
    log "=========================================="
    
    # Execute build steps
    install_android_build_dependencies
    setup_environment_variables
    check_prerequisites
    configure_git
    install_repo_tool
    initialize_repo
    sync_source_code
    setup_build_environment
    compile_android
    create_flashable_image
    show_build_results
    
    log "=========================================="
    log "✅ All build steps completed successfully"
    log "=========================================="
}

# ===== Usage Display =====
show_usage() {
    cat << EOF
Usage: $0 [options]

Builds Android 15 AAOS for Raspberry Pi 4.

Options:
    -h, --help          Show this help message
    -d, --build-dir DIR Specify build directory (default: $BUILD_DIR)

Environment Variables:
    BUILD_DIR           Build directory path (default: /build/android-15.0_rpi4_car)
    GIT_USERNAME        Git user name (default: android-builder)
    GIT_EMAIL           Git user email (default: android-builder@example.com)
    GIT_COLOR_UI        Git color output setting (default: auto)

Examples:
    $0                          # Build with default settings
    $0 -d /data/android-build   # Specify custom build directory
    
    # With custom git settings
    GIT_USERNAME="John Doe" GIT_EMAIL="john@example.com" $0
    
    # Complete custom setup
    BUILD_DIR="/custom/build" GIT_USERNAME="Builder" GIT_EMAIL="builder@company.com" $0

Required environment:
    - Ubuntu 22.04 LTS
    - Minimum 300GB free space
    - Internet connection (for downloading repo tool and source code)
    - Android build environment pre-setup

Reference documentation:
    https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/refs/heads/android-15.0/README.md

EOF
}

# ===== Command Line Arguments Processing =====
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -d|--build-dir)
            BUILD_DIR="$2"
            shift 2
            ;;
        *)
            error "Unknown argument: $1\n$(show_usage)"
            ;;
    esac
done

# Main execution
main "$@"
