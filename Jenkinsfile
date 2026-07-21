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
            name: 'USE_BUILD_CACHE',
            defaultValue: false,
            description: '⚡ Quick Build Mode: Use Docker layer cache and artifact cache for faster builds. DEFAULT: false (clean build for accurate KPI metrics)'
        ),
        booleanParam(
            name: 'SKIP_BUILD_REUSE_CACHE',
            defaultValue: false,
            description: 'Skip image build entirely and reuse cached artifacts from the last successful build (/tmp/enib-build-cache/).'
        ),
        booleanParam(
            name: 'RUN_VEN_TESTS',
            defaultValue: true,
            description: 'Trigger the child VEN test job after image/artifact stages complete.'
        ),
        booleanParam(
            name: 'MEASURE_USB_TIMING',
            defaultValue: false,
            description: 'Run bootable-usb-prepare.sh against a virtual NBD block device (/dev/nbd14) to measure USB creation time without a physical drive.'
        ),
        text(
            name: 'TARGET_HOSTS',
            defaultValue: '',
            description: '''Flashing hosts, ONE PER LINE, provisioned in parallel (use a single line for one host):
  ip,user,password,usb_device[,dest_dir]
Example:
  10.0.0.11,user,secret,/dev/sda
  10.0.0.12,user,secret,/dev/sdb,~/enib-artifacts
Blank lines and lines starting with # are ignored. dest_dir defaults to TARGET_DEST_DIR.
Leave empty to skip the copy/flash/verify/validate stages.'''
        ),
        string(
            name: 'TARGET_DEST_DIR',
            defaultValue: '~/enib-artifacts',
            description: 'Default destination directory on the flashing host (used when a TARGET_HOSTS line omits the optional 5th field). Created if it does not exist.'
        ),
        booleanParam(
            name: 'BUILD_ONLY',
            defaultValue: true,
            description: 'Build (and validate) the image only. Skips BOTH copying the artifact to the remote host AND flashing it. Uncheck to enable the copy / flash / boot-verify / post-boot-validation stages.'
        ),
        booleanParam(
            name: 'FLASH_TARGET_NODE',
            defaultValue: false,
            description: '⚠️ DESTRUCTIVE: On each flashing host, extract the artifact, write the bootable installer to the usb_device from its TARGET_HOSTS line (wipes it), set one-time UEFI boot, and REBOOT the host into the installer. Requires BUILD_ONLY unchecked and TARGET_HOSTS set.'
        ),
        string(
            name: 'TARGET_BOOT_VERIFY_TIMEOUT',
            defaultValue: '1800',
            description: '(FLASH_TARGET_NODE only) Seconds to wait for the flashing host to reboot and come back online before failing the verification step.'
        ),
        string(
            name: 'TARGET_INSTALLED_USER',
            defaultValue: 'user',
            description: '(FLASH_TARGET_NODE only) SSH username on the freshly installed image (from the ICT template; default "user"). Used for key-based post-boot verification.'
        ),
        booleanParam(
            name: 'RUN_BENCHMARKS',
            defaultValue: false,
            description: 'After the build/flash flow, run the edge workloads benchmarks on each TARGET_HOSTS host (mounts models over NFS, then runs all benchmark workloads).'
        ),
        booleanParam(
            name: 'BENCHMARK_ONLY',
            defaultValue: false,
            description: 'Run ONLY the benchmarks on already-flashed TARGET_HOSTS hosts. Skips build, flash, verify, and validation entirely. Implies RUN_BENCHMARKS.'
        ),
        string(
            name: 'BENCHMARK_SCRIPT_HOST',
            defaultValue: '',
            description: '(TEMP) user@host holding the not-yet-upstream NFS scripts, e.g. user@10.0.0.5. The benchmark stage copies mount/unmount-nfs-models.sh from here onto each target via scp. Leave empty to skip the copy (assume scripts already in the repo). Remove once the scripts are upstream.'
        ),
        string(
            name: 'BENCHMARK_SCRIPT_SRC',
            defaultValue: '/home/intel/shruti/edge-workloads-and-benchmarks/utils',
            description: '(TEMP) Directory on BENCHMARK_SCRIPT_HOST containing mount-nfs-models.sh and unmount-nfs-models.sh.'
        ),
        string(
            name: 'BENCHMARK_SCRIPT_PW',
            defaultValue: '',
            description: '(TEMP) SSH password for BENCHMARK_SCRIPT_HOST, used only to scp the NFS scripts. Remove once the scripts are upstream. NOTE: not masked in the UI.'
        ),
        string(
            name: 'BENCHMARK_NFS_SERVER',
            defaultValue: '',
            description: '(benchmarks) IP/hostname of the NFS server exporting the benchmark collateral (models + media).'
        ),
        string(
            name: 'BENCHMARK_NFS_PATH',
            defaultValue: '',
            description: '(benchmarks) Path ON the NFS server that is exported (the server-side collateral directory).'
        ),
    ])
])

// ── Benchmark configuration (non-sensitive; IP/path/creds come from params) ──
BENCHMARK_WORKLOADS  = 'all'   // "all" or a comma-separated subset: vision,media,genai,pipeline
BENCHMARK_REPO_URL   = 'https://github.com/open-edge-platform/edge-workloads-and-benchmarks.git'

// ── Multi-host flashing helpers ──────────────────────────────────────────────
// Thread-safe list of hosts that errored in any remote phase, so later phases
// skip them and the build is marked FAILURE (the other hosts still proceed).
failedHosts = java.util.Collections.synchronizedList([])

// Parse TARGET_HOSTS ("ip,user,password,device[,dest]" per line). One line = one host;
// a single line is a single-host run.
def parseHosts() {
    def out = []
    def raw = params.TARGET_HOSTS?.trim()
    if (raw) {
        raw.readLines().each { rawLine ->
            def line = rawLine.trim()
            if (!line || line.startsWith('#')) return
            // NOTE: avoid the spread operator (p*.trim()) — CPS does not support it.
            def raw2 = line.split(',', -1)
            def p = []
            for (int i = 0; i < raw2.length; i++) { p << raw2[i].trim() }
            if (p.size() < 4 || !p[0] || !p[1] || !p[2] || !p[3]) {
                error "Invalid TARGET_HOSTS line (need ip,user,password,device[,dest]): '${rawLine}'"
            }
            out << [ip: p[0], user: p[1], password: p[2], device: p[3],
                    dest: (p.size() >= 5 && p[4]) ? p[4] : params.TARGET_DEST_DIR]
        }
    }
    return out
}

// True when at least one flashing host is configured.
def hasHosts() {
    return (params.TARGET_HOSTS?.trim()) as boolean
}

// False in BENCHMARK_ONLY mode, which skips build/flash/verify/validate and runs
// only the benchmark stage.
def buildStages() {
    return !params.BENCHMARK_ONLY
}

// True when benchmarks should run (explicitly, or implied by BENCHMARK_ONLY).
def runBenchmarks() {
    return (params.RUN_BENCHMARKS || params.BENCHMARK_ONLY) as boolean
}

// Run body(host) for every parsed host in parallel. A host that failed an earlier
// phase is skipped; a failure here is recorded (build → FAILURE) but does NOT abort
// the other hosts (failFast=false).
def runPerHost(String phase, Closure body) {
    def hosts = parseHosts()
    if (hosts.isEmpty()) { echo "No target hosts configured; skipping ${phase}."; return }
    def branches = [:]
    hosts.each { h ->
        branches["${phase}:${h.ip}"] = {
            if (failedHosts.contains(h.ip)) {
                echo "[${phase}] Skipping ${h.ip} — it failed an earlier phase."
                return
            }
            // catchError marks BOTH the stage and the build red on failure, while
            // failFast=false lets the other host branches keep running. (A plain
            // try/catch would swallow the error and leave the stage green.)
            catchError(buildResult: 'FAILURE', stageResult: 'FAILURE', message: "Host ${h.ip} failed ${phase}") {
                try {
                    body(h)
                } catch (err) {
                    failedHosts.add(h.ip)
                    echo "[${phase}] Host ${h.ip} FAILED: ${err}"
                    throw err
                }
            }
        }
    }
    branches.failFast = false
    parallel branches
}

pipeline {
    agent { label 'fed-node2' }

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
                    // Display build cache mode
                    def cacheMode = params.USE_BUILD_CACHE ? "⚡ CACHED BUILD (Quick Mode)" : "🧹 CLEAN BUILD (KPI Mode - Docker cache will be cleared)"
                    echo "═══════════════════════════════════════════════════════════"
                    echo "Cache Mode: ${cacheMode}"
                    echo "═══════════════════════════════════════════════════════════"

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

                    // Update build description with cache mode
                    def cacheBadge = params.USE_BUILD_CACHE ? "⚡CACHED" : "🧹CLEAN"
                    currentBuild.description = "${cacheBadge} | ${params.BUILD_MODE}"
                }
            }
        }

        stage('Checkout') {
            when {
                expression { buildStages() }
            }
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
            when {
                expression { buildStages() }
            }
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

                # Verify Go (needed for CDI generator build and ICT binary).
                # README (infrastructure/host-os/ict/README.md) requires Go 1.24.0 or later.
                if ! command -v go &>/dev/null; then
                    echo "ERROR: Go not found in PATH. PATH=$PATH"
                    exit 1
                fi
                echo "Go: $(go version)"
                GO_VER=$(go version | grep -oE 'go[0-9]+[.][0-9]+([.][0-9]+)?' | head -1 | sed 's/^go//')
                REQ_GO="1.24.0"
                if [ -n "$GO_VER" ] && [ "$(printf '%s\n%s\n' "$REQ_GO" "$GO_VER" | sort -V | head -1)" != "$REQ_GO" ]; then
                    echo "ERROR: Go ${GO_VER} is older than required ${REQ_GO}. See infrastructure/host-os/ict/README.md."
                    exit 1
                fi

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

        stage('Clear Build Cache') {
            when {
                expression { buildStages() && !params.USE_BUILD_CACHE && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                script {
                    echo "═══════════════════════════════════════════════════════════"
                    echo "🧹 CLEAN BUILD MODE: Clearing Docker cache for accurate KPI metrics"
                    echo "═══════════════════════════════════════════════════════════"
                }
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                echo ""
                echo "📊 Docker Cache Status BEFORE cleanup:"
                echo "────────────────────────────────────────"
                docker system df || true
                echo ""

                # Clear Docker build cache
                echo "🗑️  Clearing Docker BuildKit cache..."
                docker builder prune -af || true

                # Remove specific build images to force rebuild
                echo "🗑️  Removing cached build images..."
                docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "custom-desktop|micro-os|edge-base|cdi-generator|build-edge-blueprint" | xargs -r docker rmi -f || true

                # Clear artifact cache
                CACHE_DIR="/tmp/enib-build-cache"
                if [ -d "$CACHE_DIR" ]; then
                    echo "🗑️  Clearing artifact cache at ${CACHE_DIR}..."
                    rm -rf "$CACHE_DIR"/*
                fi

                echo ""
                echo "✅ Docker Cache Status AFTER cleanup:"
                echo "────────────────────────────────────────"
                docker system df || true
                echo ""
                echo "✅ Clean build environment ready. All caches cleared."
                '''
            }
        }

        stage('Restore Cached Build') {
            when {
                expression { buildStages() && params.SKIP_BUILD_REUSE_CACHE }
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
                expression { buildStages() && params.BUILD_MODE == 'standard-image' && !params.SKIP_BUILD_REUSE_CACHE }
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
                expression { buildStages() && params.BUILD_MODE == 'reuse-image' && !params.SKIP_BUILD_REUSE_CACHE }
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
                expression { buildStages() && params.BUILD_MODE == 'ict-based' && !params.ICT_IMG?.trim() && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                echo "=== Building ICT Image from Source ==="
                ICT_TEMPLATE="infrastructure/host-os/ict/generic-handheld-os-template.yml"

                # Clone Image Composer Tool
                if [ ! -d ict-tool ]; then
                    git clone --depth 1 --branch main \
                        https://github.com/open-edge-platform/image-composer-tool.git ict-tool
                fi

                # Install image composition prerequisites.
                # systemd-ukify lives in the 'universe' component and only exists on
                # Ubuntu 23.04+; mmdebstrap 0.8.x (Ubuntu 22.04) is broken and needs 1.4.3+.
                # See infrastructure/host-os/ict/README.md ("Install Image Composition Prerequisites").
                #. /etc/os-release
                #echo "Build host: ${PRETTY_NAME:-unknown}"
                # Ensure the universe component is enabled (no-op if already present).
                #sudo add-apt-repository -y universe 2>/dev/null || true
                # Do NOT suppress update output: a silent failure here is what produces the
                # misleading "Unable to locate package systemd-ukify" error downstream.
                #sudo apt-get update
                #for pkg in systemd-ukify mmdebstrap; do
                #    if ! apt-cache policy "$pkg" | grep -q 'Candidate: [^(]'; then
                #        echo "ERROR: Package '$pkg' has no install candidate on ${PRETTY_NAME:-this host}."
                #        echo "       ICT requires Ubuntu 24.04 (23.04+) per infrastructure/host-os/ict/README.md."
                #        exit 1
                #    fi
                #done
                # sudo apt-get install -y --no-install-recommends systemd-ukify mmdebstrap

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

                # The build runs as root (sudo -E), so workspace/ and cache/ come out
                # root-owned. Reclaim ownership for the Jenkins user before searching them,
                # otherwise `find` reports "Permission denied" on those subtrees.
                sudo chown -R "$(id -u):$(id -g)" ict-tool

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
                expression { buildStages() && params.BUILD_MODE == 'ict-based' && !params.SKIP_BUILD_REUSE_CACHE }
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
            when {
                expression { buildStages() }
            }
            steps {
                script {
                    def cacheStatus = params.USE_BUILD_CACHE ? "⚡ CACHED BUILD" : "🧹 CLEAN BUILD"
                    echo "═══════════════════════════════════════════════════════════"
                    echo "Build Type: ${cacheStatus}"
                    echo "═══════════════════════════════════════════════════════════"
                }
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

        stage('Copy Artifacts to Flashing Host') {
            when {
                expression { buildStages() && !params.BUILD_ONLY && hasHosts() }
            }
            steps {
                // Per README Phase 1/2, usb-installation-files.tar.gz is the sole build output
                // needed on the flashing host; it bundles the raw image, config-file, and the
                // bootable-usb-prepare.sh / ven-deployment.sh scripts used to write the USB.
                // Runs in parallel across every configured host.
                // SSHPASS is consumed by `sshpass -e` so the password never appears in the
                // process args or the build log.
                runPerHost('copy') { h ->
                withEnv([
                    "SSHPASS=${h.password}",
                    "TARGET_NODE_IP=${h.ip}",
                    "TARGET_NODE_USER=${h.user}",
                    "TARGET_DEST_DIR=${h.dest}"
                ]) {
                    sh '''#!/usr/bin/env bash
                    set -euo pipefail

                    OUT_DIR="${WORKSPACE}/infrastructure/build-artifacts/out"
                    ARTIFACT="usb-installation-files.tar.gz"
                    SRC="${OUT_DIR}/${ARTIFACT}"

                    if [ ! -f "$SRC" ]; then
                        echo "ERROR: ${ARTIFACT} not found at ${SRC}."
                        echo "       Nothing to copy. Ensure a build mode ran and produced the artifact."
                        exit 1
                    fi

                    if ! command -v sshpass &>/dev/null; then
                        echo "Installing sshpass..."
                        sudo apt-get update
                        sudo apt-get install -y --no-install-recommends sshpass
                    fi

                    # StrictHostKeyChecking=no: the flashing host is provided ad hoc via a
                    # parameter, so its key is not pre-seeded in known_hosts.
                    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"

                    echo "Ensuring destination directory exists on ${TARGET_NODE_IP}: ${TARGET_DEST_DIR}"
                    sshpass -e ssh ${SSH_OPTS} "${TARGET_NODE_USER}@${TARGET_NODE_IP}" "mkdir -p ${TARGET_DEST_DIR}"

                    SIZE=$(du -h "$SRC" | cut -f1)
                    echo "Copying ${ARTIFACT} (${SIZE}) to ${TARGET_NODE_USER}@${TARGET_NODE_IP}:${TARGET_DEST_DIR}/ ..."
                    START=$(date +%s)
                    sshpass -e scp ${SSH_OPTS} "$SRC" "${TARGET_NODE_USER}@${TARGET_NODE_IP}:${TARGET_DEST_DIR}/"
                    ELAPSED=$(( $(date +%s) - START ))

                    echo "Verifying copy on remote host..."
                    sshpass -e ssh ${SSH_OPTS} "${TARGET_NODE_USER}@${TARGET_NODE_IP}" "ls -lh ${TARGET_DEST_DIR}/${ARTIFACT}"

                    echo "Copy complete in $((ELAPSED / 60))m $((ELAPSED % 60))s."
                    echo "On the flashing host, extract with: cd ${TARGET_DEST_DIR} && sudo tar -xzf ${ARTIFACT}"
                    '''
                }
                }
            }
        }

        stage('Flash Target Node') {
            when {
                expression { buildStages() && !params.BUILD_ONLY && params.FLASH_TARGET_NODE && hasHosts() }
            }
            steps {
                // DESTRUCTIVE: on each flashing host this extracts the artifact, updates the
                // config-file (proxy + Jenkins SSH key so post-boot verification works),
                // writes the bootable installer to the host's device (WIPES it), sets a
                // one-time UEFI boot entry, and reboots the host into the installer.
                // Runs in parallel across every configured host.
                runPerHost('flash') { h ->
                withEnv([
                    "SSHPASS=${h.password}",
                    "TARGET_NODE_IP=${h.ip}",
                    "TARGET_NODE_USER=${h.user}",
                    "TARGET_DEST_DIR=${h.dest}",
                    "TARGET_USB_DEVICE=${h.device}"
                ]) {
                    sh '''#!/usr/bin/env bash
                    set -euo pipefail

                    if [ -z "${TARGET_USB_DEVICE:-}" ]; then
                        echo "ERROR: no USB device specified for ${TARGET_NODE_IP}."
                        exit 1
                    fi

                    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
                    REMOTE="${TARGET_NODE_USER}@${TARGET_NODE_IP}"
                    # Per-host temp file so parallel branches never clobber each other.
                    LOCAL_SCRIPT="/tmp/enib-remote-flash-${TARGET_NODE_IP}.sh"

                    if ! command -v sshpass &>/dev/null; then
                        echo "Installing sshpass..."
                        sudo apt-get update
                        sudo apt-get install -y --no-install-recommends sshpass
                    fi

                    # Jenkins node public key: injected into config-file so the installed image
                    # trusts this node for key-based post-boot verification.
                    SSH_PUB=""
                    if [ -f ~/.ssh/id_ed25519.pub ]; then
                        SSH_PUB=$(cat ~/.ssh/id_ed25519.pub)
                    elif [ -f ~/.ssh/id_rsa.pub ]; then
                        SSH_PUB=$(cat ~/.ssh/id_rsa.pub)
                    else
                        echo "WARNING: No SSH public key on the Jenkins node; post-boot verification via key auth will not work."
                    fi

                    HOST_HP="${http_proxy:-${HTTP_PROXY:-}}"
                    HOST_HPS="${https_proxy:-${HTTPS_PROXY:-}}"
                    HOST_NP="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1}}"

                    # Resolve the destination dir to an absolute path (expands a leading ~).
                    ABS_DEST=$(sshpass -e ssh ${SSH_OPTS} "$REMOTE" "cd ${TARGET_DEST_DIR} && pwd")
                    echo "Remote artifact directory: ${ABS_DEST}"

                    # Build the remote provisioning script. Quoted heredoc: no local expansion,
                    # values are passed as positional args ($1..$6) instead.
                    cat > "$LOCAL_SCRIPT" <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

DEST_DIR="$1"
USB_DEVICE="$2"
SSH_PUB="$3"
HP="$4"
HPS="$5"
NP="$6"
PW="$7"

echo "=== Remote flash on $(hostname) ==="

# Authenticate sudo once using the host password from TARGET_HOSTS. This caches the
# sudo credential (~15 min), so every plain `sudo` below works without NOPASSWD.
if ! echo "$PW" | sudo -S -v 2>/dev/null; then
    echo "ERROR: sudo authentication failed on the flashing host (check the password)."
    exit 1
fi

cd "$DEST_DIR"

# The freshly-installed minimal image may lack tools that bootable-usb-prepare.sh
# needs (sgdisk from gdisk, and pigz). The script tries to apt-install gdisk itself
# but that silently fails without a proxy, so install them here with the proxy the
# pipeline passes in. Skip anything already present.
NEED_PKGS=""
command -v sgdisk >/dev/null 2>&1 || NEED_PKGS="$NEED_PKGS gdisk"
command -v pigz   >/dev/null 2>&1 || NEED_PKGS="$NEED_PKGS pigz"
if [ -n "$NEED_PKGS" ]; then
    echo "Installing missing prerequisites:${NEED_PKGS}"
    sudo env http_proxy="$HP" https_proxy="$HPS" no_proxy="$NP" apt-get update -qq || true
    if ! sudo env http_proxy="$HP" https_proxy="$HPS" no_proxy="$NP" \
            apt-get install -y --no-install-recommends $NEED_PKGS; then
        echo "ERROR: failed to install required tools (${NEED_PKGS}) on the flashing host."
        exit 1
    fi
fi

echo "Extracting usb-installation-files.tar.gz..."
sudo tar -xzf usb-installation-files.tar.gz
for f in bootable-usb-prepare.sh usb-bootable-files.tar.gz config-file; do
    if [ ! -f "$f" ]; then
        echo "ERROR: expected file '$f' missing after extraction."
        exit 1
    fi
done

# Update config-file: inject proxy and the Jenkins node SSH key (non-interactive install).
sudo cp config-file config-file.orig
while IFS= read -r line; do
    case "$line" in
        http_proxy=*)  printf 'http_proxy="%s"\n'  "${HP}"  ;;
        https_proxy=*) printf 'https_proxy="%s"\n' "${HPS}" ;;
        no_proxy=*)    printf 'no_proxy="%s"\n'    "${NP}"  ;;
        HTTP_PROXY=*)  printf 'HTTP_PROXY="%s"\n'  "${HP}"  ;;
        HTTPS_PROXY=*) printf 'HTTPS_PROXY="%s"\n' "${HPS}" ;;
        NO_PROXY=*)    printf 'NO_PROXY="%s"\n'    "${NP}"  ;;
        ssh_key=*)
            if [ -n "$SSH_PUB" ]; then
                printf 'ssh_key="%s"\n' "${SSH_PUB}"
            else
                echo "$line"
            fi ;;
        *) echo "$line" ;;
    esac
done < config-file | sudo tee config-file.tmp >/dev/null
sudo mv config-file.tmp config-file
echo "config-file updated (proxy + ssh_key injected)."

# Verify the target block device with lsblk before writing to it.
echo "Inspecting target device ${USB_DEVICE}:"
lsblk -o NAME,TYPE,SIZE,TRAN,MOUNTPOINT "$USB_DEVICE"
DEV_TYPE=$(lsblk -dno TYPE "$USB_DEVICE")
if [ "$DEV_TYPE" != "disk" ]; then
    echo "ERROR: ${USB_DEVICE} is not a whole disk (type=${DEV_TYPE}). Refusing to flash."
    exit 1
fi

# Unmount any mounted partitions on the target before writing.
echo "Unmounting any partitions on ${USB_DEVICE}..."
sudo umount ${USB_DEVICE}* 2>/dev/null || true

echo "Running bootable-usb-prepare.sh on ${USB_DEVICE}..."
sudo ./bootable-usb-prepare.sh "$USB_DEVICE" usb-bootable-files.tar.gz config-file

echo "Current UEFI boot entries:"
sudo efibootmgr -v
EFI_OUT=$(sudo efibootmgr -v)

# Identify the USB boot entry to boot from. bootable-usb-prepare.sh does NOT create a
# new UEFI entry; the USB is reached via the firmware's auto-created removable entry,
# whose device path is the USB controller (PciRoot/.../USB(...)) with no GPT PARTUUID.
# So we scan all existing entries and pick the USB one, most specific match first.
USB_ENTRY=""

# Strategy 1: match a partition PARTUUID of the target device (works if the installer
# wrote an ESP the firmware indexed as HD(GPT,<partuuid>)).
# NOTE: each match uses `|| true` because a no-match grep exits non-zero, which under
# `set -euo pipefail` would abort the whole script mid-detection before later strategies
# (or the error handler below) get a chance to run.
for uuid in $(lsblk -no PARTUUID "$USB_DEVICE" 2>/dev/null || true); do
    [ -z "$uuid" ] && continue
    m=$(echo "$EFI_OUT" | grep -iE "^Boot[0-9A-Fa-f]{4}.*${uuid}" | grep -oE '^Boot[0-9A-Fa-f]{4}' | head -1 | sed 's/^Boot//' || true)
    if [ -n "$m" ]; then USB_ENTRY="$m"; echo "Matched USB boot entry by PARTUUID ${uuid}."; break; fi
done

# Strategy 2: match by the target device's model/vendor tokens (ties the entry to THIS
# exact USB drive, avoiding a wrong pick if several USB entries exist).
if [ -z "$USB_ENTRY" ]; then
    MODELVEND="$(lsblk -dno MODEL "$USB_DEVICE" 2>/dev/null || true) $(lsblk -dno VENDOR "$USB_DEVICE" 2>/dev/null || true)"
    for tok in $(echo "$MODELVEND" | tr '_/.-' '    '); do
        [ ${#tok} -ge 4 ] || continue
        m=$(echo "$EFI_OUT" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -iF "$tok" | grep -oE '^Boot[0-9A-Fa-f]{4}' | head -1 | sed 's/^Boot//' || true)
        if [ -n "$m" ]; then USB_ENTRY="$m"; echo "Matched USB boot entry by device token '${tok}'."; break; fi
    done
fi

# Strategy 3: match the firmware's removable USB entry by "USB" in its description.
if [ -z "$USB_ENTRY" ]; then
    m=$(echo "$EFI_OUT" | grep -E '^Boot[0-9A-Fa-f]{4}' | grep -iE 'usb' | grep -oE '^Boot[0-9A-Fa-f]{4}' | head -1 | sed 's/^Boot//' || true)
    if [ -n "$m" ]; then USB_ENTRY="$m"; echo "Matched USB boot entry by 'USB' description."; fi
fi

if [ -z "$USB_ENTRY" ]; then
    echo "ERROR: could not determine the USB installer UEFI boot entry automatically."
    echo "       Inspect 'efibootmgr -v' above and set BootNext manually."
    exit 1
fi
echo "USB installer UEFI boot entry: Boot${USB_ENTRY}"

# One-time boot into the USB entry, then reboot (backgrounded so ssh returns first).
sudo efibootmgr -n "$USB_ENTRY"
echo "BootNext set to ${USB_ENTRY}. Rebooting the flashing host in 5s..."
sudo bash -c 'nohup sh -c "sleep 5; reboot" >/dev/null 2>&1 &'
echo "Reboot scheduled."
REMOTE_SCRIPT

                    echo "Sending and executing remote flash script on ${REMOTE}..."
                    sshpass -e ssh ${SSH_OPTS} "$REMOTE" "bash -s -- '${ABS_DEST}' '${TARGET_USB_DEVICE}' '${SSH_PUB}' '${HOST_HP}' '${HOST_HPS}' '${HOST_NP}' '${SSHPASS}'" < "$LOCAL_SCRIPT"
                    rm -f "$LOCAL_SCRIPT"
                    echo "Flash + reboot triggered on ${TARGET_NODE_IP}."
                    '''
                }
                }
            }
        }

        stage('Verify Target Boot') {
            when {
                expression { buildStages() && !params.BUILD_ONLY && params.FLASH_TARGET_NODE && hasHosts() }
            }
            steps {
                runPerHost('verify') { h ->
                withEnv([
                    "TARGET_NODE_IP=${h.ip}",
                    "TARGET_INSTALLED_USER=${params.TARGET_INSTALLED_USER}",
                    "TARGET_BOOT_VERIFY_TIMEOUT=${params.TARGET_BOOT_VERIFY_TIMEOUT}"
                ]) {
                    sh '''#!/usr/bin/env bash
                    set -uo pipefail

                    IP="${TARGET_NODE_IP}"
                    USER_INSTALLED="${TARGET_INSTALLED_USER}"
                    TIMEOUT="${TARGET_BOOT_VERIFY_TIMEOUT}"
                    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"

                    echo "Verifying ${IP} reboots into the installed image (timeout ${TIMEOUT}s)."
                    echo "Post-install login uses key auth as '${USER_INSTALLED}' (Jenkins key injected into config-file)."

                    # Phase 1: wait for the host to go down (reboot into installer + install).
                    echo "Waiting for ${IP} to go offline (reboot)..."
                    DOWN=0
                    for i in $(seq 1 60); do
                        if ! ping -c1 -W2 "$IP" >/dev/null 2>&1; then
                            DOWN=1
                            echo "Host is offline after ${i} checks."
                            break
                        fi
                        sleep 5
                    done
                    [ "$DOWN" -eq 1 ] || echo "NOTE: host never observed offline; it may reboot faster than the poll interval."

                    # Phase 2: poll SSH (key auth as installed user) until the new image is up.
                    START=$(date +%s)
                    while true; do
                        ELAPSED=$(( $(date +%s) - START ))
                        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
                            echo "ERROR: ${IP} did not come back as the installed image within ${TIMEOUT}s."
                            exit 1
                        fi
                        if OUT=$(ssh ${SSH_OPTS} "${USER_INSTALLED}@${IP}" \
                                'cat /etc/os-release 2>/dev/null; echo "---"; uname -a; hostnamectl 2>/dev/null || true' 2>/dev/null); then
                            echo "=========================================================="
                            echo "Target booted and reachable as ${USER_INSTALLED}@${IP} after ${ELAPSED}s."
                            echo "----------------------------------------------------------"
                            echo "$OUT"
                            echo "=========================================================="
                            echo "Image boot verified."
                            exit 0
                        fi
                        echo "  [${ELAPSED}s] not reachable yet; retrying..."
                        sleep 15
                    done
                    '''
                }
                }
            }
        }

        stage('Post-Boot Validation') {
            when {
                expression { buildStages() && !params.BUILD_ONLY && params.FLASH_TARGET_NODE && hasHosts() }
            }
            steps {
                runPerHost('validate') { h ->
                withEnv([
                    "TARGET_NODE_IP=${h.ip}",
                    "TARGET_INSTALLED_USER=${params.TARGET_INSTALLED_USER}"
                ]) {
                    // README Phase 3: post-boot bring-up and validation on the target system.
                    // Runs the documented checks over SSH (key auth as the installed user).
                    // These are diagnostic — the build is not failed on individual soft checks.
                    sh '''#!/usr/bin/env bash
                    set -uo pipefail

                    IP="${TARGET_NODE_IP}"
                    USER_INSTALLED="${TARGET_INSTALLED_USER}"
                    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o BatchMode=yes"
                    REMOTE="${USER_INSTALLED}@${IP}"

                    run_remote() {
                        # $1 = human label, $2 = remote command
                        echo "───────────────────────────────────────────────────────────"
                        echo ">>> $1"
                        echo "    \\$ $2"
                        if ssh ${SSH_OPTS} "$REMOTE" "$2" 2>&1; then
                            echo "    [ok]"
                        else
                            echo "    [WARN] command failed or returned non-zero (see output above)."
                        fi
                    }

                    echo "═══════════════════════════════════════════════════════════"
                    echo "   POST-BOOT VALIDATION (README Phase 3) on ${REMOTE}"
                    echo "═══════════════════════════════════════════════════════════"

                    # Kubernetes cluster: nodes and plugin pods.
                    run_remote "Kubernetes nodes"          "sudo kubectl get nodes"
                    run_remote "Kubernetes pods (all ns)"  "sudo kubectl get pods -A"

                    # SR-IOV status.
                    run_remote "SR-IOV info" "sudo cat /sys/kernel/debug/dri/0000:00:02.1/sriov_info"

                    # GPU / NPU driver bring-up.
                    run_remote "GPU driver (xe) dmesg"  "sudo dmesg | grep -i xe  || echo '(no xe lines)'"
                    run_remote "NPU driver (vpu) dmesg" "sudo dmesg | grep -i vpu || echo '(no vpu lines)'"

                    # Containers.
                    run_remote "Docker info" "docker info"
                    run_remote "Docker ps"   "docker ps"

                    echo "═══════════════════════════════════════════════════════════"
                    echo "Post-boot validation complete. Review [WARN] lines above."
                    echo "═══════════════════════════════════════════════════════════"
                    '''
                }
                }
            }
        }

        stage('Run Benchmarks') {
            when {
                expression { runBenchmarks() && hasHosts() }
            }
            steps {
                // Runs the edge-workloads-and-benchmarks suite on each host in parallel.
                // Per NFS-SETUP.md: clone the repo on the host, then mount-nfs-models.sh
                // mounts the collateral over NFS and runs `make benchmarks`. SSH + sudo
                // both use the host password from TARGET_HOSTS.
                runPerHost('benchmark') { h ->
                withEnv([
                    "SSHPASS=${h.password}",
                    "TARGET_NODE_IP=${h.ip}",
                    "TARGET_NODE_USER=${h.user}",
                    "BM_NFS_SERVER=${params.BENCHMARK_NFS_SERVER}",
                    "BM_NFS_PATH=${params.BENCHMARK_NFS_PATH}",
                    "BM_WORKLOADS=${BENCHMARK_WORKLOADS}",
                    "BM_REPO_URL=${BENCHMARK_REPO_URL}",
                    // TEMP: source of the not-yet-upstream NFS scripts + its SSH password.
                    "BM_SCRIPT_HOST=${params.BENCHMARK_SCRIPT_HOST}",
                    "BM_SCRIPT_SRC=${params.BENCHMARK_SCRIPT_SRC}",
                    "BM_SCRIPT_PW=${params.BENCHMARK_SCRIPT_PW}"
                ]) {
                    sh '''#!/usr/bin/env bash
                    set -euo pipefail

                    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
                    REMOTE="${TARGET_NODE_USER}@${TARGET_NODE_IP}"

                    HOST_HP="${http_proxy:-${HTTP_PROXY:-}}"
                    HOST_HPS="${https_proxy:-${HTTPS_PROXY:-}}"
                    HOST_NP="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1}}"

                    REMOTE_REPO="edge-workloads-and-benchmarks"

                    # ── Step 1: clone the benchmarks repo on the target (proxy-aware) ──
                    echo "Cloning benchmarks repo on ${TARGET_NODE_IP} (if needed)..."
                    sshpass -e ssh ${SSH_OPTS} "$REMOTE" \
                        "export http_proxy='${HOST_HP}' https_proxy='${HOST_HPS}' no_proxy='${HOST_NP}'; \
                         [ -d ~/${REMOTE_REPO}/.git ] || git clone --depth 1 '${BM_REPO_URL}' ~/${REMOTE_REPO}"

                    # ── Step 2 (TEMP): NFS scripts are not yet upstream. Copy them from
                    # BENCHMARK_SCRIPT_HOST to the Jenkins node, then scp them to the target's
                    # repo utils/. Both hops run from the Jenkins node (sshpass here); nothing
                    # is installed on the target. Remove once the scripts are upstream.
                    if [ -n "${BM_SCRIPT_HOST}" ] && [ -n "${BM_SCRIPT_PW}" ]; then
                        echo "[TEMP] Copying NFS scripts from ${BM_SCRIPT_HOST} to target..."
                        TMP_SCRIPTS=$(mktemp -d)
                        # One scp per file: scp opens a separate SSH connection per source, and
                        # sshpass only feeds the password to the first — so copy files one at a time.
                        for f in mount-nfs-models.sh unmount-nfs-models.sh; do
                            SSHPASS="${BM_SCRIPT_PW}" sshpass -e scp ${SSH_OPTS} \
                                "${BM_SCRIPT_HOST}:${BM_SCRIPT_SRC}/$f" "$TMP_SCRIPTS/$f"
                            sshpass -e scp ${SSH_OPTS} "$TMP_SCRIPTS/$f" "$REMOTE:${REMOTE_REPO}/utils/$f"
                        done
                        rm -rf "$TMP_SCRIPTS"
                        echo "[TEMP] NFS scripts copied to target."
                    else
                        echo "[TEMP] BENCHMARK_SCRIPT_HOST/PW not set; assuming NFS scripts already in repo."
                    fi

                    # ── Step 3: run mount + benchmarks + report + unmount on the target ──
                    LOCAL_SCRIPT="/tmp/enib-remote-benchmark-${TARGET_NODE_IP}.sh"
                    cat > "$LOCAL_SCRIPT" <<'REMOTE_BENCH'
#!/usr/bin/env bash
set -euo pipefail

NFS_SERVER="$1"
NFS_PATH="$2"
WORKLOADS="$3"
HP="$4"
HPS="$5"
NP="$6"
PW="$7"

echo "=== Benchmarks on $(hostname) (NFS ${NFS_SERVER}:${NFS_PATH}, workloads=${WORKLOADS}) ==="

# Validate the sudo password up front. Do NOT rely on the cached credential later:
# the benchmark run can exceed sudo's ~15-min timeout, so every sudo below is fed the
# password on stdin via sudo -S (works without a tty).
if ! echo "$PW" | sudo -S -v 2>/dev/null; then
    echo "ERROR: sudo authentication failed on ${HOSTNAME:-target} (check the password)."
    exit 1
fi
# Helper: run sudo with the password piped in, every time (immune to cache expiry).
sudo_pw() { echo "$PW" | sudo -S "$@"; }

export http_proxy="$HP" https_proxy="$HPS" no_proxy="$NP"
export HTTP_PROXY="$HP" HTTPS_PROXY="$HPS" NO_PROXY="$NP"

REPO_DIR="$HOME/edge-workloads-and-benchmarks"
cd "$REPO_DIR"
chmod +x utils/mount-nfs-models.sh utils/unmount-nfs-models.sh 2>/dev/null || true

# Build the --workload argument only when a subset is requested.
WL_ARG=""
if [ -n "$WORKLOADS" ] && [ "$WORKLOADS" != "all" ]; then
    WL_ARG="--workload $WORKLOADS"
fi

# Install benchmark prerequisites once, from the repo root. mount-nfs-models.sh runs
# 'make check' + benchmarks internally, so prereqs must be satisfied before it runs.
echo "Running make prereqs (INCLUDE_GPU=False INCLUDE_NPU=False)..."
make prereqs INCLUDE_GPU=False INCLUDE_NPU=False

echo "Running mount-nfs-models.sh (mount NFS collateral + run benchmarks)..."
echo "$PW" | sudo -S -E ./utils/mount-nfs-models.sh "$NFS_SERVER" --path "$NFS_PATH" $WL_ARG

# Track failures but keep going so we always attempt the unmount, then fail the stage
# at the end if anything went wrong (so the Jenkins stage turns red, not green).
RC=0

# 'make report' needs jq; the minimal image may not have it. Install it right before.
if ! command -v jq >/dev/null 2>&1; then
    echo "Installing jq (required by 'make report')..."
    sudo_pw -E apt-get update -qq || true
    sudo_pw -E apt-get install -y --no-install-recommends jq || echo "WARNING: failed to install jq."
fi

echo "Generating consolidated report (make report)..."
make report || { echo "ERROR: make report failed."; RC=1; }

# unmount-nfs-models.sh prompts interactively (remove mount point / restore backup);
# feed "n" to both so it can't hang over the non-interactive SSH pipe.
echo "Unmounting NFS models..."
printf 'n\nn\n' | sudo_pw ./utils/unmount-nfs-models.sh || { echo "ERROR: unmount failed; NFS mount may still be active."; RC=1; }

echo "Benchmarks finished. Results under ${REPO_DIR}/collateral/results/ , report under ${REPO_DIR}/collateral/reports/"
if [ "$RC" -ne 0 ]; then
    echo "ERROR: one or more post-benchmark steps failed (see above)."
    exit 1
fi
REMOTE_BENCH

                    echo "Sending and executing remote benchmark script on ${REMOTE}..."
                    sshpass -e ssh ${SSH_OPTS} "$REMOTE" "bash -s -- '${BM_NFS_SERVER}' '${BM_NFS_PATH}' '${BM_WORKLOADS}' '${HOST_HP}' '${HOST_HPS}' '${HOST_NP}' '${SSHPASS}'" < "$LOCAL_SCRIPT"
                    rm -f "$LOCAL_SCRIPT"
                    echo "Benchmarks completed on ${TARGET_NODE_IP}."
                    '''
                }
                }
            }
        }

        stage('Save Build Cache') {
            when {
                expression { buildStages() && params.USE_BUILD_CACHE && !params.SKIP_BUILD_REUSE_CACHE }
            }
            steps {
                sh '''#!/usr/bin/env bash
                set -euo pipefail

                CACHE_DIR="/tmp/enib-build-cache"
                echo "=== Saving build artifacts to cache (${CACHE_DIR}) ==="
                echo "⚡ Cache enabled - artifacts will be reused in next cached build"

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
                expression { buildStages() && params.MEASURE_USB_TIMING }
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
            when {
                expression { buildStages() }
            }
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

                CACHE_MODE="CLEAN BUILD (No cache)"
                if [ "${USE_BUILD_CACHE}" = "true" ]; then
                    CACHE_MODE="⚡ CACHED BUILD (Quick mode)"
                fi

                mkdir -p infrastructure/build-artifacts/out
                {
                    echo "═══════════════════════════════════════════════════════════"
                    echo "           INFRASTRUCTURE BUILD REPORT"
                    echo "═══════════════════════════════════════════════════════════"
                    echo "Build Mode    : ${BUILD_MODE}"
                    echo "Build Branch  : ${BUILD_BRANCH}"
                    echo "Cache Mode    : ${CACHE_MODE}"
                    echo "───────────────────────────────────────────────────────────"
                    echo "Image Build   : $(format_time "$IMG_SECS")"
                    echo "USB Prepare   : $(format_time "$USB_SECS")"
                    echo "═══════════════════════════════════════════════════════════"
                    echo ""
                    echo "📌 For customer KPI reporting, use CLEAN BUILD mode"
                    echo "📌 For development/testing, use CACHED BUILD mode"
                } | tee infrastructure/build-artifacts/out/build-report.txt
                '''
                archiveArtifacts artifacts: 'infrastructure/build-artifacts/out/build-report.txt', allowEmptyArchive: true
            }
        }

        stage('VEN Boot & Test') {
            when {
                expression { buildStages() && params.RUN_VEN_TESTS }
            }
            // This stage only triggers another Jenkins job; no workspace/node is required.
            // Running it without an agent prevents deadlock on single-executor setups.
            agent none
            steps {
                script {
                    def usbArtifacts = "${env.WORKSPACE}/infrastructure/build-artifacts/out/usb-installation-files.tar.gz"
                    echo "Triggering child job asynchronously: enib-ven-test"
                    build job: 'enib-ven-test',
                        parameters: [
                            string(name: 'USB_ARTIFACTS_PATH', value: usbArtifacts),
                            string(name: 'SSH_PORT', value: '2222'),
                            string(name: 'VEN_MEMORY', value: '4G'),
                            string(name: 'VEN_BOOT_TIMEOUT', value: '300')
                        ],
                        wait: false,
                        propagate: false
                    echo "Child job enib-ven-test queued. Parent will finish and release executor."
                }
            }
        }
    }

    post {
        always {
            // Per-host summary for any multi-host phase (flash and/or benchmarks).
            script {
                if (hasHosts() && ((!params.BUILD_ONLY && buildStages()) || runBenchmarks())) {
                    def all = parseHosts().collect { it.ip }
                    def failed = failedHosts as List
                    def ok = all.findAll { !failed.contains(it) }
                    echo "═══════════════════════════════════════════════════════════"
                    echo "  PER-HOST SUMMARY — ${all.size()} host(s)"
                    echo "  Succeeded (${ok.size()}): ${ok.join(', ') ?: '(none)'}"
                    echo "  Failed    (${failed.size()}): ${failed.join(', ') ?: '(none)'}"
                    echo "═══════════════════════════════════════════════════════════"
                }
            }
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
