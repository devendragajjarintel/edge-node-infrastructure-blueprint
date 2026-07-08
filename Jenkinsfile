// SPDX-FileCopyrightText: (C) 2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

// Dynamic parameters: ICT_IMG only applies when BUILD_MODE=ict-based.
// Requires "Active Choices" plugin (uno-choice) for full dynamic visibility.
// Without the plugin, all parameters are shown but ICT-only ones are ignored in standard-image mode.

properties([
    parameters([
        choice(
            name: 'BUILD_MODE',
            choices: ['standard-image', 'ict-based', 'reuse-image'],
            description: 'standard-image: build from Ubuntu minimal desktop image; ict-based: build with Image Composer Tool; reuse-image: skip image creation, package artifacts only'
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
            name: 'MEASURE_USB_TIMING',
            defaultValue: false,
            description: 'Run bootable-usb-prepare.sh against a virtual NBD block device (/dev/nbd14) to measure USB creation time without a physical drive.'
        ),
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
                    if (params.BUILD_MODE == 'standard-image') {
                        echo "Mode: standard-image | Building from Ubuntu minimal desktop image"
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

        stage('Build Image (standard-image)') {
            when {
                expression { params.BUILD_MODE == 'standard-image' && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -uo pipefail
                START=$(date +%s)
                echo "Running: make build MODE=standard-image"
                make build MODE=standard-image
                BUILD_EXIT=$?
                ELAPSED=$(( $(date +%s) - START ))
                echo "$ELAPSED" > /tmp/enib-timing-image-build.txt
                echo "Image build time: $((ELAPSED / 60))m $((ELAPSED % 60))s"
                if [ $BUILD_EXIT -ne 0 ]; then
                    echo "ERROR: make build exited with code $BUILD_EXIT"
                    exit $BUILD_EXIT
                fi
                '''
            }
        }

        stage('Build Artifacts (reuse-image)') {
            when {
                expression { params.BUILD_MODE == 'reuse-image' && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -uo pipefail
                START=$(date +%s)
                echo "Running: make build MODE=reuse-image (skipping image creation)"
                make build MODE=reuse-image
                BUILD_EXIT=$?
                ELAPSED=$(( $(date +%s) - START ))
                echo "$ELAPSED" > /tmp/enib-timing-image-build.txt
                echo "Image build time: $((ELAPSED / 60))m $((ELAPSED % 60))s"
                if [ $BUILD_EXIT -ne 0 ]; then
                    echo "ERROR: make build exited with code $BUILD_EXIT"
                    exit $BUILD_EXIT
                fi
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
                    set -uo pipefail
                    START=\$(date +%s)
                    echo "Running: make build MODE=image-from-tool ICT_IMG=${ictPath}"
                    make build MODE=image-from-tool ICT_IMG="${ictPath}"
                    BUILD_EXIT=\$?
                    ELAPSED=\$(( \$(date +%s) - START ))
                    echo "\$ELAPSED" > /tmp/enib-timing-image-build.txt
                    echo "Image build time: \$((ELAPSED / 60))m \$((ELAPSED % 60))s"
                    if [ \$BUILD_EXIT -ne 0 ]; then
                        echo "ERROR: make build exited with code \$BUILD_EXIT"
                        exit \$BUILD_EXIT
                    fi
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

        stage('Bootable USB Prepare') {
            when {
                expression { params.MEASURE_USB_TIMING }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                echo "=== Bootable USB Prepare (virtual NBD) ==="
                OUT_DIR="${WORKSPACE}/infrastructure/build-artifacts/out"

                if [ ! -f "${OUT_DIR}/usb-installation-files.tar.gz" ]; then
                    echo "ERROR: usb-installation-files.tar.gz not found in build output."
                    exit 1
                fi

                VIRTUAL_USB_IMG="/tmp/enib-virtual-usb.img"
                # Disconnect stale nbd14 from any previous failed run
                sudo qemu-nbd --disconnect /dev/nbd14 2>/dev/null || true
                truncate -s 32G "$VIRTUAL_USB_IMG"
                sudo modprobe nbd max_part=8 2>/dev/null || true
                # --format=raw: removes write restriction on block 0 (needed for partition table)
                # --fork: daemonizes qemu-nbd so the script continues while the device is active
                sudo qemu-nbd --format=raw --fork --connect=/dev/nbd14 "$VIRTUAL_USB_IMG"
                echo "Virtual USB device: /dev/nbd14 (32 GB sparse image)"

                echo "Extracting usb-installation-files.tar.gz..."
                sudo tar -xzf "${OUT_DIR}/usb-installation-files.tar.gz" -C "${OUT_DIR}/"
                cd "${OUT_DIR}"

                # Inject SSH key and proxy into config-file so the script runs non-interactively.
                # sudo strips env vars, so proxy must come from config-file (not the environment).
                SSH_PUB=""
                if [ -f ~/.ssh/id_ed25519.pub ]; then
                    SSH_PUB=$(cat ~/.ssh/id_ed25519.pub)
                elif [ -f ~/.ssh/id_rsa.pub ]; then
                    SSH_PUB=$(cat ~/.ssh/id_rsa.pub)
                else
                    echo "WARNING: No SSH public key found; ssh_key will remain empty."
                fi
                HOST_HP="${http_proxy:-${HTTP_PROXY:-}}"
                HOST_HPS="${https_proxy:-${HTTPS_PROXY:-}}"
                HOST_NP="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1}}"
                while IFS= read -r line; do
                    case "$line" in
                        http_proxy=*)  printf 'http_proxy="%s"\n'  "${HOST_HP}"  ;;
                        https_proxy=*) printf 'https_proxy="%s"\n' "${HOST_HPS}" ;;
                        no_proxy=*)    printf 'no_proxy="%s"\n'    "${HOST_NP}"  ;;
                        HTTP_PROXY=*)  printf 'HTTP_PROXY="%s"\n'  "${HOST_HP}"  ;;
                        HTTPS_PROXY=*) printf 'HTTPS_PROXY="%s"\n' "${HOST_HPS}" ;;
                        NO_PROXY=*)    printf 'NO_PROXY="%s"\n'    "${HOST_NP}"  ;;
                        ssh_key=*)
                            if [ -n "$SSH_PUB" ]; then
                                printf 'ssh_key="%s"\n' "${SSH_PUB}"
                            else
                                echo "$line"
                            fi ;;
                        *) echo "$line" ;;
                    esac
                done < config-file > /tmp/usb-config-file.tmp
                sudo mv /tmp/usb-config-file.tmp config-file
                echo "Config-file updated (proxy + ssh_key injected)."

                START=$(date +%s)
                echo "Running bootable-usb-prepare.sh on /dev/nbd14..."
                sudo ./bootable-usb-prepare.sh /dev/nbd14 usb-bootable-files.tar.gz config-file
                ELAPSED=$(( $(date +%s) - START ))

                sudo qemu-nbd --disconnect /dev/nbd14 2>/dev/null || true
                rm -f "$VIRTUAL_USB_IMG"
                echo "$ELAPSED" > /tmp/enib-timing-usb-prepare.txt
                echo "Bootable USB prepare time: $((ELAPSED / 60))m $((ELAPSED % 60))s"
                echo "Bootable USB preparation complete."
                '''
            }
        }

        stage('Infra Build Report') {
            steps {
                sh '''#!/usr/bin/env bash
                set -uo pipefail

                format_time() {
                    local secs=$1
                    if [ "$secs" = "N/A" ]; then echo "N/A"; return; fi
                    echo "$((secs / 60))m $((secs % 60))s  (${secs}s total)"
                }

                IMG_SECS=$(cat /tmp/enib-timing-image-build.txt 2>/dev/null || echo "N/A")
                USB_SECS=$(cat /tmp/enib-timing-usb-prepare.txt 2>/dev/null || echo "N/A")

                mkdir -p infrastructure/build-artifacts/out
                {
                    echo "=== Infra Build Report ==="
                    echo "Build Mode    : ${BUILD_MODE}"
                    echo "Build Branch  : ${BUILD_BRANCH}"
                    echo "--------------------------------------------"
                    echo "Image Build   : $(format_time "$IMG_SECS")"
                    echo "USB Prepare   : $(format_time "$USB_SECS")"
                    echo "--------------------------------------------"
                } | tee infrastructure/build-artifacts/out/build-report.txt
                '''
                archiveArtifacts artifacts: 'infrastructure/build-artifacts/out/build-report.txt', allowEmptyArchive: true
            }
        }

        stage('VEN Boot & Test') {
            when {
                expression { params.RUN_VEN_DEPLOYMENT }
            }
            steps {
                script {
                    def usbArtifacts = "${env.WORKSPACE}/infrastructure/build-artifacts/out/usb-installation-files.tar.gz"
                    echo "Triggering child job: enib-ven-test"
                    def childResult = build job: 'enib-ven-test',
                        parameters: [
                            string(name: 'USB_ARTIFACTS_PATH', value: usbArtifacts),
                            string(name: 'SSH_PORT', value: '2222'),
                            string(name: 'VEN_MEMORY', value: '4G'),
                            string(name: 'VEN_BOOT_TIMEOUT', value: '300')
                        ],
                        wait: true,
                        propagate: true
                    echo "Child job enib-ven-test completed: ${childResult.result}"
                }
            }
        }
    }

    post {
        always {
            // Cleanup any leftover QEMU processes (installation + test VMs)
            sh 'sudo pkill -f "qemu-system-x86_64.*ubuntu-disk.img" 2>/dev/null || true'
            sh 'sudo pkill -f "qemu-system-x86_64.*ven-test-vm" 2>/dev/null || true'
            sh 'sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true'
            sh 'sudo qemu-nbd --disconnect /dev/nbd14 2>/dev/null || true'
            sh 'rm -f /tmp/ven-test-vm.pid /tmp/enib-virtual-usb.img 2>/dev/null || true'
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
