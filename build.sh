#!/bin/bash
set -e

# ==========================================
# Konoha Kernel Build Script
# Usage: ./build.sh [key=value ...]
#   hz=100|250|1000       Timer frequency (default: 250)
#   hardened=on|off       CPU mitigations (default: off)
#   variant=stock|root|susfs  Build variant (default: stock)
#   root=ksu-next|sukisu|resukisu|mambosu  Root solution (default: ksu-next)
#   kpm=on|off            KPM support (default: off, sukisu/resukisu only)
#   kpm_superkey=STRING   KPM SuperKey (required if kpm=on)
#   kpm_patch=on|off      Inject kpimg with kptools (default: on; resukisu defaults off)
#   lto=thin|full|none    LTO type (default: thin)
#   autofdo=on|off        AutoFDO (default: off)
# ==========================================

VERSION="1.1"

# Parse CLI arguments (key=value)
for arg in "$@"; do
    case "$arg" in
        hz=*)       HZ="${arg#*=}" ;;
        hardened=*) HARDENED="${arg#*=}" ;;
        variant=*)  VARIANT="${arg#*=}" ;;
        root=*)     ROOT="${arg#*=}" ;;
        kpm=*)      KPM="${arg#*=}" ;;
        kpm_superkey=*) KPM_SUPERKEY="${arg#*=}" ;;
        kpm_patch=*) KPM_PATCH="${arg#*=}" ;;
        lto=*)      LTO_TYPE="${arg#*=}" ;;
        autofdo=*)  AUTOFDO="${arg#*=}" ;;
        bypasscharging=*) BYPASSCHARGING="${arg#*=}" ;;
    esac
done

# ==========================================
# Paths
# ==========================================
KERNEL_DIR=$(pwd)
MAIN=$(readlink -f "$KERNEL_DIR/..")
CLANG_DIR="$MAIN/toolchains/clang"
OUT_DIR="$KERNEL_DIR/out"
ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
MODULES_DIR="$KERNEL_DIR/.root_modules"
BUILD_START=$(date +"%s")

# ==========================================
# Interactive Menus (only if not set via CLI/env)
# ==========================================

# 1. Timer Frequency
if [ -z "$HZ" ]; then
    echo "=========================================="
    echo "         Select Timer Frequency           "
    echo "=========================================="
    echo " 1) 100 HZ  (powersave)"
    echo " 2) 250 HZ  (balance - default)"
    echo " 3) 500 HZ  (performance)"
    echo " 4) 1000 HZ (ultra-performance)"
    read -p "Enter choice [1-4] (default 2): " _c
    case "${_c:-2}" in 1) HZ=100 ;; 3) HZ=500 ;; 4) HZ=1000 ;; *) HZ=250 ;; esac
fi

# 2. Hardened Security
if [ -z "$HARDENED" ]; then
    echo "=========================================="
    echo "         Hardened Security Mode           "
    echo "=========================================="
    echo " 1) OFF (default - better performance)"
    echo " 2) ON  (CPU mitigations enabled)"
    read -p "Enter choice [1-2] (default 1): " _c
    [ "${_c:-1}" == "2" ] && HARDENED="on" || HARDENED="off"
fi

# 3. Build Variant
if [ -z "$VARIANT" ]; then
    echo "=========================================="
    echo "          Select Build Variant            "
    echo "=========================================="
    echo " 1) Non-Root (Stock - default)"
    echo " 2) Root Only"
    echo " 3) Root + SUSFS"
    read -p "Enter choice [1-3] (default 1): " _c
    case "${_c:-1}" in 2) VARIANT="root" ;; 3) VARIANT="susfs" ;; *) VARIANT="stock" ;; esac
fi

# 4. Root Solution (only for root/susfs)
if [ "$VARIANT" != "stock" ] && [ -z "$ROOT" ]; then
    echo "=========================================="
    echo "         Select Root Solution             "
    echo "=========================================="
    echo " 1) KernelSU-Next (default)"
    echo " 2) Sukisu"
    echo " 3) ReSukiSU"
    echo " 4) MamboSU"
    echo " 5) APatch (KernelPatch)"
    echo " 6) FolkPatch (KernelPatch)"
    read -p "Enter choice [1-6] (default 1): " _c
    case "${_c:-1}" in 2) ROOT="sukisu" ;; 3) ROOT="resukisu" ;; 4) ROOT="mambosu" ;; 5) ROOT="apatch" ;; 6) ROOT="folkpatch" ;; *) ROOT="ksu-next" ;; esac
fi

# 5. KPM (only for sukisu/resukisu/apatch/folkpatch)
KPM_SUPPORTED_ROOTS="sukisu resukisu apatch folkpatch"
if [ "$VARIANT" != "stock" ] && echo "$KPM_SUPPORTED_ROOTS" | grep -qw "$ROOT"; then
    if [ -z "$KPM" ]; then
        echo "=========================================="
        echo "        KPM (Kernel Patch Module)         "
        echo "=========================================="
        echo " 1) OFF (default - standard root)"
        echo " 2) ON  (enable KPM module support)"
        read -p "Enter choice [1-2] (default 1): " _c
        [ "${_c:-1}" == "2" ] && KPM="on" || KPM="off"
    fi
    if [ "$KPM" == "on" ] && [ -z "$KPM_SUPERKEY" ]; then
        if [ -t 0 ]; then
            read -p "Enter KPM SuperKey (or leave empty to auto-generate): " KPM_SUPERKEY
        fi
        if [ -z "$KPM_SUPERKEY" ]; then
            KPM_SUPERKEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
            echo "[+] Auto-generated SuperKey: $KPM_SUPERKEY"
        fi
    fi
else
    [ "$KPM" == "on" ] && [ "$VARIANT" != "stock" ] && \
        echo "[!] KPM not supported by $ROOT — forcing off"
    KPM="off"
fi

# ReSukiSU + runtime kpimg patch is unstable on some devices.
# Keep KPM compile-time enabled, but default to no post-build injection.
if [ "$KPM" == "on" ] && [ -z "$KPM_PATCH" ]; then
    [ "$ROOT" == "resukisu" ] && KPM_PATCH="off" || KPM_PATCH="on"
fi

# 6. LTO Type
if [ -z "$LTO_TYPE" ]; then
    echo "=========================================="
    echo "           Select LTO Type                "
    echo "=========================================="
    echo " 1) THIN (default - faster build)"
    echo " 2) FULL (slower, slightly better perf)"
    echo " 3) NONE (no LTO)"
    read -p "Enter choice [1-3] (default 1): " _c
    case "${_c:-1}" in 2) LTO_TYPE="full" ;; 3) LTO_TYPE="none" ;; *) LTO_TYPE="thin" ;; esac
fi

# KPM builds are more stable with thin LTO.
if [ "$KPM" == "on" ] && [ "$LTO_TYPE" == "full" ]; then
    echo "[!] KPM with FULL LTO is unstable, forcing LTO=thin"
    LTO_TYPE="thin"
fi
# 7. Bypass Charging
if [ -z "$BYPASSCHARGING" ]; then
    echo "=========================================="
    echo "         Bypass Charging (MCA)            "
    echo "=========================================="
    echo " 1) OFF (default - standard charging)"
    echo " 2) ON  (Override limits / Bypass charging)"
    read -p "Enter choice [1-2] (default 1): " _c
    [ "${_c:-1}" == "2" ] && BYPASSCHARGING="on" || BYPASSCHARGING="off"
fi


# ==========================================
# Resolve Root Solution
# ==========================================
case "$ROOT" in
    sukisu)   ROOT_REPO="https://github.com/sukisu-ultra/sukisu-ultra.git"; REPO_NAME="sukisu-ultra"; BRANCH="main" ;;
    resukisu) ROOT_REPO="https://github.com/ReSukiSU/ReSukiSU.git"; REPO_NAME="ReSukiSU"; BRANCH="main" ;;
    mambosu)  ROOT_REPO="https://github.com/RapliVx/KernelSU.git"; REPO_NAME="MamboSU"; BRANCH="master" ;;
    apatch)   REPO_NAME="APatch" ;;
    folkpatch) REPO_NAME="FolkPatch" ;;
    *)        ROOT_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; REPO_NAME="KernelSU-Next"; BRANCH="dev"; ROOT="ksu-next" ;;
esac

# ==========================================
# Print Config Summary
# ==========================================
echo ""
echo "=========================================="
echo "          Build Configuration             "
echo "=========================================="
echo " Timer:     ${HZ} HZ"
echo " Hardened:  ${HARDENED^^}"
echo " Bypass:    ${BYPASSCHARGING^^}"
[ "$VARIANT" != "stock" ] && echo " Variant:   ${VARIANT} ($REPO_NAME)" || echo " Variant:   stock"
echo " LTO:       ${LTO_TYPE^^}"
if [ "$VARIANT" != "stock" ]; then
    _ROOT_COMMIT=$(git -C "$MODULES_DIR/$REPO_NAME" rev-parse --short HEAD 2>/dev/null || echo "n/a")
    echo " Root:      $REPO_NAME @ $_ROOT_COMMIT"
fi
if [ "$VARIANT" == "susfs" ]; then
    _SUSFS_COMMIT=$(git -C "$MODULES_DIR/susfs4ksu" rev-parse --short HEAD 2>/dev/null || echo "n/a")
    echo " SUSFS:     susfs4ksu @ $_SUSFS_COMMIT"
fi
if [ "$KPM" == "on" ]; then
    echo " KPM:       ENABLED"
    echo " KPM Patch: ${KPM_PATCH^^}"
    echo " SuperKey:  ${KPM_SUPERKEY:0:4}****"
fi
echo "=========================================="
echo ""

# ==========================================
# Prepare Root Module
# ==========================================
rm -rf "$KERNEL_DIR/drivers/kernelsu"
if [ "$VARIANT" == "stock" ]; then
    mkdir -p "$KERNEL_DIR/drivers/kernelsu"
    touch "$KERNEL_DIR/drivers/kernelsu/Kconfig"
    touch "$KERNEL_DIR/drivers/kernelsu/Makefile"
elif [ "$ROOT" == "apatch" ] || [ "$ROOT" == "folkpatch" ]; then
    echo "[+] Using $REPO_NAME (binary patcher) — creating dummy KernelSU module"
    mkdir -p "$KERNEL_DIR/drivers/kernelsu"
    touch "$KERNEL_DIR/drivers/kernelsu/Kconfig"
    touch "$KERNEL_DIR/drivers/kernelsu/Makefile"
    # Force KPM for APatch/FolkPatch
    KPM="on"
else
    mkdir -p "$MODULES_DIR"
    if [ ! -d "$MODULES_DIR/$REPO_NAME" ]; then
        echo "[+] Cloning $REPO_NAME..."
        git clone -b "$BRANCH" "$ROOT_REPO" "$MODULES_DIR/$REPO_NAME"
    else
        echo "[+] Updating $REPO_NAME..."
        (cd "$MODULES_DIR/$REPO_NAME" && git fetch origin && git reset --hard "origin/$BRANCH" || true)
    fi

    # Apply SUSFS
    if [ "$VARIANT" == "susfs" ]; then
        SUSFS_DIR="$MODULES_DIR/susfs4ksu"
        if [ ! -d "$SUSFS_DIR" ]; then
            git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6-dev "$SUSFS_DIR"
        else
            (cd "$SUSFS_DIR" && git fetch origin && git reset --hard origin/gki-android15-6.6-dev || true)
        fi

        # Pin to latest stable SUSFS — includes "Fix possible kernel panic" (1450035)
        (cd "$SUSFS_DIR" && git reset --hard origin/gki-android15-6.6-dev)

        echo "[+] Injecting SUSFS kernel sources..."
        cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c"
        cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h"
        [ -f "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" ] && \
            cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"

        # Fix susfs_def.h: the 6b1badb version uses 'current', 'current_uid()',
        # 'test_ti_thread_flag()', etc. but doesn't include the required headers.
        SUSFS_DEF_H="$KERNEL_DIR/include/linux/susfs_def.h"
        if [ -f "$SUSFS_DEF_H" ] && ! grep -q "linux/sched.h" "$SUSFS_DEF_H" 2>/dev/null; then
            sed -i '/#include <linux\/bits.h>/a\
#include <linux\/sched.h>\
#include <linux\/thread_info.h>\
#include <linux\/cred.h>\
#include <asm\/current.h>' "$SUSFS_DEF_H"
        fi

        if grep -q "config KSU_SUSFS" "$MODULES_DIR/$REPO_NAME/kernel/Kconfig" 2>/dev/null; then
            echo "[+] $REPO_NAME already has native SUSFS integration. Skipping patch..."
        else
            echo "[+] Patching $REPO_NAME for SUSFS..."
            (cd "$MODULES_DIR/$REPO_NAME" && \
             patch -p1 --forward -f --reject-file=- < "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true)
        fi

        # Always run fixup — repairs partial patch failures and adds missing hooks
        # (Moved to after root module preparation)
    fi

    # Some forks (e.g. SukiSU-Ultra) keep UAPI headers outside kernel/.
    # Expose them under kernel/uapi so includes like "uapi/supercall.h" resolve.
    if [ ! -d "$MODULES_DIR/$REPO_NAME/kernel/uapi" ] && [ -d "$MODULES_DIR/$REPO_NAME/uapi" ]; then
        ln -sfn ../uapi "$MODULES_DIR/$REPO_NAME/kernel/uapi"
    fi

    # SukiSU KPM header compatibility fixes
    if [ "$ROOT" == "sukisu" ] && [ "$KPM" == "on" ]; then
        KPM_HEADER="$MODULES_DIR/$REPO_NAME/kernel/kpm/kpm.h"
        KPM_COMPACT="$MODULES_DIR/$REPO_NAME/kernel/kpm/compact.c"
        SUPERCALL_UAPI="$MODULES_DIR/$REPO_NAME/uapi/supercall.h"
        ALLOWLIST_H="$MODULES_DIR/$REPO_NAME/kernel/policy/allowlist.h"
        KSU_KBUILD="$MODULES_DIR/$REPO_NAME/kernel/Kbuild"

        if [ -f "$KPM_HEADER" ] && grep -q '#include "uapi/supercall.h"' "$KPM_HEADER" 2>/dev/null; then
            sed -i 's|#include "uapi/supercall.h"|#include "../../uapi/supercall.h"|' "$KPM_HEADER"
            echo "[+] Patched SukiSU KPM header include path"
        fi
        if [ -f "$SUPERCALL_UAPI" ] && grep -q '#include "uapi/app_profile.h"' "$SUPERCALL_UAPI" 2>/dev/null; then
            sed -i 's|#include "uapi/app_profile.h"|#include "app_profile.h"|' "$SUPERCALL_UAPI"
            echo "[+] Patched SukiSU supercall UAPI include path"
        fi
        if [ -f "$KPM_COMPACT" ] && grep -q '#include "policy/allowlist.h"' "$KPM_COMPACT" 2>/dev/null; then
            sed -i 's|#include "policy/allowlist.h"|#include "../policy/allowlist.h"|' "$KPM_COMPACT"
        fi
        if [ -f "$KPM_COMPACT" ] && grep -q '#include "manager/manager_identity.h"' "$KPM_COMPACT" 2>/dev/null; then
            sed -i 's|#include "manager/manager_identity.h"|#include "../manager/manager_identity.h"|' "$KPM_COMPACT"
        fi
        if [ -f "$ALLOWLIST_H" ] && grep -q '#include "uapi/app_profile.h"' "$ALLOWLIST_H" 2>/dev/null; then
            sed -i 's|#include "uapi/app_profile.h"|#include "../uapi/app_profile.h"|' "$ALLOWLIST_H"
        fi
        if [ -f "$KSU_KBUILD" ] && ! grep -q '\-I$(KSU_KERNEL_DIR)/\.\.' "$KSU_KBUILD" 2>/dev/null; then
            sed -i 's|ccflags-y += -I$(KSU_KERNEL_DIR) -I$(KSU_KERNEL_DIR)/include|ccflags-y += -I$(KSU_KERNEL_DIR) -I$(KSU_KERNEL_DIR)/include -I$(KSU_KERNEL_DIR)/..|' "$KSU_KBUILD"
        fi
        [ -f "$KPM_COMPACT" ] && echo "[+] Patched SukiSU KPM compact include paths"
    fi

    echo "[+] Symlinking $REPO_NAME to drivers/kernelsu..."
    ln -sf "$MODULES_DIR/$REPO_NAME/kernel" "$KERNEL_DIR/drivers/kernelsu"
fi

# Run SUSFS fixup if needed (after root module is symlinked/created)
if [ "$VARIANT" == "susfs" ] && [ "$VARIANT" != "stock" ]; then
    echo "[+] Running SUSFS compatibility fixup ($ROOT)..."
    bash "$KERNEL_DIR/ksu_susfs_fixup.sh" "$KERNEL_DIR/drivers/kernelsu" "$ROOT"
fi

# ==========================================
# KPM Tools Setup (kptools + kpimg)
# ==========================================
if [ "$KPM" == "on" ]; then
    KPM_TOOLS_DIR="$MODULES_DIR/kpm_tools"
    mkdir -p "$KPM_TOOLS_DIR"

    if [ "$ROOT" == "apatch" ] || [ "$ROOT" == "folkpatch" ]; then
        if [ "$ROOT" == "folkpatch" ]; then
            KPM_RELEASE_BASE="https://github.com/LyraVoid/KernelPatch/releases/download/0.13.1"
            KPM_SOURCE_NAME="LyraVoid/KernelPatch (FolkPatch fork) v0.13.1"
            KPIMG_NAME="kpimg-android"
        else
            KPM_RELEASE_BASE="https://github.com/bmax121/KernelPatch/releases/latest/download"
            KPM_SOURCE_NAME="official KernelPatch"
            KPIMG_NAME="kpimg-android"
        fi
    else
        KPM_RELEASE_BASE="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download"
        KPIMG_NAME="kpimg"
        KPM_SOURCE_NAME="SukiSU-Ultra/SukiSU_KernelPatch_patch"
    fi

    KPTOOLS_BIN="$KPM_TOOLS_DIR/kptools-linux"
    KPIMG_BIN="$KPM_TOOLS_DIR/$KPIMG_NAME"

    if [ ! -f "$KPTOOLS_BIN" ] || [ ! -f "$KPIMG_BIN" ]; then
        echo "[+] Downloading KPM tools from $KPM_SOURCE_NAME..."
        
        # Download kptools (use stable 0.13.1 for LyraVoid as latest/C18 lacks linux binary)
        if [ "$ROOT" == "folkpatch" ]; then
            KPTOOLS_URL="https://github.com/LyraVoid/KernelPatch/releases/download/0.13.1/kptools-linux"
        else
            KPTOOLS_URL="$KPM_RELEASE_BASE/kptools-linux"
        fi

        curl -LSs -o "$KPTOOLS_BIN" "$KPTOOLS_URL" || \
            { echo "[-] Failed to download kptools-linux!"; exit 1; }
        
        # Download kpimg
        curl -LSs -o "$KPIMG_BIN" "$KPM_RELEASE_BASE/$KPIMG_NAME" || \
            { echo "[-] Failed to download $KPIMG_NAME!"; exit 1; }
        
        chmod +x "$KPTOOLS_BIN"
    else
        echo "[+] KPM tools already cached"
    fi

    chmod +x "$KPTOOLS_BIN"
    echo "[+] KPM tools ready: $(file -b "$KPTOOLS_BIN" | cut -d, -f1-2)"
fi

# ==========================================
# Toolchain Setup
# ==========================================
check_clang() {
    if [ -n "$CLANG_PATH" ] && [ -f "$CLANG_PATH/bin/clang" ]; then
        export PATH="$CLANG_PATH/bin:$PATH"
        CLANG_BIN="$CLANG_PATH/bin/clang"
    elif [ -d "$CLANG_DIR" ] && [ -f "$CLANG_DIR/bin/clang" ]; then
        export PATH="$CLANG_DIR/bin:$PATH"
        CLANG_BIN="$CLANG_DIR/bin/clang"
    elif command -v clang > /dev/null 2>&1; then
        CLANG_BIN=$(command -v clang)
    else
        return 1
    fi
    COMPILER_VER=$("$CLANG_BIN" --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')
    export KBUILD_COMPILER_STRING="$COMPILER_VER"
    echo "Found Clang: $KBUILD_COMPILER_STRING"
    return 0
}

export ARCH=arm64 SUBARCH=arm64

# Clang optimization
EXTREME_CLANG_FLAGS=(
    -O2
    -mcpu=cortex-x4
    -mtune=cortex-x4
    # -fsplit-machine-functions (causes ld.lld orphaned section errors 'text.split.*')
    -mno-fmv
    -mno-outline-atomics
    -Wno-all
    
    # inline thresholds
    # -mllvm -inline-threshold=200
    # -mllvm -unroll-threshold=75
    # -falign-loops=32
    # -funroll-loops
    # -finline-functions
    -fomit-frame-pointer
    # functions & vectors
    # -ffunction-sections (causes ld.lld orphaned section errors in vmlinux)
    -fslp-vectorize
    # -fdata-sections // error is being placed in '.init.bss.cmdline.o' section, which is not supported by the current linker script
    -fmerge-all-constants
    -fdelete-null-pointer-checks
    -moutline 
    # No safeties (Raw Performance)
    -mharden-sls=none
    -mbranch-protection=none
    -fno-semantic-interposition
    -fno-stack-protector
    -fno-math-errno
    -fno-trapping-math
    -fno-signed-zeros
    -fassociative-math
    -freciprocal-math
    

    # polly flags
    # -Xclang -load -Xclang LLVMPolly.so
    # -mllvm -polly
    # -mllvm -polly-ast-use-context
    # -mllvm -polly-vectorizer=stripmine
    # -mllvm -polly-invariant-load-hoisting
    # -mllvm -polly-enable-simplify
    # -mllvm -polly-reschedule
    # -mllvm -polly-postopts
    # -mllvm -polly-tiling
    # -mllvm -polly-2nd-level-tiling
    # -mllvm -polly-register-tiling
    # -mllvm -polly-pattern-matching-based-opts
    # -mllvm -polly-matmul-opt
    # -mllvm -polly-tc-opt
    # -mllvm -polly-process-unprofitable
)
KERNEL_KCFLAGS="-w ${EXTREME_CLANG_FLAGS[*]}"

# Inject Bypass Charging Macro
if [ "$BYPASSCHARGING" == "on" ]; then
    KERNEL_KCFLAGS="$KERNEL_KCFLAGS -DCONFIG_MCA_BYPASS=1"
fi

KERNEL_LDFLAGS="-O2 --icf=all -mllvm -enable-new-pm=1"

if ! check_clang; then
    echo "[-] No Clang toolchain found!"
    exit 1
fi

# ==========================================
# Kernel Config
# ==========================================
mkdir -p "$OUT_DIR"
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="$KERNEL_KCFLAGS" LDFLAGS="$KERNEL_LDFLAGS" konoha_defconfig || exit 1

# Root config
case "$VARIANT" in
    stock) scripts/config --file "$OUT_DIR/.config" -d CONFIG_KSU -d CONFIG_KSU_SUSFS -d CONFIG_KPM ;;
    root)  scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU -d CONFIG_KSU_SUSFS ;;
    susfs) 
        scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_SUS_MAP
        if [[ "$ROOT" == *"ksu"* ]] || [[ "$ROOT" == *"sukisu"* ]] || [[ "$ROOT" == "mambosu" ]]; then
            scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU
        else
            scripts/config --file "$OUT_DIR/.config" -d CONFIG_KSU
        fi
        ;;
esac

# Root/KPM config
if [ "$ROOT" == "apatch" ] || [ "$ROOT" == "folkpatch" ]; then
    scripts/config --file "$OUT_DIR/.config" -d CONFIG_KSU
    scripts/config --file "$OUT_DIR/.config" -e CONFIG_KPM -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL
elif [ "$KPM" == "on" ]; then
    scripts/config --file "$OUT_DIR/.config" -e CONFIG_KPM -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL
else
    scripts/config --file "$OUT_DIR/.config" -d CONFIG_KPM
fi

# HZ config
case "$HZ" in
    100)  scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_500 -d CONFIG_HZ_1000 -e CONFIG_HZ_100 --set-val CONFIG_HZ 100 -e CONFIG_RCU_LAZY ;;
    500)  scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_100 -d CONFIG_HZ_1000 -e CONFIG_HZ_500 --set-val CONFIG_HZ 500 -d CONFIG_RCU_LAZY ;;
    1000) scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_100 -d CONFIG_HZ_500 -e CONFIG_HZ_1000 --set-val CONFIG_HZ 1000 -d CONFIG_RCU_LAZY ;;
    *)    scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_1000 -d CONFIG_HZ_100 -d CONFIG_HZ_500 -e CONFIG_HZ_250 --set-val CONFIG_HZ 250 ;;
esac

# Hardened config
if [ "$HARDENED" == "off" ]; then
    scripts/config --file "$OUT_DIR/.config" -d CONFIG_CPU_MITIGATIONS -d CONFIG_MITIGATE_SPECTRE_BRANCH_HISTORY
fi

# LTO config
case "$LTO_TYPE" in
    full) scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_NONE -d CONFIG_LTO_CLANG_THIN -e CONFIG_LTO_CLANG -e CONFIG_LTO_CLANG_FULL ;;
    none) scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_CLANG -d CONFIG_LTO_CLANG_FULL -d CONFIG_LTO_CLANG_THIN -e CONFIG_LTO_NONE ;;
    *)    scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_NONE -d CONFIG_LTO_CLANG_FULL -e CONFIG_LTO_CLANG -e CONFIG_LTO_CLANG_THIN ;;
esac

# AutoFDO
AFDO_PROFILE=""
if [ "$AUTOFDO" == "on" ]; then
    scripts/config --file "$OUT_DIR/.config" -e CONFIG_AUTOFDO_CLANG
    AFDO_PROFILE="$KERNEL_DIR/android/gki/aarch64/afdo/kernel.afdo"
    [ ! -f "$AFDO_PROFILE" ] && { echo "[-] AutoFDO profile not found!"; exit 1; }
fi

# Reduce debug overhead for production kernel
# NOTE: Each config was verified against android/abi_gki_aarch64_qcom.
# CONFIG_SCHED_DEBUG and CONFIG_SLUB_DEBUG are NOT disabled — they export
# ABI symbols (sched_feat_keys, get_each_object_track, get_slabinfo).
# CONFIG_KASAN cannot be compiled out — vendor modules depend on
# kasan_flag_enabled. We disable it at runtime via kasan=off cmdline.
echo "=========================================="
echo "[+] Applying debug reduction configs..."
echo "=========================================="
DEBUG_REDUCTION_ARGS=(
    -e CONFIG_DEBUG_INFO_REDUCED
    -d CONFIG_DEBUG_MISC
    -d CONFIG_BT_DEBUGFS
    -d CONFIG_DEBUG_MEMORY_INIT
    -d CONFIG_PROFILING
    -d CONFIG_PRINTK_CALLER
    -d CONFIG_RCU_TRACE
    -d CONFIG_CMA_DEBUGFS
    -d CONFIG_UBSAN -d CONFIG_UBSAN_BOUNDS -d CONFIG_UBSAN_ARRAY_BOUNDS -d CONFIG_UBSAN_LOCAL_BOUNDS -d CONFIG_UBSAN_SANITIZE_ALL -d CONFIG_UBSAN_TRAP
 
    # -d CONFIG_SCHEDSTATS # bootloop

)
scripts/config --file "$OUT_DIR/.config" "${DEBUG_REDUCTION_ARGS[@]}"

# KASAN runtime disable (can't compile out — ABI symbol kasan_flag_enabled)
# Also override bootloader's panic_on_rcu_stall — SUSFS hooks can trigger
# scheduling-while-atomic BUGs that cascade into false RCU stalls.
CURRENT_CMDLINE=$(grep '^CONFIG_CMDLINE=' "$OUT_DIR/.config" | sed 's/^CONFIG_CMDLINE="//' | sed 's/"$//')
CMDLINE_APPEND=""
echo "$CURRENT_CMDLINE" | grep -q "kasan=off" || CMDLINE_APPEND="$CMDLINE_APPEND kasan=off"
echo "$CURRENT_CMDLINE" | grep -q "panic_on_rcu_stall" || CMDLINE_APPEND="$CMDLINE_APPEND kernel.panic_on_rcu_stall=0"
[ -n "$CMDLINE_APPEND" ] && \
    scripts/config --file "$OUT_DIR/.config" --set-str CONFIG_CMDLINE "$CURRENT_CMDLINE$CMDLINE_APPEND"

# Single olddefconfig to finalize all changes
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1

# ==========================================
# Build
# ==========================================
CPUS=$(nproc --all)
MAKE_ARGS=(
    "-j${CPUS}" "O=${OUT_DIR}" "CC=clang" "LD=ld.lld" "AR=llvm-ar" "NM=llvm-nm"
    "OBJCOPY=llvm-objcopy" "OBJDUMP=llvm-objdump" "STRIP=llvm-strip"
    "LLVM=1" "LLVM_IAS=1" "KCFLAGS=${KERNEL_KCFLAGS}" "LDFLAGS=${KERNEL_LDFLAGS}"
)
[ -n "$AFDO_PROFILE" ] && MAKE_ARGS+=("CLANG_AUTOFDO_PROFILE=${AFDO_PROFILE}")

echo "[+] Building with ${CPUS} threads..."
make "${MAKE_ARGS[@]}" || { echo "[-] Build failed!"; exit 1; }

# ==========================================
# KPM Post-Build Patching
# ==========================================
if [ "$KPM" == "on" ]; then
    echo "=========================================="
    echo "[+] Patching kernel Image with KernelPatch..."
    echo "=========================================="

    # kptools operates on the raw (uncompressed) Image
    RAW_IMAGE="$ZIMAGE_DIR/Image"
    if [ ! -f "$RAW_IMAGE" ]; then
        if [ -f "$ZIMAGE_DIR/Image.gz" ]; then
            echo "[+] Decompressing Image.gz for KPM patching..."
            gzip -dk "$ZIMAGE_DIR/Image.gz"
        else
            echo "[-] No kernel Image found for KPM patching!"; exit 1
        fi
    fi

    cp "$RAW_IMAGE" "${RAW_IMAGE}.orig"
    "$KPTOOLS_BIN" -p -i "${RAW_IMAGE}.orig" -S "$KPM_SUPERKEY" -k "$KPIMG_BIN" -o "$RAW_IMAGE"
    KPM_RC=$?
    rm -f "${RAW_IMAGE}.orig"

    if [ $KPM_RC -ne 0 ]; then
        echo "[-] KPM patching failed (exit code: $KPM_RC)!"
        exit 1
    fi

    # Re-compress if the build originally produced Image.gz
    if [ -f "$ZIMAGE_DIR/Image.gz" ]; then
        echo "[+] Re-compressing patched Image → Image.gz"
        gzip -nkf "$RAW_IMAGE"
    fi

    echo "[+] KPM patching successful"
    echo "[+] SuperKey: $KPM_SUPERKEY"
elif [ "$KPM" == "on" ]; then
    echo "[!] KPM runtime patching skipped (kpm_patch=off)"
fi

# ==========================================
# Package
# ==========================================
find "$KERNEL_DIR" -maxdepth 1 -type f -name "Kono-Ha-*.zip" -exec rm -v {} \;
rm -rf "$KERNEL_DIR/Kono-Ha-Release"

TIME=$(date "+%Y%m%d-%H%M%S")
TEMP_DIR="$KERNEL_DIR/anykernel_temp"
rm -rf "$TEMP_DIR"

[ ! -d "$KERNEL_DIR/anykernel" ] && { echo "[-] anykernel directory not found!"; exit 1; }
cp -r "$KERNEL_DIR/anykernel" "$TEMP_DIR"

# Copy kernel image
for img in Image.gz-dtb Image.gz Image; do
    [ -f "$ZIMAGE_DIR/$img" ] && { cp -v "$ZIMAGE_DIR/$img" "$TEMP_DIR/"; break; }
done

# Build filename
ZIP_SUFFIX=""
if [ "$VARIANT" == "stock" ]; then
    ZIP_SUFFIX="-stock"
elif [ "$VARIANT" == "root" ]; then
    ZIP_SUFFIX="-root-$REPO_NAME"
elif [ "$VARIANT" == "susfs" ]; then
    ZIP_SUFFIX="-susfs-$REPO_NAME-v2.1"
fi

[ "$KPM" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-kpm"
[ "$HARDENED" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-hardened"
[ "$BYPASSCHARGING" == "on" ] && ZIP_SUFFIX="${ZIP_SUFFIX}-bypasscharging"

HZ_LABEL=""
case "$HZ" in 100) HZ_LABEL="-powersave" ;; 500) HZ_LABEL="-performance" ;; 1000) HZ_LABEL="-ultra-performance" ;; *) HZ_LABEL="-balance" ;; esac

ZIP_NAME="Kono-Ha-${VERSION}${ZIP_SUFFIX}${HZ_LABEL}-$TIME.zip"
cd "$TEMP_DIR" && zip -r9 "../$ZIP_NAME" * -x .git README.md *placeholder > /dev/null && cd ..
rm -rf "$TEMP_DIR"

# Copy to release dir for CI
mkdir -p "$KERNEL_DIR/Kono-Ha-Release"
cp "$KERNEL_DIR/$ZIP_NAME" "$KERNEL_DIR/Kono-Ha-Release/"

# GitHub Actions outputs
if [ "$GITHUB_ACTIONS" == "true" ]; then
    echo "ZIP_PATH=$KERNEL_DIR/$ZIP_NAME" >> "$GITHUB_ENV"
    echo "ZIP_NAME=$ZIP_NAME" >> "$GITHUB_ENV"
    [ "$KPM" == "on" ] && echo "KPM_SUPERKEY=$KPM_SUPERKEY" >> "$GITHUB_ENV"
fi

BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))
echo -e "\n=========================================="
echo "Build completed in $((DIFF / 60))m $((DIFF % 60))s"
echo "Output: $KERNEL_DIR/$ZIP_NAME"
echo "=========================================="