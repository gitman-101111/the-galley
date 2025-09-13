# the-galley
GrapheneOS build script/system for Docker

## Quick Start
1. `git clone https://github.com/gitman-101111/the-galley` && `cd the-galley`
2. `docker-compose -f docker-compose.public.yml up -d`
3. `docker logs -f the-galley # To monitor progress...`

## Usage Guide

### Docker Usage (Recommended)

#### Single Build Mode (Default)
Run a one-time build and exit:
```bash
docker-compose up
```

#### Continuous Monitoring Mode
The container can run indefinitely and monitor for new GrapheneOS releases:

**Option 1: Build on every new release**
```bash
# Using the monitoring override file
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

**Option 2: Monthly builds (e.g., on the 2nd release of each month)**
Edit `docker-compose.monitoring.yml` to set:
- `BUILD_MODE=monthly`
- `MONTHLY_RELEASE=2`

Then run:
```bash
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

#### Environment Variables
Key configuration options in `docker-compose.yml`:
- `MONITORING_ENABLED`: Enable continuous monitoring (true/false, default: false)
- `BUILD_MODE`: "on_release" or "monthly" 
- `MONTHLY_RELEASE`: Which release of the month to build (1, 2, 3... default: 1)
- `CHECK_INTERVAL`: How often to check for releases in seconds (default: 3600)

### Standalone Usage (Without Docker)

The build script can also be run directly on a host system without Docker:

#### Prerequisites
- Ubuntu or Debian-based system
- Required packages (see Dockerfile for full list):
  ```bash
  sudo apt-get update && sudo apt-get install -y \
    git-core gnupg flex bison zip curl python3 \
    build-essential openssl jq wget rsync nodejs npm
  ```
- Install repo tool:
  ```bash
  curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
  chmod a+x ~/bin/repo
  ```

#### Running build.sh Directly
```bash
# Set required environment variables
export OS=grapheneos-16
export TGT=tangorpro,caiman
export TAG=16
export GOOGLE_BUILD_ID=BP2A.250805.005
export VERSION=16

# Optional: Set additional variables
export USR=$(id -u)
export GRP=$(id -g)
export CN="YourCertName"
export UPDATE_URL="https://your.update.server/"

# Run with specific steps
./build.sh -s  # Sync repositories
./build.sh -k  # Generate keys
./build.sh -e  # Extract vendor files
./build.sh -c  # Apply customizations
./build.sh -r  # Build ROM

# Or run all steps at once
./build.sh
```

#### Build Options
- `-s`: Sync repositories from GrapheneOS
- `-u`: Build aapt2 tool
- `-e`: Extract vendor files from Google images
- `-c`: Apply customizations and patches
- `-k`: Generate or import signing keys
- `-r`: Build the ROM
- `-f`: Build custom kernel
- `-h`: Show help message

When run without arguments, all steps are executed in sequence.

### Monitoring New Releases
The monitoring feature checks https://github.com/GrapheneOS/platform_manifest/tags for new releases and can automatically trigger builds based on your configuration.
