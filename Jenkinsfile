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
                script {
                    def t0 = System.currentTimeMillis()
                    sh '''#!/usr/bin/env bash
                    set -uo pipefail
                    echo "Running: make build MODE=standard-image"
                    make build MODE=standard-image
                    BUILD_EXIT=$?
                    if [ $BUILD_EXIT -ne 0 ]; then
                        echo "ERROR: make build exited with code $BUILD_EXIT"
                        exit $BUILD_EXIT
                    fi
                    '''
                    def elapsed = ((System.currentTimeMillis() - t0) / 1000).toLong()
                    sh "echo '${elapsed}' > /tmp/enib-timing-image-build.txt"
                    echo "Image build time: ${elapsed}s"
                }
            }
        }

        stage('Build Artifacts (reuse-image)') {
            when {
                expression { params.BUILD_MODE == 'reuse-image' && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                script {
                    def t0 = System.currentTimeMillis()
                    sh '''#!/usr/bin/env bash
                    set -uo pipefail
                    echo "Running: make build MODE=reuse-image (skipping image creation)"
                    make build MODE=reuse-image
                    BUILD_EXIT=$?
                    if [ $BUILD_EXIT -ne 0 ]; then
                        echo "ERROR: make build exited with code $BUILD_EXIT"
                        exit $BUILD_EXIT
                    fi
                    '''
                    def elapsed = ((System.currentTimeMillis() - t0) / 1000).toLong()
                    sh "echo '${elapsed}' > /tmp/enib-timing-image-build.txt"
                    echo "Image build time: ${elapsed}s"
                }
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
                    def t0 = System.currentTimeMillis()
                    sh """#!/usr/bin/env bash
                    set -euo pipefail
                    echo "Running: make build MODE=image-from-tool ICT_IMG=${ictPath}"
                    make build MODE=image-from-tool ICT_IMG="${ictPath}"
                    """
                    def elapsed = ((System.currentTimeMillis() - t0) / 1000).toLong()
                    sh "echo '${elapsed}' > /tmp/enib-timing-image-build.txt"
                    echo "Image build time: ${elapsed}s"
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
                script {
                    def t0 = System.currentTimeMillis()
                    sh '''\
                    set -euo pipefail

                    echo "=== Bootable USB Prepare (virtual NBD) ==="
                    OUT_DIR="${WORKSPACE}/infrastructure/build-artifacts/out"

                    if [ ! -f "${OUT_DIR}/usb-installation-files.tar.gz" ]; then
                        echo "ERROR: usb-installation-files.tar.gz not found in build output."
                        exit 1
                    fi

                    # Create a 32 GB sparse image and attach it to nbd14
                    VIRTUAL_USB_IMG="/tmp/enib-virtual-usb.img"
                    truncate -s 32G "$VIRTUAL_USB_IMG"
                    sudo modprobe nbd max_part=8 2>/dev/null || true
                    sudo qemu-nbd --connect=/dev/nbd14 "$VIRTUAL_USB_IMG"
                    sleep 1
                    echo "Virtual USB device: /dev/nbd14 (32 GB sparse image)"

                    echo "Extracting usb-installation-files.tar.gz..."
                    sudo tar -xzf "${OUT_DIR}/usb-installation-files.tar.gz" -C "${OUT_DIR}/"

                    echo "Running bootable-usb-prepare.sh on /dev/nbd14..."
                    cd "${OUT_DIR}"
                    sudo ./bootable-usb-prepare.sh /dev/nbd14 usb-bootable-files.tar.gz config-file

                    # Cleanup
                    sudo qemu-nbd --disconnect /dev/nbd14 2>/dev/null || true
                    rm -f "$VIRTUAL_USB_IMG"
                    echo "Virtual USB device cleaned up."
                    echo "Bootable USB preparation complete."
                    '''
                    def elapsed = ((System.currentTimeMillis() - t0) / 1000).toLong()
                    sh "echo '${elapsed}' > /tmp/enib-timing-usb-prepare.txt"
                    echo "Bootable USB prepare time: ${elapsed}s"
                }
            }
        }

        stage('Infra Build Report') {
            steps {
                script {
                    def imgSecs = sh(script: "cat /tmp/enib-timing-image-build.txt 2>/dev/null || echo 'N/A'", returnStdout: true).trim()
                    def usbSecs = sh(script: "cat /tmp/enib-timing-usb-prepare.txt 2>/dev/null || echo 'N/A'", returnStdout: true).trim()

                    def fmt = { s ->
                        if (s == 'N/A' || s == 'skipped') return s
                        try {
                            def sec = s.toLong()
                            return "${sec / 60}m ${sec % 60}s  (${sec}s total)"
                        } catch (ignored) { return s }
                    }

                    def report = """\
=== Infra Build Report ===
Build Mode    : ${params.BUILD_MODE}
Build Branch  : ${env.BUILD_BRANCH}
--------------------------------------------
Image Build   : ${fmt(imgSecs)}
USB Prepare   : ${fmt(usbSecs)}
--------------------------------------------
""".stripIndent()

                    echo report
                    sh 'mkdir -p infrastructure/build-artifacts/out'
                    writeFile file: 'infrastructure/build-artifacts/out/build-report.txt', text: report
                }
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
