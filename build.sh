#!/bin/bash
set -eo pipefail # Quit on error and pipe failures
# Note: -u removed for compatibility, but we should validate critical vars
trap 'echo -e "${RED}Error on line $LINENO: Command failed with exit code $?${NC}" >&2' ERR

export WORKDIR=${OS:-}
export BUILD_NUMBER=$(date +%Y%m%d01)
TARGET_RELEASE=$(echo ${GOOGLE_BUILD_ID:-} | tr '[:upper:]' '[:lower:]'| cut -d. -f1)  # Used internally, not exported
export RED='\033[0;31m'
export GREEN='\033[0;33m'
export BLUE='\033[0;36m'
export YELLOW='\033[1;33m'
export NC='\033[0m'

# Helper function for timestamped logging
log_step() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] $*${NC}"
}

# Helper function for error messages
error() {
    echo -e "${RED}ERROR: $*${NC}" >&2
}

# Helper function for warnings
warning() {
    echo -e "${YELLOW}WARNING: $*${NC}"
}

# Helper function for success messages
success() {
    echo -e "${GREEN}$*${NC}"
}

# Helper function for notifications
notify() {
    local message="$1"
    if [[ -n "$APPRISE_URLS" ]]; then
        apprise -t "The Galley" -b "$message" || true
    fi
}

# Cleanup function for build failures
cleanup_on_failure() {
    local target="$1"
    warning "Cleaning up after failed build for $target"
}

echo -e "${NC}
           ===                                ===
            ===                              ===
              ===                            ==
                ==       ============       ==
               ============================
              ==============================
           ====================================
         ========================================
        ============================================
       ==============================================
      =========    ======================    =========
     ==========    ======================    ==========
    ============  ========================  ============
   ======================================================
  ========================================================
  ========================================================
  ========================================================

                           WELCOME
\n\n"

# ============================================================================
# SECTION 1: INITIALIZATION & VALIDATION
# ============================================================================

# Validate required environment variables
log_step "Validating environment..."
missing_vars=()
for var in OS TGT TAG GOOGLE_BUILD_ID VERSION; do
    if [[ -z "${!var:-}" ]]; then
        missing_vars+=("$var")
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo -e "${RED}ERROR: Missing required variables: ${missing_vars[*]}${NC}"
    echo -e "${YELLOW}Please set the following variables:${NC}"
    echo -e "${YELLOW}  OS: Operating system identifier${NC}"
    echo -e "${YELLOW}  TGT: Build target(s), comma-separated${NC}"
    echo -e "${YELLOW}  TAG: Git tag or branch to build${NC}"
    echo -e "${YELLOW}  GOOGLE_BUILD_ID: Google build identifier${NC}"
    echo -e "${YELLOW}  VERSION: Android version number${NC}"
    exit 1
fi


# Set default values for optional variables
export USR=${USR:-$(whoami)}
export GRP=${GRP:-$(id -gn)}
export CN=${CN:-"GrapheneOS"}
export APPRISE_URLS=${APPRISE_URLS:-""}
export DOCKER_MODE=${DOCKER_MODE:-false}

# TGT already validated above, just process it
IFS=', ' read -r -a targets <<< $(echo "$TGT" | tr '[:upper:]' '[:lower:]')
success "Targets: ${targets[*]}"

# Kernel device mappings
declare -A kernel_targets=(
    ["tangorpro"]="tangorpro"
    ["lynx"]="lynx"
    ["cheetah"]="cheetah"
    ["panther"]="panther"
    ["bluejay"]="bluejay"
    ["oriole"]="oriole"
    ["raven"]="raven"
    ["barbet"]="barbet"
    ["coral"]="coral"
    ["flame"]="coral"
    ["sunfish"]="sunfish"
    ["bramble"]="redbull"
    ["redfin"]="redbull"
    ["caiman"]="caimito"
    ["tokay"]="caimito"
    ["komodo"]="ripcurrent"
    ["comet"]="ripcurrent"
)

# Kernel manifest mappings
declare -A kernel_manifest=(
    ["tangorpro"]="6"
    ["lynx"]="6"
    ["cheetah"]="6"
    ["panther"]="6"
    ["bluejay"]="6a"
    ["oriole"]="6a"
    ["raven"]="6a"
    ["barbet"]="5a"
    ["coral"]="coral"
    ["sunfish"]="sunfish"
    ["redbull"]="redbull"
    ["caimito"]="caimito"
    ["ripcurrent"]="ripcurrent"
)

# Magisk preinit device mappings
declare -A preinit_devices=(
    ["tangorpro"]="persist"
    ["lynx"]="persist"
    ["cheetah"]="persist"
    ["panther"]="persist"
    ["bluejay"]="persist"
    ["oriole"]="persist"
    ["raven"]="persist"
    ["barbet"]="sda10"
    ["coral"]="sda5"
    ["flame"]="sda5"
    ["sunfish"]="sda5"
    ["bramble"]="sda10"
    ["redfin"]="sda10"
    ["tangorpro"]="sda5"
    ["caiman"]="sda10"
)

# Parse command line options
OPTSTRING="fuckersh"
while getopts ${OPTSTRING} opt; do
  case ${opt} in
    f)
      KERNEL=true
      ;;
    u)
      AAPT2=true
      ;;
    c)
      CUSTOMIZE=true
      ;;
    k)
      KEYS=true
      ;;
    e)
      EXTRACT=true
      ;;
    r)
      ROM=true
      ;;
    s)
      SYNC=true
      ;;
    h)
      HELP="
        -h: This help message :-)
        [Nothing]: If no arguments are passed, all steps run (default when run in a docker container)! 
        -s: Default: False; Sync the repo with the tag passed
        -u: Default: False; Build aapt2 if not using a prebuilt verison
        -e: Default: False; Extract vendor files from the latest Google OTA/Factory images
        -c: Default: False; Whether or not to apply patches to customize your build
        -k: Default: False; Generate/move keys from "/build_mods/keys/'$target'"
        -r: Default: False; Build the rom!
      "
      echo "$HELP"
      exit 1
      ;;
    ?)
      echo "Invalid option: -${OPTARG}."
      exit 1
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "No args detected, assuming defaults (Docker mode - running all steps)"
  # echo $HELP
  DOCKER_MODE=true  # Flag for strict error handling
  SYNC=true      # Sync repo first
  AAPT2=true     # Build aapt2 (needed for vendor extraction)
  CUSTOMIZE=true # Apply customizations
  KEYS=true      # Generate signing keys
  EXTRACT=true   # Extract vendor files
  ROM=true       # Build the ROM
  KERNEL=false   # Don't build kernel by default
  ROOT_TYPE="magisk"
fi

# https://github.com/cawilliamson/rooted-graphene
function repo_sync_until_success() {
  local max_attempts=5
  local attempt=0
  
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))
    echo -e "${BLUE}Sync attempt $attempt of $max_attempts${NC}"
    
    # Try to sync with reduced parallel jobs to avoid rate limiting
    # if repo sync -c -j4 --fail-fast --no-clone-bundle --no-tags --force-sync; then
    if repo sync -c -j4 --force-sync; then
      echo -e "${GREEN}Repo sync successful!${NC}"
      return 0
    fi
    
    if [ $attempt -lt $max_attempts ]; then
      echo -e "${YELLOW}Sync failed, waiting 60 seconds before retry...${NC}"
      sleep 60
    fi
  done
  
  echo -e "${RED}Repo sync failed after $max_attempts attempts${NC}"
  notify "Repo sync failed after $max_attempts attempts"
  return 1
}

# Function to download AVBRoot
function download_avbroot() {
  if [[ -f /build_mods/avbroot/avbroot ]]; then
    echo -e "${GREEN}avbroot exists${NC}"
    return 0
  fi
  
  if [[ ! -e /build_mods/avbroot ]]; then
    mkdir /build_mods/avbroot
  fi
  
  echo -e "${BLUE}Grabbing latest avbroot module ${NC}"
  for attempt in 1 2 3; do
    if export avblatestver=$(curl --retry 3 --retry-delay 5 https://api.github.com/repos/chenxiaolong/avbroot/releases/latest -s | jq .name -r | sed 's/Version//g'); then
      export avblink="https://github.com/chenxiaolong/avbroot/releases/latest/download/avbroot-${avblatestver}-x86_64-unknown-linux-gnu.zip"
      if wget --tries=3 --timeout=30 "$avblink" -O /build_mods/avbroot/avbroot.zip; then
        unzip -o /build_mods/avbroot/avbroot.zip -d /build_mods/avbroot/
        chmod +x /build_mods/avbroot/avbroot
        echo -e "${GREEN}avbroot downloaded successfully${NC}"
        return 0
      fi
    fi
    echo -e "${YELLOW}Download attempt $attempt failed, retrying...${NC}"
    sleep 10
  done
  
  echo -e "${RED}Failed to download avbroot after 3 attempts${NC}"
  return 1
}

# Function to check build environment
function check_build_environment() {
  if [[ ! -f "/src/$WORKDIR/build/envsetup.sh" ]]; then
    error "Build environment not found."
    if [[ "$SYNC" != "true" ]]; then
      echo -e "${RED}Please run with -s flag to sync first, or run without arguments for full build${NC}"
      notify "Build environment not found - sync required"
      exit 1
    else
      echo -e "${RED}SYNC should have run but build directory is missing. Check sync logs.${NC}"
      notify "Build environment missing after sync - check logs"
      exit 1
    fi
  fi
}

# Function to apply patches
function apply_patch() {
  local patch_name="$1"
  local target_dir="$2"
  local patch_file="$3"
  
  echo -e "${BLUE}Applying $patch_name patch${NC}"
  if git apply --directory="$target_dir" --unsafe-paths "$patch_file"; then
    echo -e "${GREEN}$patch_name patch applied successfully${NC}"
    return 0
  else
    echo -e "${RED}$patch_name patch failed${NC}"
    notify "$patch_name patch failed!"
    exit 1
  fi
}

# Set git opts
git config --global user.email "user@domain.com"
git config --global user.name "user"
git config --global color.ui true

# Setup our dirs
if [[ -e /src/$WORKDIR ]]; then
    echo -e "${GREEN}/src/$WORKDIR exists, skipping creation ${NC}"
    if [[ "$OFFICIAL_BUILD" == true ]]; then
        if [ "$AAPT2" == true ] && [ "$ROM" == true ]; then
          echo -e "${YELLOW}Official build detected, cleaning /src/$WORKDIR/$OUT_DIR ${NC}"
          rm -rf /src/$WORKDIR/$OUT_DIR
          mkdir /src/$WORKDIR/$OUT_DIR
        fi
    fi
else
    echo -e "${YELLOW}/src/$WORKDIR/ not found, creating ${NC}"
    mkdir /src/$WORKDIR
    sudo chown -R $USR:$GRP /src/$WORKDIR
fi
cd /src/$WORKDIR

# Set perms
echo -e "${GREEN}Setting permissions...${NC}"
sudo chown -R $USR:$GRP /src
sudo chown -R $USR:$GRP /build_mods

# ============================================================================
# SECTION 2: SOURCE MANAGEMENT (SYNC & EXTRACT)
# ============================================================================

# Branch type will be determined when repo init is needed
if [[ "$SYNC" == true ]]; then
  log_step "Starting repository sync"
  cd /src/$WORKDIR
  
  # Option to start completely fresh if CLEAN_SYNC is set
  if [[ "${CLEAN_SYNC:-false}" == "true" ]]; then
    echo -e "${YELLOW}CLEAN_SYNC requested - removing entire work directory${NC}"
    cd /src
    rm -rf "$WORKDIR/.repo"
    find "$WORKDIR" -maxdepth 1 -type d ! -name "$WORKDIR" ! -name "keys" ! -name "releases" -exec rm -rf {} + 2>/dev/null || true
    find "$WORKDIR" -maxdepth 1 -type f -delete 2>/dev/null || true
    echo -e "${GREEN}Work directory cleaned${NC}"
  else
    # Undo patches before sync if repo exists
    echo -e "${BLUE}Undoing patches prior to sync${NC}"
    if [[ -d "/src/$WORKDIR/.repo/repo" ]]; then
      cd /src/$WORKDIR/.repo/repo && git reset --hard && git clean -ffdx || true
    fi
    cd /src/$WORKDIR
    if [[ -d ".repo" ]] && command -v repo &> /dev/null; then
      repo forall -vc "git reset --hard" || true
      repo forall -vc "git clean -ffdx" || true
    fi
  fi
  
  cd /src/$WORKDIR
  # Figure out what we're doing
  if [[ "$TAG" =~ ^[0-9]{10}$ ]]; then
      echo -e "${GREEN}Release branch tag detected! ${NC}"
      repo init -u https://github.com/GrapheneOS/platform_manifest.git -b $TAG

      # Verify
      curl https://grapheneos.org/allowed_signers > /tmp/grapheneos_allowed_signers
      cd .repo/manifests || exit 1
      git config gpg.ssh.allowedSignersFile /tmp/grapheneos_allowed_signers
      git verify-tag $(git describe)
      cd /src/$WORKDIR || exit 1
  else
      echo -e "${GREEN}Dev branch tag detected! ${NC}"
      repo init -u https://github.com/GrapheneOS/platform_manifest.git -b $TAG
  fi

  # Sync it!
  echo -e "${BLUE}Syncing repo... ${NC}"
  repo_sync_until_success
  notify "Repo sync completed!"
fi

# Install adevtool dependencies if needed (after sync, before extract)
if [[ "$EXTRACT" == true ]] || [[ "$AAPT2" == true ]]; then
  if [[ -d "/src/$WORKDIR/vendor/adevtool" ]]; then
    log_step "Installing adevtool dependencies"
    cd /src/$WORKDIR
    echo -e "${GREEN}Installing adevtool dependencies${NC}"
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 && yarn install --cwd /src/$WORKDIR/vendor/adevtool/
  else
    if [[ "$SYNC" != "true" ]]; then
      echo -e "${YELLOW}adevtool directory not found. Run with -s flag to sync first${NC}"
    fi
  fi
fi

# Build AAPT2 before vendor extraction (needed for arsclib)
if [[ "$AAPT2" == true ]]; then
  log_step "Building aapt2"
  
  # Check if build directory exists before sourcing
  check_build_environment
  
  cd /src/$WORKDIR
  source /src/$WORKDIR/build/envsetup.sh
  echo -e "${GREEN}Compiling aapt2 ${NC}"
  lunch sdk_phone64_x86_64-cur-user
  if ! m arsclib 2>&1; then
      echo -e "${RED}aapt2 compile failed!${NC}"
      notify "aapt2 build failed!"
      exit 1
  else
      echo -e "${GREEN}aapt2 compiled successfully! ${NC}"
      notify "aapt2 build completed successfully!"
  fi
fi

# Extract vendor files (needs source code from sync, adevtool installed, and arsclib built)
if [[ "$EXTRACT" == true ]]; then
  log_step "Extracting vendor files"
  cd /src/$WORKDIR
  
  # Check if adevtool is available
  if [[ ! -d "vendor/adevtool" ]]; then
    error "adevtool not found. Please run with -s flag to sync first"
    notify "Vendor extraction failed - adevtool not found"
    exit 1
  fi
  
  for target in "${targets[@]}"
  do
    # Extract vendor files
    echo -e "${GREEN}Downloading and extracting vendor files for $target ${NC}"
    cd /src/$WORKDIR
    if ! vendor/adevtool/bin/run generate-all -d $target; then
        echo -e "${RED}Failed to extract vendor files for $target${NC}"
        notify "Vendor extraction failed for $target"
        exit 1
    fi
  done
  notify "Vendor files extracted for all targets"
fi

# ============================================================================
# SECTION 3: CUSTOMIZATION & KEYS
# ============================================================================

if [[ "$CUSTOMIZE" == true ]]; then
  ## PRE-BUILD MODS (ALL TARGETS) ##
  log_step "Applying customizations"
  notify "Applying pre-build mods"
  cd /src/$WORKDIR

  # Custom hosts for some OOTB adblocking
  echo -e "${BLUE}Modifying hosts file ${NC}"
  hosts_downloaded=false
  for attempt in 1 2 3; do
    if curl --retry 3 --retry-delay 5 -f https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts -o system/core/rootdir/etc/hosts; then
      echo -e "${GREEN}Hosts file downloaded successfully${NC}"
      hosts_downloaded=true
      break
    fi
    echo -e "${YELLOW}Download attempt $attempt failed, retrying...${NC}"
    sleep 5
  done
  
  if [[ "$hosts_downloaded" == false ]]; then
    if [[ "$DOCKER_MODE" == "true" ]]; then
      echo -e "${RED}Failed to download hosts file after 3 attempts${NC}"
      exit 1
    else
      echo -e "${YELLOW}Warning: Failed to download hosts file after 3 attempts, continuing...${NC}"
    fi
  fi
  
  # Copy over additional prebuilts
  # export gmscore=$(echo -e "$(curl https://api.github.com/repos/microg/GmsCore/releases/latest -s | jq .name -r)")    
  # apksigner sign --key /build_mods/fs-verity/key.pk8 --cert /build_mods/fs-verity/cert.pem GmsCore.apk
  # echo -e "${BLUE}Injecting GmsCore ${NC}"
  # cp -r /build_mods/external/GmsCore /src/$WORKDIR/external/
  # md5sum /src/$WORKDIR/external/GmsCore/GmsCore.apk

  # Copy custom boot animation
  echo -e "${BLUE}Replacing bootanimation ${NC}"
  if [[ -f /build_mods/bootanimation.zip ]]; then
    cp /build_mods/bootanimation.zip frameworks/base/data/
  else
    echo -e "${YELLOW}Warning: bootanimation.zip not found${NC}"
  fi

  # Copy custom notification sound (and set perms)
  echo -e "${BLUE}Copying custom notification sounds and setting permissions ${NC}"
  if [[ -f /build_mods/fasten_seatbelt.ogg ]]; then
    cp /build_mods/fasten_seatbelt.ogg frameworks/base/data/sounds/notifications/
    chmod 644 frameworks/base/data/sounds/notifications/fasten_seatbelt.ogg
  else
    echo -e "${YELLOW}Warning: fasten_seatbelt.ogg not found${NC}"
  fi
  # patching will be handled by frameworks-base-patches-14.patch

  # Apply patches
  apply_patch "frameworks/base" "/src/$WORKDIR/frameworks/base" "/build_mods/patches/$VERSION/frameworks-base-patches-$VERSION.patch"
  apply_patch "build/make" "/src/$WORKDIR/build/make" "/build_mods/patches/$VERSION/build-make-patches-$VERSION.patch"

  # Setup updates
  cat << EOF > packages/apps/Updater/res/values/config.xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
<string name="url" translatable="false">$UPDATE_URL</string>
<string name="channel_default" translatable="false">stable</string>
<string name="network_type_default" translatable="false">1</string>
<string name="battery_not_low_default" translatable="false">true</string>
<string name="requires_charging_default" translatable="false">false</string>
<string name="idle_reboot_default" translatable="false">false</string>
</resources>
EOF

  notify "Pre-build mods applied!"
fi

if [[ "$KEYS" == true ]]; then
  log_step "Managing signing keys"
  cd /src/$WORKDIR
  
  for target in "${targets[@]}"
  do
      if [[ -e /build_mods/keys/$target ]]; then
          if [[ -e /src/$WORKDIR/keys/$target ]]; then
              echo -e "${RED}Key directory exists for $target, not recreating or replacing! ${NC}"
          else
              echo -e "${BLUE}Copying keys for $target from build_mods ${NC}"
              mkdir -p /src/$WORKDIR/keys/$target
              cp -R /build_mods/keys/$target /src/$WORKDIR/keys/ 
          fi
      fi
      # Generate keys & sign & encrypt
      if [[ -e /src/$WORKDIR/keys/$target ]]; then
        if [[ $(ls /src/$WORKDIR/keys/$target/*.pk8 2>/dev/null | wc -l) -ge 7 ]]; then
            echo -e "${GREEN}Keys for $target exist, skipping recreation ${NC}"
        fi
        if [[ -e /src/$WORKDIR/keys/$target/avb.pem ]]; then
            echo -e "${GREEN}AVB key exists for $target ${NC}"
        else
            if [[ -z "$CERTPASS" ]]; then
                openssl genrsa 4096 | openssl pkcs8 -topk8 -scrypt -out /src/$WORKDIR/keys/$target/avb.pem -passout pass:""
            else
                openssl genrsa 4096 | openssl pkcs8 -topk8 -scrypt -out /src/$WORKDIR/keys/$target/avb.pem -passout pass:"$CERTPASS"
            fi
        fi
        if [[ -e /src/$WORKDIR/keys/$target/avb_pkmd.bin ]]; then
            echo -e "${GREEN}Public key exists for $target ${NC}"
        else
            if [[ -z "$CERTPASS" ]]; then
            /src/$WORKDIR/external/avb/avbtool.py extract_public_key --key /src/$WORKDIR/keys/$target/avb.pem --output /src/$WORKDIR/keys/$target/avb_pkmd.bin
            else
            /src/$WORKDIR/external/avb/avbtool.py extract_public_key --key /src/$WORKDIR/keys/$target/avb.pem --output /src/$WORKDIR/keys/$target/avb_pkmd.bin --passphrase_file <(echo -n "$CERTPASS")
            fi
        fi
      else
        echo -e "${BLUE}Generating $target keys ${NC}"
        mkdir -p /src/$WORKDIR/keys/$target
        cd /src/$WORKDIR/keys/$target
        /src/$WORKDIR/development/tools/make_key releasekey '/CN=$CN/'
        /src/$WORKDIR/development/tools/make_key platform '/CN=$CN/'
        /src/$WORKDIR/development/tools/make_key shared '/CN=$CN/'
        /src/$WORKDIR/development/tools/make_key media '/CN=$CN/'
        /src/$WORKDIR/development/tools/make_key verity '/CN=$CN/'
        /src/$WORKDIR/development/tools/make_key networkstack '/CN=$CN/'
        /src/$WORKDIR/development/tools/make_key bluetooth '/CN=$CN/'
        /src/$WORKDIR/development/tools/make_key sdk_sandbox '/CN=$CN/'
        cd /src/$WORKDIR
        openssl genrsa 4096 | openssl pkcs8 -topk8 -scrypt -out /src/$WORKDIR/keys/$target/avb.pem
        /src/$WORKDIR/external/avb/avbtool.py extract_public_key --key /src/$WORKDIR/keys/$target/avb.pem --output /src/$WORKDIR/keys/$target/avb_pkmd.bin
        cd /src/$WORKDIR/keys/$target
        # Encrypt and re-sign the keys
        if [[ -z "$CERTPASS" ]]; then
          echo -e "${RED}Your keys are NOT encrypted! Set CERTPASS to encrypt! ${NC}"
          export password="$CERTPASS"
        else
          echo -e "${GREEN}Encrypting your keys... ${NC}"
          /src/$WORKDIR/script/encrypt-keys /src/$WORKDIR/keys/$target
        fi
        cp -R /src/$WORKDIR/keys/$target /build_mods/keys/
      fi
      if [[ "$ROOT_TYPE" == "magisk" ]]; then
          # Download AVBRoot if needed
          download_avbroot
          # cp /src/$WORKDIR/keys/$target/avb_python.key /src/$WORKDIR/keys/$target/ota_python.key
          cp /src/$WORKDIR/keys/$target/avb.pem /src/$WORKDIR/keys/$target/avb.key
          cp /src/$WORKDIR/keys/$target/avb.key /src/$WORKDIR/keys/$target/ota.key
          /build_mods/avbroot/avbroot key extract-avb -k /src/$WORKDIR/keys/$target/avb.key --output /src/$WORKDIR/keys/$target/avb_pkmd.bin
          if [[ -z "$CERTPASS" ]]; then
              openssl req -new -x509 -sha256 -key /src/$WORKDIR/keys/$target/ota.key -out /src/$WORKDIR/keys/$target/ota.crt -days 10000 -subj /CN=$CN/
          else
              openssl req -new -x509 -sha256 -key /src/$WORKDIR/keys/$target/ota.key -out /src/$WORKDIR/keys/$target/ota.crt -days 10000 -subj /CN=$CN/ -passin pass:"$CERTPASS"
          fi
          cp /src/$WORKDIR/keys/$target/avb.key /build_mods/keys/$target/
      fi
  done

  ## ADD FS-VERITY KEYS ##
  # Ensure destination directory exists
  mkdir -p /src/$WORKDIR/build/make/target/product/security/
  
  if [[ -e /build_mods/fs-verity/fsverity_cert.0.der ]]; then
      echo -e "${BLUE}fs-verity keys exist, not recreating ${NC}"
      cp /build_mods/fs-verity/fsverity_cert.0.der /src/$WORKDIR/build/make/target/product/security/
  else
      mkdir -p /build_mods/fs-verity
      cd /build_mods/fs-verity || exit 1
      # Create PKCS#8 key (can be password-protected)
      openssl genpkey -algorithm rsa -pkeyopt rsa_keygen_bits:4096 -out fsverity.key
      # PKCS#8 is used by the Android fsverity library
      openssl pkcs8 -topk8 -in fsverity.key -out fsverity_private_key.0.pk8 -nocrypt
      # Create the certificate (DER format for Android)
      openssl req -new -x509 -sha256 -key fsverity_private_key.0.pk8 -out fsverity_cert.0.der -days 10000 -outform DER -subj "/CN=$CN/"
      cp /build_mods/fs-verity/fsverity_cert.0.der /src/$WORKDIR/build/make/target/product/security/
      # Convert for use with the host-side "fsverity" tool (optional)
      # openssl x509 -in fsverity_cert.0.der -inform DER -out cert.pem -outform PEM
      # openssl rsa -in fsverity.key -out key.pem
  fi
  
  notify "Keys managed successfully"
fi

# ============================================================================
# SECTION 4: BUILD TOOLS PREPARATION
# ============================================================================

# Download Magisk and AVBRoot if needed for ROM build
if [[ "$ROOT_TYPE" == "magisk" ]]; then
    log_step "Downloading root tools"
    
    # Download AVBRoot (will be used in KEYS and/or ROM sections)
    download_avbroot
    
    # Magisk
    echo -e "${BLUE}Grabbing latest Magisk zip ${NC}"
    for attempt in 1 2 3; do
        if export magiskapk=$(curl --retry 3 --retry-delay 5 https://api.github.com/repos/topjohnwu/Magisk/releases/latest -s | jq .name -r 2>/dev/null | sed 's/ /-/g'); then
            if [ -n "$magiskapk" ] && wget --tries=3 --timeout=30 "https://github.com/topjohnwu/Magisk/releases/latest/download/${magiskapk}.apk" -O /build_mods/avbroot/Magisk.apk; then
                echo -e "${GREEN}Magisk downloaded successfully${NC}"
                break
            fi
        fi
        echo -e "${YELLOW}Download attempt $attempt failed, retrying...${NC}"
        sleep 10
    done
fi

# ============================================================================
# SECTION 5: BUILD (KERNEL & ROM)
# ============================================================================

# Build Kernel
if [ "$KERNEL" == true ] || [ "$ROOT_TYPE" == "kernelsu" ]; then
  log_step "Building kernel"
  if [[ -e /src/kernel ]]; then
    echo -e "${YELLOW}Cleaning /src/kernel/*${NC}"
    rm -rf /src/kernel/*
  fi
  for target in "${targets[@]}"
  do
    KTGT="${kernel_targets[$target]}"
    if [[ -z "$KTGT" ]]; then
      warning "No kernel configuration for $target, skipping kernel build"
      continue
    fi
    
    MTGT="${kernel_manifest[$KTGT]}"
    if [ "$KTGT" == "caimito" ]; then
      BRANCH="$VERSION-$KTGT"
    else
      BRANCH="$VERSION"
    fi
    KVER="6.1"
    if [[ ! -e /src/kernel/$KTGT ]]; then
      mkdir -p /src/kernel/$KTGT
    fi
    cd /src/kernel/$KTGT
    repo init -u https://github.com/GrapheneOS/kernel_manifest-$MTGT.git -b $BRANCH
    repo_sync_until_success
    # repo init -u https://github.com/GrapheneOS/kernel_manifest-shusky.git -b "refs/tags/$T" --depth=1 --git-lfs
    # MOD IT
    if [[ "$ROOT_TYPE" == "kernelsu" ]]; then
      # Root via KernelSU
      cd /src/kernel/$KTGT/aosp || exit 1
      curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
      cd /src/kernel/$KTGT || exit 1
    fi
    LTO=thin BUILD_CONFIG=aosp/build.config.$KTGT build/build.sh -j$(nproc)
    # Copy it over
    if [[ "$KTGT" == "barbet" ]]; then
      cd /src/$WORKDIR
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/boot.img /src/$WORKDIR/device/google/barbet-kernel/ || { error "Failed to copy kernel for barbet"; exit 1; }
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/vendor_boot.img /src/$WORKDIR/device/google/barbet-kernel/
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/vendor_dlkm.img /src/$WORKDIR/device/google/barbet-kernel/
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/dtbo.img /src/$WORKDIR/device/google/barbet-kernel/
    elif [[ "$KTGT" == "coral" ]]; then
      cd /src/$WORKDIR
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/boot.img /src/$WORKDIR/device/google/coral-kernel/ || { error "Failed to copy kernel for coral"; exit 1; }
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/dtbo-coral.img /src/$WORKDIR/device/google/coral-kernel/dtbo.img
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/vendor_boot.img /src/$WORKDIR/device/google/coral-kernel/
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/vendor_dlkm.img /src/$WORKDIR/device/google/coral-kernel/
    elif [[ "$KTGT" == "sunfish" ]]; then
      cd /src/$WORKDIR
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/boot.img /src/$WORKDIR/device/google/sunfish-kernel/ || { error "Failed to copy kernel for sunfish"; exit 1; }
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/dtbo.img /src/$WORKDIR/device/google/sunfish-kernel/
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/vendor_boot.img /src/$WORKDIR/device/google/sunfish-kernel/
      cp -f /src/kernel/$KTGT/out/$BRANCH/$MTGT/dist/vendor_dlkm.img /src/$WORKDIR/device/google/sunfish-kernel/
    else
      cd /src/$WORKDIR
    fi
    cd /src/$WORKDIR
  done
  notify "Kernel build completed"
fi

# Build ROM
if [ "$ROM" == true ]; then
  log_step "Building ROM"
  
  # Check disk space before building
  available_space=$(df /src | awk 'NR==2 {print int($4/1048576)}')
  recommended_space=200  # GB recommended for build
  
  if [ "$available_space" -lt "$recommended_space" ]; then
    warning "Low disk space. Available: ${available_space}GB, Recommended: ${recommended_space}GB"
    if [[ "$DOCKER_MODE" == "true" ]]; then
      exit 1
    fi
    # In non-Docker mode, allow override
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
  else
    echo -e "${GREEN}Disk space check: ${available_space}GB available${NC}"
  fi

  for target in "${targets[@]}"
  do
    notify "Building for $target at $(date)"

    # Build it
    check_build_environment
    source /src/$WORKDIR/build/envsetup.sh
    cd /src/$WORKDIR
    lunch $target-$TARGET_RELEASE-user
    
    log_step "Starting build for $target"
    BUILD_START=$(date +%s)
    
    if ! m vendorbootimage vendorkernelbootimage target-files-package 2>&1; then
        BUILD_END=$(date +%s)
        BUILD_TIME=$((BUILD_END - BUILD_START))
        echo -e "${RED}Build failed for $target after $((BUILD_TIME/60)) minutes!${NC}"
        cleanup_on_failure "$target"
        notify "Build failed for $target after $((BUILD_TIME/60)) minutes!"
        exit 2
    else
        BUILD_END=$(date +%s)
        BUILD_TIME=$((BUILD_END - BUILD_START))
        echo -e "${GREEN}Build for $target completed successfully in $((BUILD_TIME/60)) minutes!${NC}"
        notify "Build for $target completed successfully in $((BUILD_TIME/60)) minutes!"
    fi

    # Generate OTA stuff
    echo -e "${BLUE}Building OTA tools for $target${NC}"
    if ! m otatools-package 2>&1; then
        echo -e "${RED}OTA Tools failed for $target!${NC}"
        notify "OTA Tools failed for $target!"
        exit 2
    else
        echo -e "${GREEN}OTA Tools for $target packaged successfully!${NC}"
        notify "OTA Tools for $target packaged successfully!"
    fi

    # Debug: Show current directory and check for script
    echo -e "${BLUE}Current directory: $(pwd)${NC}"
    echo -e "${BLUE}Checking for script/finalize.sh...${NC}"
    ls -la script/finalize.sh 2>&1 || echo -e "${YELLOW}ls failed${NC}"
    
    # Sign and package...
    if [[ -f script/finalize.sh ]]; then
        # Set password environment variable for any key operations in finalize.sh (empty if no CERTPASS)
        export password="${CERTPASS:-}"
        if ! script/finalize.sh; then
            unset password
            echo -e "${RED}finalize.sh failed for $target!${NC}"
            notify "finalize.sh failed for $target!"
            exit 1
        fi
        unset password
    else
        echo -e "${RED}finalize.sh not found!${NC}"
        notify "finalize.sh not found for $target!"
        exit 1
    fi
    # generate-release.sh doesn't handle passwords directly - it uses decrypt-keys internally
    # Set the password environment variable for decrypt-keys (empty if no CERTPASS)
    export password="${CERTPASS:-}"
    if ! script/generate-release.sh $target $BUILD_NUMBER; then
        unset password
        echo -e "${RED}generate-release.sh failed for $target!${NC}"
        notify "Release generation failed for $target!"
        exit 1
    fi
    unset password
    notify "Release signed and packaged for $target!"

    if [[ "$ROOT_TYPE" == "magisk" ]]; then
      preinit="${preinit_devices[$target]}"
      if [[ -z "$preinit" ]]; then
          warning "No preinit device configured for $target, skipping Magisk patching"
          continue
      fi
      log_step "Using preinit device $preinit for $target"

      # Ensure we're in a good place to gen up (pre-rooted) incremental updates in the future
      # Actually patch the ota
      # Use CERTPASS for both AVB and OTA operations
      export PASSPHRASE_AVB="$CERTPASS"
      export PASSPHRASE_OTA="$CERTPASS"
      /build_mods/avbroot/avbroot patch --input /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/$target-ota_update-*.zip --privkey-avb /src/$WORKDIR/keys/$target/avb.key --privkey-ota /src/$WORKDIR/keys/$target/ota.key --pass-avb-env-var PASSPHRASE_AVB --pass-ota-env-var PASSPHRASE_OTA --cert-ota /src/$WORKDIR/keys/$target/ota.crt --magisk /build_mods/avbroot/Magisk.apk --magisk-preinit-device $preinit --ignore-magisk-warnings
      unset PASSPHRASE_AVB PASSPHRASE_OTA
      # Setup a temp directory ("./root")
      mkdir -p /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/root
      # Extract to the temp directory & enter
      /build_mods/avbroot/avbroot ota extract --input /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/$target-ota_update-*.zip.patched --directory /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/root/
      cd /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/ || exit 1
      # Extract the factory zip into "./factory"
      unzip -j $target-factory-*.zip -d factory
      # Inject the patched images into the images zip
      zip factory/image-$target-*.zip -j root/*
      # Keys are identical, md5s match last I checked
      # zip /src/$WORKDIR/keys/$target/avb_pkmd.bin $target-factory-*/image-$target-*.zip
      # Update the factory zip with the patched image zip (not zip into itself)
      cd factory
      zip -u ../$target-factory-*.zip image-$target-*.zip
      cd ..
      # Remove the temp directory
      rm -rf root/
      # Append ".unpatched" to the untouched ota zip
      mv /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/$target-ota_update-$BUILD_NUMBER.zip /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/$target-ota_update-$BUILD_NUMBER.zip.unpatched
      # Append ".patched" to the patched ota zip
      mv /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/$target-ota_update-$BUILD_NUMBER.zip.patched /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/$target-ota_update-$BUILD_NUMBER.zip
      cd /src/$WORKDIR/
    fi

    # Fin
    echo -e "${GREEN}Built releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER ${NC}"

    # PUSH TO UPDATE SERVER
    if [[ "$PUSH" == true ]]; then

      # Create list of files to be pushed to the update server
      if [[ ! -f /src/$WORKDIR/releases/filesToPushToUpdateServer.txt ]]; then
        touch /src/$WORKDIR/releases/filesToPushToUpdateServer.txt
      fi

      # Add targets to the list
      if grep -q "$target" "/src/$WORKDIR/releases/filesToPushToUpdateServer.txt" 2>/dev/null; then
        echo -e "${YELLOW}$target found, skipping${NC}"
      else
        echo -e "$target-ota_update-$BUILD_NUMBER.zip\n$target-factory-$BUILD_NUMBER.zip\n$target-factory-$BUILD_NUMBER.zip.sig\n$target-testing\n$target-beta\n$target-stable\n" >> /src/$WORKDIR/releases/filesToPushToUpdateServer.txt
      fi

      # RSYNC
      # rsync
    fi

    if [[ -e /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/$target-factory-$BUILD_NUMBER.zip ]]; then
      notify "Factory image ready for $target at $(date)"
    fi
  done
  
  # set -u  # Would re-enable strict mode, but kept disabled for compatibility
  
  # Final summary
  echo -e "${GREEN}=== BUILD SUMMARY ===${NC}"
  log_step "Build completed for all targets"
  for target in "${targets[@]}"; do
    if [[ -e /src/$WORKDIR/releases/$BUILD_NUMBER/release-$target-$BUILD_NUMBER/$target-factory-$BUILD_NUMBER.zip ]]; then
      echo -e "${GREEN}✓ $target: Factory image ready${NC}"
    else
      echo -e "${RED}✗ $target: Build may have failed${NC}"
    fi
  done
  echo -e "${GREEN}===================${NC}"
fi
