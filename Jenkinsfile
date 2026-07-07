// SPDX-FileCopyrightText: (C) 2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

// Dynamic parameters: ICT_IMG only applies when BUILD_MODE=ict-based.
// Requires "Active Choices" plugin (uno-choice) for full dynamic visibility.
// Without the plugin, all parameters are shown but ICT-only ones are ignored in script-based mode.

properties([
    parameters([
        choice(
            name: 'BUILD_MODE',
            choices: ['script-based', 'ict-based', 'reuse-image'],
            description: 'script-based: build from Ubuntu ISO; ict-based: build with Image Composer Tool; reuse-image: skip image creation, package artifacts only'
        ),
        string(
            name: 'ISO_URL',
            defaultValue: 'https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso',
            description: '(script-based only) Ubuntu ISO URL to build from.'
        ),
        string(
            name: 'ICT_IMG',
            defaultValue: '',
            description: '(ict-based only) Absolute path to pre-built ICT image (.raw.gz/.raw.img.gz). Leave empty to build from source.'
        ),
        string(
            name: 'BUILD_BRANCH',
            defaultValue: 'main',
            description: 'Branch or tag to build from. The workspace will be switched to this branch before building.'
        ),
        booleanParam(
            name: 'SKIP_BUILD_REUSE_CACHE',
            defaultValue: false,
            description: 'Skip image build entirely and reuse cached artifacts from the last successful build (/tmp/enib-build-cache/).'
        ),
        booleanParam(
            name: 'RUN_VEN_DEPLOYMENT',
            defaultValue: true,
            description: 'Run Virtual Edge Node (VEN) deployment and validation after image build.'
        ),
        booleanParam(
            name: 'SKIP_VEN_INSTALL_REUSE_DISK',
            defaultValue: false,
            description: 'Skip VEN installation and reuse an existing ubuntu-disk.img from a prior run. Jumps directly to VEN Boot & Test.'
        )
    ])
])

pipeline {
    agent { label 'fed-node' }

    options {
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
    }

    environment {
        PATH = "/usr/local/go/bin:${env.PATH}"
        // Resolve BUILD_BRANCH early so it's available as an env var in all shell steps.
        // Fallback handles first run after parameter rename (when params.BUILD_BRANCH is null).
        BUILD_BRANCH = "${params.BUILD_BRANCH?.trim() ?: 'main'}"
    }

    stages {
        stage('Parameter Validation') {
            steps {
                script {
                    if (params.BUILD_MODE == 'script-based') {
                        if (!params.ISO_URL?.trim()) {
                            error "ISO_URL is required for script-based mode."
                        }
                        echo "Mode: script-based | ISO: ${params.ISO_URL}"
                    } else if (params.BUILD_MODE == 'reuse-image') {
                        echo "Mode: reuse-image | Skipping image build, reusing previous artifacts."
                    } else {
                        if (params.ICT_IMG?.trim()) {
                            echo "Mode: ict-based | ICT image: ${params.ICT_IMG}"
                        } else {
                            echo "Mode: ict-based | No ICT image provided; will build from source using Image Composer Tool."
                        }
                    }
                }
            }
        }

        stage('Checkout') {
            steps {
                script {
                    def targetBranch = env.BUILD_BRANCH
                    def repoUrl = 'https://github.com/open-edge-platform/edge-node-infrastructure-blueprint.git'

                    echo "Checking out: ${repoUrl} @ ${targetBranch}"

                    checkout([
                        $class: 'GitSCM',
                        branches: [[name: "refs/heads/${targetBranch}"]],
                        userRemoteConfigs: [[url: repoUrl]],
                        extensions: [
                            [$class: 'CloneOption', shallow: true, depth: 1, noTags: false, timeout: 30],
                            [$class: 'CleanBeforeCheckout']
                        ]
                    ])

                    def actualCommit = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    echo "Checked out: ${targetBranch} (${actualCommit})"
                    currentBuild.description = "${params.BUILD_MODE} | ${targetBranch} (${actualCommit})"
                }
            }
        }

        stage('Preflight') {
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                echo "Build mode: ${BUILD_MODE}"
                echo "Build branch: ${BUILD_BRANCH}"
                echo "Workspace: ${WORKSPACE}"
                echo "Git commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')"
                [ -f VERSION ] && echo "Version: $(cat VERSION)" || true

                # Verify non-interactive sudo with env preservation
                if ! sudo -n true 2>/dev/null; then
                    echo "ERROR: Non-interactive sudo not available. Grant NOPASSWD:SETENV for Jenkins user."
                    exit 1
                fi
                if ! sudo -nE true 2>/dev/null; then
                    echo "ERROR: sudo -E not allowed. Add SETENV to sudoers entry."
                    exit 1
                fi

                # Verify Go (needed for CDI generator build)
                if ! command -v go &>/dev/null; then
                    echo "ERROR: Go not found in PATH. PATH=$PATH"
                    exit 1
                fi
                echo "Go: $(go version)"

                # Verify Docker access (required for container-based builds)
                if ! command -v docker &>/dev/null; then
                    echo "ERROR: Docker is not installed."
                    exit 1
                fi
                if ! docker info &>/dev/null; then
                    echo "ERROR: Docker is not accessible. Ensure $(whoami) is in the docker group and re-login."
                    exit 1
                fi
                echo "Docker: $(docker --version)"

                echo "Preflight passed."
                '''
            }
        }

        stage('Restore Cached Build') {
            when {
                expression { params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                CACHE_DIR="/tmp/enib-build-cache"
                echo "=== Restoring cached build artifacts from ${CACHE_DIR} ==="

                if [ ! -f "${CACHE_DIR}/usb-installation-files.tar.gz" ]; then
                    echo "ERROR: No cached build found at ${CACHE_DIR}/"
                    echo "Run a full build first (SKIP_BUILD_REUSE_CACHE=false) to populate the cache."
                    ls -la "$CACHE_DIR" 2>/dev/null || echo "  (directory does not exist)"
                    exit 1
                fi

                # Ensure out/ directory is writable (may be root-owned from prior sudo tar)
                sudo rm -rf infrastructure/build-artifacts/out 2>/dev/null || true
                mkdir -p infrastructure/build-artifacts/out
                cp -v "${CACHE_DIR}"/* infrastructure/build-artifacts/out/
                echo "Cache restored. Contents:"
                ls -lh infrastructure/build-artifacts/out/
                '''
            }
        }

        stage('Build Image (script-based)') {
            when {
                expression { params.BUILD_MODE == 'script-based' && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail
                echo "Running: make build MODE=image-from-iso"
                make build MODE=image-from-iso ISO_URL="${ISO_URL}" ICT_IMG=""
                '''
            }
        }

        stage('Build Artifacts (reuse-image)') {
            when {
                expression { params.BUILD_MODE == 'reuse-image' && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail
                echo "Running: make build MODE=reuse-image (skipping image creation)"
                make build MODE=reuse-image
                '''
            }
        }

        stage('Build ICT Image from Source') {
            when {
                expression { params.BUILD_MODE == 'ict-based' && !params.ICT_IMG?.trim() && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                echo "=== Building ICT Image from Source ==="
                ICT_TEMPLATE="infrastructure/host-os/ict/generic-handheld-os-template.yml"

                # Clone Image Composer Tool
                if [ ! -d ict-tool ]; then
                    git clone --depth 1 --branch 2026.1-Release \
                        https://github.com/open-edge-platform/image-composer-tool.git ict-tool
                fi

                # Install prerequisites
                sudo apt-get update -qq
                sudo apt-get install -y --no-install-recommends systemd-ukify mmdebstrap

                # Build ICT binary
                cd ict-tool
                go build -buildmode=pie -ldflags "-s -w" ./cmd/image-composer-tool
                echo "ICT binary built: $(ls -la image-composer-tool)"

                # Validate template
                TEMPLATE="${WORKSPACE}/${ICT_TEMPLATE}"
                ./image-composer-tool validate "$TEMPLATE"
                echo "Template validation passed."

                # Build the image
                echo "Building ICT image (this may take a while)..."
                sudo -E ./image-composer-tool build "$TEMPLATE"
                echo "ICT image build completed."
                cd ..

                # Find the output image
                ICT_OUTPUT=$(find ict-tool -type f -name "*.raw.gz" -print -o -type f -name "*.raw.img.gz" -print | head -1)
                if [ -z "$ICT_OUTPUT" ]; then
                    echo "ERROR: No ICT image output found."
                    exit 1
                fi

                # Copy to a known location for next stage
                mkdir -p /tmp/ict-shared-output
                cp "$ICT_OUTPUT" /tmp/ict-shared-output/
                echo "ICT image ready: $ICT_OUTPUT"
                '''
            }
        }

        stage('Build Image (ict-based)') {
            when {
                expression { params.BUILD_MODE == 'ict-based' && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                script {
                    def ictPath = params.ICT_IMG?.trim()
                    if (!ictPath) {
                        // Use image built by previous stage
                        ictPath = sh(
                            script: "find /tmp/ict-shared-output -type f -name '*.raw.gz' -print -o -type f -name '*.raw.img.gz' -print | head -1",
                            returnStdout: true
                        ).trim()
                    }
                    if (!ictPath) {
                        error "No ICT image path available."
                    }
                    sh """#!/usr/bin/env bash
                    set -euo pipefail
                    echo "Running: make build MODE=image-from-tool ICT_IMG=${ictPath}"
                    make build MODE=image-from-tool ICT_IMG="${ictPath}" ISO_URL=""
                    """
                }
            }
        }

        stage('Collect Build Artifacts') {
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail
                echo "=== Build Artifacts ==="
                find infrastructure/build-artifacts/out -type f -print 2>/dev/null \
                    | while read f; do
                        size=$(du -h "$f" | cut -f1)
                        echo "  [$size] $f"
                    done || echo "  (none)"

                echo ""
                echo "Artifacts remain on disk at: ${WORKSPACE}/infrastructure/build-artifacts/out/"
                echo "(Large image files are NOT uploaded to Jenkins to avoid 10+ min archive delays)"
                '''
                // Only archive small metadata/logs, NOT multi-GB images
                archiveArtifacts artifacts: 'infrastructure/build-artifacts/out/**/*.log,infrastructure/build-artifacts/out/**/*.txt,infrastructure/build-artifacts/out/**/config-file', allowEmptyArchive: true
            }
        }

        stage('Save Build Cache') {
            when {
                expression { !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                CACHE_DIR="/tmp/enib-build-cache"
                echo "=== Saving build artifacts to cache (${CACHE_DIR}) ==="

                rm -rf "$CACHE_DIR"
                mkdir -p "$CACHE_DIR"

                if [ -d infrastructure/build-artifacts/out ] && [ "$(ls -A infrastructure/build-artifacts/out 2>/dev/null)" ]; then
                    cp infrastructure/build-artifacts/out/* "$CACHE_DIR/" 2>/dev/null || true
                    echo "Cached for next run:"
                    ls -lh "$CACHE_DIR/"
                else
                    echo "No artifacts to cache."
                fi
                '''
            }
        }

        stage('VEN Deployment') {
            when {
                expression { params.RUN_VEN_DEPLOYMENT && !params.SKIP_VEN_INSTALL_REUSE_DISK }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                echo "=== Virtual Edge Node (VEN) Deployment ==="
                cd infrastructure/build-artifacts

                # Clean up leftover QEMU artifacts from prior runs to free disk space
                sudo pkill -f "qemu-system-x86_64.*ubuntu-disk" 2>/dev/null || true
                sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
                sudo rm -f out/ubuntu-disk.img out/usb-disk 2>/dev/null || true
                echo "Disk space at VEN start:"
                df -h / | tail -1

                if [ ! -f out/usb-installation-files.tar.gz ]; then
                    echo "ERROR: usb-installation-files.tar.gz not found in build output."
                    exit 1
                fi

                # Extract installation artifacts
                sudo tar -xzf out/usb-installation-files.tar.gz -C out/
                cd out

                # Inject SSH key and host proxy into config-file for non-interactive VEN deployment.
                # Files are root-owned (from sudo tar). Using simple case/match to avoid
                # awk -v issues inside Groovy triple-quoted strings.

                SSH_PUB=""
                if [ -f ~/.ssh/id_ed25519.pub ]; then
                    SSH_PUB=$(cat ~/.ssh/id_ed25519.pub)
                elif [ -f ~/.ssh/id_rsa.pub ]; then
                    SSH_PUB=$(cat ~/.ssh/id_rsa.pub)
                else
                    echo "WARNING: No SSH public key found. VEN tests requiring SSH will fail."
                fi

                HOST_HP="${http_proxy:-${HTTP_PROXY:-}}"
                HOST_HPS="${https_proxy:-${HTTPS_PROXY:-}}"
                HOST_NP="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1}}"

                while IFS= read -r line; do
                    case "$line" in
                        http_proxy=*)  printf '%s\n' "http_proxy=${HOST_HP}" ;;
                        https_proxy=*) printf '%s\n' "https_proxy=${HOST_HPS}" ;;
                        no_proxy=*)    printf '%s\n' "no_proxy=${HOST_NP}" ;;
                        HTTP_PROXY=*)  printf '%s\n' "HTTP_PROXY=${HOST_HP}" ;;
                        HTTPS_PROXY=*) printf '%s\n' "HTTPS_PROXY=${HOST_HPS}" ;;
                        NO_PROXY=*)    printf '%s\n' "NO_PROXY=${HOST_NP}" ;;
                        ssh_key=*)
                            if [ -n "$SSH_PUB" ]; then
                                printf 'ssh_key="%s"\n' "${SSH_PUB}"
                            else
                                echo "$line"
                            fi
                            ;;
                        *) echo "$line" ;;
                    esac
                done < config-file > /tmp/config-file.tmp
                sudo mv /tmp/config-file.tmp config-file

                echo "Config-file updated:"
                grep -E '^(http_proxy|https_proxy|no_proxy|ssh_key|host_type)' config-file || true

                # Also export ssh_key so sudo -E passes it through the environment
                export ssh_key="${SSH_PUB}"

                # Pre-flight: verify extracted files and dependencies
                echo ""
                echo "=== VEN Pre-flight Checks ==="
                echo "Files in $(pwd):"
                ls -la
                echo ""
                echo "Checking usb-bootable-files.tar.gz contents:"
                tar -tzf usb-bootable-files.tar.gz | head -20 || echo "FAIL: cannot list tar contents"
                echo ""
                echo "Checking python3 + PyYAML:"
                python3 -c "import yaml; print('PyYAML OK')" 2>&1 || echo "FAIL: PyYAML not available"
                echo ""
                echo "Checking gdisk:"
                which sgdisk 2>/dev/null && echo "sgdisk OK" || echo "WARN: sgdisk not found"
                echo "=== End Pre-flight ==="
                echo ""

                # Enable bash tracing inside bootable-usb-prepare.sh for debugging
                sudo sed -i '2i set -x' bootable-usb-prepare.sh

                # Add -no-reboot to QEMU so it exits when the VM does 'reboot -f'
                sudo sed -i 's/-vnc :99/-vnc :99 -no-reboot/' ven-deployment.sh

                # Verify -no-reboot was injected
                echo "QEMU command after patching:"
                grep -A5 'qemu-system-x86_64' ven-deployment.sh | head -15

                # Remove usb-installation-files.tar.gz — no longer needed after extraction
                # This frees ~3.5GB before QEMU creates the 64GB disk images
                sudo rm -f usb-installation-files.tar.gz
                echo "Disk space before VEN launch:"
                df -h / | tail -1

                # ven-deployment.sh runs QEMU in foreground.
                # The installer ends with 'reboot -f' which reboots the VM (doesn't shut it down).
                # We run it in background with a timeout to prevent infinite hangs.
                # Redirect all output to a log file so progress-bar \r sequences don't hide errors.
                VEN_TIMEOUT=2400  # 40 minutes max for installation
                echo "Launching VEN deployment (ven-deployment.sh) in background (timeout: ${VEN_TIMEOUT}s)..."
                sudo -E ./ven-deployment.sh > /tmp/ven-deployment-full.log 2>&1 &
                VEN_PID=$!

                # Monitor with timeout — kill QEMU if it runs too long
                set +e
                ELAPSED=0
                while kill -0 $VEN_PID 2>/dev/null; do
                    if [ $ELAPSED -ge $VEN_TIMEOUT ]; then
                        echo "TIMEOUT: VEN deployment exceeded ${VEN_TIMEOUT}s. Killing QEMU..."
                        sudo pkill -f "qemu-system-x86_64.*ubuntu-disk" 2>/dev/null || true
                        sleep 5
                        sudo kill -9 $VEN_PID 2>/dev/null || true
                        break
                    fi
                    sleep 30
                    ELAPSED=$((ELAPSED + 30))
                    echo "  VEN deployment running... (${ELAPSED}s)"
                done
                wait $VEN_PID 2>/dev/null
                VEN_EXIT=$?
                set -e

                # Show the bootable-usb-prepare log (errors are hidden in this file)
                echo ""
                echo "=== bootable_usb_setup_log.txt ==="
                cat bootable_usb_setup_log.txt 2>/dev/null || echo "(no log file found)"
                echo "=== end log ==="
                echo ""
                echo "=== ven-deployment-full.log (sanitized) ==="
                cat /tmp/ven-deployment-full.log 2>/dev/null | col -b | cat -s || echo "(no full log found)"
                echo "=== end full log ==="
                echo ""

                if [ $VEN_EXIT -ne 0 ]; then
                    echo "ven-deployment.sh exited with code $VEN_EXIT"
                fi

                echo "VEN installation completed."

                # Disconnect NBD from installation phase
                sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true

                # Verify disk was created
                if [ ! -f ubuntu-disk.img ]; then
                    echo "FAIL: ubuntu-disk.img not created by installation."
                    exit 1
                fi
                echo "PASS: ubuntu-disk.img created ($(ls -lh ubuntu-disk.img | awk '{print $5}'))"
                '''
            }
        }

        stage('VEN Boot & Test') {
            when {
                expression { params.RUN_VEN_DEPLOYMENT || params.SKIP_VEN_INSTALL_REUSE_DISK }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                echo "=== Booting Installed VEN for Testing ==="

                # When reusing an existing disk, verify it exists
                DISK_IMG="infrastructure/build-artifacts/out/ubuntu-disk.img"
                if [ ! -f "$DISK_IMG" ]; then
                    # Check build cache as fallback
                    if [ -f "/tmp/enib-build-cache/ubuntu-disk.img" ]; then
                        mkdir -p infrastructure/build-artifacts/out
                        cp /tmp/enib-build-cache/ubuntu-disk.img "$DISK_IMG"
                        echo "Restored ubuntu-disk.img from build cache."
                    else
                        echo "ERROR: ubuntu-disk.img not found. Run VEN Deployment first or provide a cached disk."
                        exit 1
                    fi
                fi

                chmod +x tests/ven-boot-installed.sh tests/ven-validate.sh tests/ven-cleanup.sh

                # Resolve SSH private key — prefer the Jenkins user's key (sudo loses HOME)
                VEN_SSH_KEY=""
                JENKINS_HOME_DIR=$(getent passwd "$(logname 2>/dev/null || echo jenkins)" | cut -d: -f6 2>/dev/null || true)
                for candidate in "${JENKINS_HOME_DIR}/.ssh/id_ed25519" "${JENKINS_HOME_DIR}/.ssh/id_rsa" \
                                 "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa"; do
                    if [ -f "$candidate" ]; then
                        VEN_SSH_KEY="$candidate"
                        break
                    fi
                done
                echo "SSH private key for VEN boot: ${VEN_SSH_KEY:-none found}"

                # Boot the installed VM with SSH port forwarding
                # ubuntu-disk.img is in infrastructure/build-artifacts/out/ (created by ven-deployment.sh)
                sudo tests/ven-boot-installed.sh \
                    infrastructure/build-artifacts/out/ubuntu-disk.img \
                    2222 98 4G 300 "${VEN_SSH_KEY}"

                echo ""
                echo "=== Running VEN Validation Tests ==="
                # Run the test suite (uses SSH to validate the VM)
                tests/ven-validate.sh 2222 user localhost || VEN_TEST_RESULT=$?

                # Archive test results
                cp /tmp/ven-test-results.txt infrastructure/build-artifacts/out/ven-test-results.txt 2>/dev/null || true

                # Cleanup test VM
                sudo tests/ven-cleanup.sh 2222 user localhost

                if [ "${VEN_TEST_RESULT:-0}" -ne 0 ]; then
                    echo "VEN validation had failures. Check test results."
                    exit 1
                fi
                '''

                archiveArtifacts artifacts: 'infrastructure/build-artifacts/out/ven-test-results.txt', allowEmptyArchive: true
            }
        }
    }

    post {
        always {
            // Cleanup any leftover QEMU processes (installation + test VMs)
            sh 'sudo pkill -f "qemu-system-x86_64.*ubuntu-disk.img" 2>/dev/null || true'
            sh 'sudo pkill -f "qemu-system-x86_64.*ven-test-vm" 2>/dev/null || true'
            sh 'sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true'
            sh 'rm -f /tmp/ven-test-vm.pid 2>/dev/null || true'
            cleanWs(deleteDirs: true, notFailBuild: true)
        }
        success {
            echo 'Pipeline completed successfully.'
        }
        failure {
            echo 'Pipeline failed. Check stage logs for details.'
        }
    }
}
