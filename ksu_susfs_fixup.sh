#!/bin/bash
# ==========================================================================
# SUSFS v2.1 Compatibility Fixup — Dynamic Multi-Manager Support
# ==========================================================================
# Surgically repairs SUSFS integration after 10_enable_susfs_for_ksu.patch
# which may partially fail on different KernelSU forks.
#
# Supported managers: KernelSU-Next, Sukisu-Ultra, MamboSU
# (ReSukiSU has native SUSFS — should be skipped upstream in build.sh)
#
# Usage: ksu_susfs_fixup.sh <path-to-ksu/kernel> [manager-name]
#   manager-name: ksu-next | sukisu | mambosu (auto-detected if omitted)
# ==========================================================================
set -e

KSU_KERNEL="$1"
MANAGER_HINT="$2"

if [ -z "$KSU_KERNEL" ] || [ ! -d "$KSU_KERNEL" ]; then
    echo "Usage: $0 <path-to-ksu/kernel> [ksu-next|sukisu|mambosu]"
    exit 1
fi

# ==========================================================================
# Manager Detection
# ==========================================================================
detect_manager() {
    local kdir="$1"
    local hint="$2"
    local parent
    parent=$(dirname "$kdir")

    if [ -n "$hint" ]; then
        case "$hint" in
            ksu-next)  echo "ksu-next" ;;
            sukisu)    echo "sukisu" ;;
            resukisu)  echo "resukisu" ;;
            mambosu)   echo "mambosu" ;;
            apatch)    echo "apatch" ;;
            folkpatch) echo "folkpatch" ;;
            *)         echo "unknown" ;;
        esac
        return
    fi

    if [ -f "$parent/.git/config" ]; then
        local url
        url=$(git -C "$parent" remote get-url origin 2>/dev/null || true)
        case "$url" in
            *KernelSU-Next*|*kernelsu-next*) echo "ksu-next"; return ;;
            *sukisu*|*SukiSU*|*Sukisu*)      echo "sukisu"; return ;;
            *ReSukiSU*|*resukisu*)           echo "resukisu"; return ;;
            *RapliVx*|*MamboSU*|*mambosu*)   echo "mambosu"; return ;;
        esac
    fi

    if [ -f "$kdir/feature/adb_root.c" ]; then
        if grep -q "sulog_init_heap" "$kdir/supercall/supercall.c" 2>/dev/null; then
            echo "mambosu"; return
        fi
        echo "sukisu"; return
    fi

    if [ -f "$kdir/hook/syscall_event_bridge.c" ] && \
       grep -q "KernelSU-Next" "$kdir/Kbuild" 2>/dev/null; then
        echo "ksu-next"; return
    fi

    echo "unknown"
}

MANAGER=$(detect_manager "$KSU_KERNEL" "$MANAGER_HINT")
echo "[SUSFS-Fixup] Manager: $MANAGER"

if [ "$MANAGER" = "resukisu" ]; then
    echo "[SUSFS-Fixup] ReSukiSU has native SUSFS — applying typo fix."
    if [ -f "$KSU_KERNEL/runtime/ksud_integration.c" ]; then
        sed -i 's/ksu_init_rc_hook_key_false/ksu_is_init_rc_hook_enabled/g' "$KSU_KERNEL/runtime/ksud_integration.c"
    fi
    # [GLOBAL] fs/susfs.c — make loop call non-static for compatibility
    if [ -f "$(dirname "$0")/fs/susfs.c" ]; then
        sed -i 's/static void susfs_run_sus_path_loop(void)/void susfs_run_sus_path_loop(void)/g' "$(dirname "$0")/fs/susfs.c"
        echo "[SUSFS-Fixup] fs/susfs.c: Made susfs_run_sus_path_loop non-static"
    fi
    # [FIX] selinux_hide.c — remove undefined context_struct_compute_av_fn extern
    # The kernel's context_struct_compute_av in security/selinux/ss/services.c is
    # static and not exported. selinux_hide.c has its own local copy, so remove
    # the extern reference and always use the local implementation.
    SELINUX_HIDE_C="$KSU_KERNEL/feature/selinux_hide.c"
    if [ -f "$SELINUX_HIDE_C" ] && grep -q "context_struct_compute_av_fn" "$SELINUX_HIDE_C" 2>/dev/null; then
        # Remove the extern declaration
        sed -i '/^extern void context_struct_compute_av_fn/,/struct extended_perms \*xperms);/d' "$SELINUX_HIDE_C"
        # Replace conditional call with direct call to local function
        sed -i '/if (context_struct_compute_av_fn) {/{
            N;N;N;N
            s/if (context_struct_compute_av_fn) {\n.*context_struct_compute_av_fn.*\n.*} else {\n.*context_struct_compute_av(.*\n.*}/context_struct_compute_av(policydb, scontext, tcontext, tclass, avd, NULL);/
        }' "$SELINUX_HIDE_C"
        echo "[SUSFS-Fixup] selinux_hide.c: Removed undefined context_struct_compute_av_fn"
    fi
    exit 0
fi

# ==========================================================================
# [GLOBAL] fs/susfs.c — make loop call non-static for compatibility
# ==========================================================================
if [ -f "$(dirname "$0")/fs/susfs.c" ]; then
    sed -i 's/static void susfs_run_sus_path_loop(void)/void susfs_run_sus_path_loop(void)/g' "$(dirname "$0")/fs/susfs.c"
    echo "[SUSFS-Fixup] fs/susfs.c: Made susfs_run_sus_path_loop non-static"
fi

# ==========================================================================
# Path Resolution (all supported managers use NEW layout with core/)
# ==========================================================================
KBUILD="$KSU_KERNEL/Kbuild"
MAKEFILE_KSU="$KSU_KERNEL/Makefile"
INIT_C="$KSU_KERNEL/core/init.c"
SUCOMPAT_C="$KSU_KERNEL/feature/sucompat.c"
SUCOMPAT_H="$KSU_KERNEL/feature/sucompat.h"
SETUID_HOOK_C="$KSU_KERNEL/hook/setuid_hook.c"
BRIDGE_C="$KSU_KERNEL/hook/syscall_event_bridge.c"
SUPERCALL_C="$KSU_KERNEL/supercall/supercall.c"
SUPERCALL_H="$KSU_KERNEL/supercall/supercall.h"
DISPATCH_C="$KSU_KERNEL/supercall/dispatch.c"
KSUD_H="$KSU_KERNEL/runtime/ksud.h"
KSUD_INT_C="$KSU_KERNEL/runtime/ksud_integration.c"
APP_PROFILE_C="$KSU_KERNEL/policy/app_profile.c"
KSU_H="$KSU_KERNEL/include/ksu.h"
RULES_C="$KSU_KERNEL/selinux/rules.c"
SELINUX_H="$KSU_KERNEL/selinux/selinux.h"
SULOG_EVENT_H="$KSU_KERNEL/sulog/event.h"
SULOG_EVENT_C="$KSU_KERNEL/sulog/event.c"
KERNEL_UMOUNT_C="$KSU_KERNEL/feature/kernel_umount.c"

echo "[SUSFS-Fixup] Starting compatibility fixups..."

# ==========================================================================
# Helper: safely insert a line after a pattern (idempotent)
# ==========================================================================
insert_after() {
    local file="$1" pattern="$2" line="$3"
    [ -f "$file" ] || return 0
    grep -qF "$line" "$file" 2>/dev/null && return 0
    sed -i "/${pattern}/a\\${line}" "$file" 2>/dev/null || true
}

# ==========================================================================
# [SHARED] Makefile — SUSFS version detection
# ==========================================================================
if [ -f "$MAKEFILE_KSU" ] && ! grep -q "SUSFS_VERSION" "$MAKEFILE_KSU" 2>/dev/null; then
    cat >> "$MAKEFILE_KSU" << 'MKEOF'

## For susfs stuff ##
ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
$(info )
$(info -- SUSFS_VERSION: $(SUSFS_VERSION))
else
$(info -- You have not integrated susfs in your kernel yet.)
endif
MKEOF
    echo "[SUSFS-Fixup] Makefile: Added SUSFS version detection"
fi

# ==========================================================================
# [SHARED] core/init.c — susfs include + init call
# ==========================================================================
if [ -f "$INIT_C" ]; then
    if ! grep -q "linux/susfs.h" "$INIT_C" 2>/dev/null; then
        # Try multiple anchor points for robustness
        sed -i '/#include <linux\/workqueue.h>/a #include <linux/susfs.h>' "$INIT_C" 2>/dev/null || \
        sed -i '/#include <linux\/moduleparam.h>/a #include <linux/susfs.h>' "$INIT_C" 2>/dev/null || \
        sed -i '0,/#include.*<linux\//{/#include.*<linux\//a #include <linux/susfs.h>
        }' "$INIT_C" 2>/dev/null || true
    fi
    if ! grep -q "susfs_init()" "$INIT_C" 2>/dev/null; then
        sed -i '/ksu_file_wrapper_init/a\\n\tsusfs_init();' "$INIT_C" 2>/dev/null || true
    fi
    echo "[SUSFS-Fixup] init.c: OK"
fi

# ==========================================================================
# [SHARED] selinux/rules.c — susfs SID init calls
# ==========================================================================
if [ -f "$RULES_C" ] && ! grep -q "susfs_set_zygote_sid" "$RULES_C" 2>/dev/null; then
    if grep -q "susfs_set_batch_sid" "$RULES_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] selinux/rules.c: Using modern susfs_set_batch_sid"
    else
        if [ -f "$SELINUX_H" ]; then
            for fn in susfs_set_init_sid susfs_set_ksu_sid susfs_set_zygote_sid; do
                grep -q "$fn" "$SELINUX_H" 2>/dev/null || \
                    sed -i "/^#endif/i void ${fn}(void);" "$SELINUX_H"
            done
        fi
        if grep -q "reset_avc_cache();" "$RULES_C" 2>/dev/null; then
            sed -i 's/^[ \t]*reset_avc_cache();/\tsusfs_set_init_sid();\n\tsusfs_set_ksu_sid();\n\tsusfs_set_zygote_sid();\n\treset_avc_cache();/' "$RULES_C"
        fi
        echo "[SUSFS-Fixup] selinux/rules.c: OK"
    fi
fi

# ==========================================================================
# [SHARED] setuid_hook.c — do_umount label
# ==========================================================================
if [ -f "$SETUID_HOOK_C" ] && grep -q "goto do_umount;" "$SETUID_HOOK_C" 2>/dev/null; then
    if ! grep -q "do_umount:" "$SETUID_HOOK_C" 2>/dev/null; then
        sed -i '/ksu_handle_umount/i\\ndo_umount:' "$SETUID_HOOK_C"
        echo "[SUSFS-Fixup] setuid_hook.c: Added do_umount label"
    fi
fi

# ==========================================================================
# [SHARED] Remove dead symbol references when objects are not compiled
# ==========================================================================
APP_PROFILE_C="$KSU_KERNEL/policy/app_profile.c"
if [ -f "$KBUILD" ] && [ -f "$APP_PROFILE_C" ]; then
    if ! grep -q "tp_marker.o" "$KBUILD" 2>/dev/null; then
        if grep -q "ksu_set_task_tracepoint_flag\|ksu_clear_task_tracepoint_flag" "$APP_PROFILE_C" 2>/dev/null; then
            sed -i '/ksu_set_task_tracepoint_flag/d' "$APP_PROFILE_C"
            sed -i '/ksu_clear_task_tracepoint_flag/d' "$APP_PROFILE_C"
            echo "[SUSFS-Fixup] app_profile.c: Removed tracepoint calls (tp_marker.o not compiled)"
        fi
    fi
fi

# ==========================================================================
# [SHARED] sucompat.h — Complete rebuild to clean state
# ==========================================================================
rebuild_sucompat_h() {
    [ -f "$SUCOMPAT_H" ] || return 0

    # Detect which functions exist in sucompat.c to declare them correctly
    local has_execve_sucompat=0 has_execveat_sucompat=0
    if [ -f "$SUCOMPAT_C" ]; then
        grep -q "ksu_handle_execve_sucompat" "$SUCOMPAT_C" 2>/dev/null && has_execve_sucompat=1
        grep -q "ksu_handle_execveat_sucompat" "$SUCOMPAT_C" 2>/dev/null && has_execveat_sucompat=1
    fi

    # Detect if sucompat.c uses DEFINE_STATIC_KEY_TRUE or plain bool
    local use_static_key=0
    if [ -f "$SUCOMPAT_C" ]; then
        grep -q 'DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled)' "$SUCOMPAT_C" 2>/dev/null && use_static_key=1
    fi

    if [ "$use_static_key" -eq 1 ]; then
        cat > "$SUCOMPAT_H" << 'SUCOMPAT_H_EOF'
#ifndef __KSU_H_SUCOMPAT
#define __KSU_H_SUCOMPAT
#include <asm/ptrace.h>
#include <linux/types.h>
#include <linux/version.h>
#include <linux/jump_label.h>

extern struct static_key_true ksu_su_compat_enabled;

void ksu_sucompat_init(void);
void ksu_sucompat_exit(void);

int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
int ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags);
#else
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#define ksu_handle_stat_user ksu_handle_stat
#endif
SUCOMPAT_H_EOF
    else
        cat > "$SUCOMPAT_H" << 'SUCOMPAT_H_EOF'
#ifndef __KSU_H_SUCOMPAT
#define __KSU_H_SUCOMPAT
#include <asm/ptrace.h>
#include <linux/types.h>
#include <linux/version.h>

extern bool ksu_su_compat_enabled;

void ksu_sucompat_init(void);
void ksu_sucompat_exit(void);

int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
int ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags);
#else
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#define ksu_handle_stat_user ksu_handle_stat
#endif
SUCOMPAT_H_EOF
    fi

    # Add the correct execve function declarations
    if [ "$has_execve_sucompat" -eq 1 ]; then
        cat >> "$SUCOMPAT_H" << 'EOF'

#ifndef CONFIG_KSU_SUSFS
long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, const struct pt_regs *regs);
#endif
EOF
    fi

    # Add SUSFS declarations
    cat >> "$SUCOMPAT_H" << 'EOF'

#ifdef CONFIG_KSU_SUSFS
#include <linux/fs.h>
struct user_arg_ptr;
int ksu_handle_execveat_init(struct filename *filename,
    struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user);
int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
    void *argv_user, void *envp_user, int *__never_use_flags);
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
    void *envp, int *flags);
#endif

#endif /* __KSU_H_SUCOMPAT */
EOF

    echo "[SUSFS-Fixup] sucompat.h: Rebuilt clean"
}
rebuild_sucompat_h

# ==========================================================================
# [SHARED] sucompat.c — ksu_handle_stat version gate + ksu_handle_execveat_init
# ==========================================================================
if [ -f "$SUCOMPAT_C" ]; then
    # Ensure susfs_def.h include
    if ! grep -q "linux/susfs_def.h" "$SUCOMPAT_C" 2>/dev/null; then
        sed -i '1,/#include/{/#include/a #include <linux/susfs_def.h>
        }' "$SUCOMPAT_C" 2>/dev/null || true
    fi

    # Fix ksu_handle_stat for kernel >= 6.1 if not already version-gated
    if grep -q "int ksu_handle_stat(int \*dfd, const char __user \*\*filename_user, int \*flags)" "$SUCOMPAT_C" 2>/dev/null && \
       ! grep -q "KERNEL_VERSION(6, 1, 0)" "$SUCOMPAT_C" 2>/dev/null; then
        sed -i '/^int ksu_handle_stat(int \*dfd, const char __user \*\*filename_user, int \*flags)/c\
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)\
{\
    if (unlikely(IS_ERR(*filename) || (*filename)->name == NULL)) return 0;\
    if (likely(memcmp((*filename)->name, "/system/bin/su", 15))) return 0;\
    pr_info("ksu_handle_stat: su->sh!\\n");\
    memcpy((void *)((*filename)->name), "/system/bin/sh", 15);\
    return 0;\
}\
int ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags)\
#else\
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)\
#endif' "$SUCOMPAT_C"
        # We don't need the #endif at the end of the function anymore, because the #else/#endif wraps the function signature only.
        # However, the previous script might have already added #endif at the end of the function if it ran before.
        # But we are assuming a clean run of the script.
        echo "[SUSFS-Fixup] sucompat.c: Fixed ksu_handle_stat version gate"
    fi

    # Add ksu_handle_execveat_init if missing
    if ! grep -q "ksu_handle_execveat_init" "$SUCOMPAT_C" 2>/dev/null; then
        cat >> "$SUCOMPAT_C" << 'EXECVEAT_EOF'

#ifdef CONFIG_KSU_SUSFS
int ksu_handle_execveat_init(struct filename *filename,
    struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    if (current->pid != 1 && is_init(get_current_cred())) {
        if (unlikely(strcmp(filename->name, KSUD_PATH) == 0)) {
            pr_info("hook_manager: escape to root for init executing ksud: %d\n", current->pid);
            escape_to_root_for_init();
            return 0;
        } else if (likely(strstr(filename->name, "/app_process") == NULL &&
                    strstr(filename->name, "/adbd") == NULL) &&
                    !susfs_is_current_proc_umounted())
        {
            pr_info("susfs: mark no sucompat checks for pid: '%d', exec: '%s'\n",
                current->pid, filename->name);
            susfs_set_current_proc_umounted();
            return 0;
        }
        return 0;
    }
    return -EINVAL;
}
#endif /* CONFIG_KSU_SUSFS */
EXECVEAT_EOF
        echo "[SUSFS-Fixup] sucompat.c: Added ksu_handle_execveat_init"
    fi
fi

# ==========================================================================
# [MANAGER-SPECIFIC] Fixes per kernel manager
# ==========================================================================

# --------------------------------------------------------------------------
# MamboSU / Sukisu-Ultra: kprobe-based reboot interception needs SUSFS forwarding
# --------------------------------------------------------------------------
fix_kprobe_supercall() {
    if [ ! -f "$SUPERCALL_C" ]; then return; fi

    # Only applies if supercall.c still has a kprobe handler
    if ! grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then return; fi

    # Check if dispatch.c has SUSFS handling (patch succeeded for dispatch.c)
    if ! grep -q "SUSFS_MAGIC" "$DISPATCH_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] WARNING: dispatch.c missing SUSFS handler — cannot bridge"
        return
    fi

    # SUSFS supercalls are handled by kernel/reboot.c → dispatch.c's
    # ksu_handle_sys_reboot() in normal syscall context. No kprobe bridge needed.

    # NOTE: We do NOT add SUSFS dispatch to the kprobe handler.
    # kprobe pre-handlers run with preemption disabled (atomic context).
    # SUSFS dispatch calls mutex_lock/copy_from_user/kzalloc(GFP_KERNEL)
    # which sleep → BUG: scheduling while atomic.
    # Instead, kernel/reboot.c already has a direct call to
    # ksu_handle_sys_reboot() in normal syscall context which handles SUSFS.

    # Remove any previously-injected kprobe SUSFS bridge (from older fixup)
    if grep -q "ksu_susfs_dispatch_reboot" "$SUPERCALL_C" 2>/dev/null; then
        sed -i '/#ifdef CONFIG_KSU_SUSFS/{
            N;N;N;N;N;N
            /ksu_susfs_dispatch_reboot/d
        }' "$SUPERCALL_C"
        sed -i '/ksu_susfs_dispatch_reboot/d' "$SUPERCALL_C"
        sed -i '/^#ifdef CONFIG_KSU_SUSFS$/{N;/^#ifdef CONFIG_KSU_SUSFS\n#endif$/d}' "$SUPERCALL_C"
        echo "[SUSFS-Fixup] supercall.c: Removed kprobe SUSFS bridge (atomic context unsafe)"
    fi

    # Step 3: Add ksu_supercall_reboot_handler if missing (dispatch.c needs it)
    if ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_C" 2>/dev/null; then
        cat >> "$SUPERCALL_C" << 'REBOOT_HANDLER_EOF'

int ksu_supercall_reboot_handler(void __user **arg)
{
    struct ksu_install_fd_tw *tw;
    tw = kzalloc(sizeof(*tw), GFP_KERNEL);
    if (!tw) return 0;
    tw->outp = (int __user *)(*arg);
    tw->cb.func = ksu_install_fd_tw_func;
    if (task_work_add(current, &tw->cb, TWA_RESUME)) {
        kfree(tw);
        pr_warn("install fd add task_work failed\n");
    }
    return 0;
}
REBOOT_HANDLER_EOF
        echo "[SUSFS-Fixup] supercall.c: Added ksu_supercall_reboot_handler"
    fi

    if [ -f "$SUPERCALL_H" ] && ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_H" 2>/dev/null; then
        sed -i '/ksu_install_fd/a int ksu_supercall_reboot_handler(void __user **arg);' "$SUPERCALL_H" 2>/dev/null || \
        sed -i '/ksu_supercalls_init/i int ksu_supercall_reboot_handler(void __user **arg);' "$SUPERCALL_H" 2>/dev/null || true
    fi
}

# --------------------------------------------------------------------------
# MamboSU / Sukisu-Ultra: Fix sulog type mismatch in ksu_handle_execve_sucompat
# --------------------------------------------------------------------------
fix_sulog_type_mismatch() {
    if [ ! -f "$SUCOMPAT_C" ]; then return; fi

    # The SUSFS patch changes sulog/event.h to expect struct user_arg_ptr *
    # but the old ksu_handle_execve_sucompat passes raw const char __user *const __user *
    if [ -f "$SULOG_EVENT_H" ] && grep -q "struct user_arg_ptr \*argv_user" "$SULOG_EVENT_H" 2>/dev/null; then
        # Check if sucompat.c still has the old-style call
        if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user' "$SUCOMPAT_C" 2>/dev/null; then
            # The function has: const char __user *const __user *argv_user = ...
            # We need to wrap it in struct user_arg_ptr before passing to ksu_sulog_capture_sucompat
            sed -i '/pending_sucompat = ksu_sulog_capture_sucompat(\*filename_user, argv_user/c\
    {\
        struct user_arg_ptr _argv_wrap = { .ptr.native = argv_user };\
        pending_sucompat = ksu_sulog_capture_sucompat(*filename_user, \&_argv_wrap, GFP_KERNEL);\
    }' "$SUCOMPAT_C"
            echo "[SUSFS-Fixup] sucompat.c: Fixed sulog argv_user type mismatch"
        fi
    fi
}

# --------------------------------------------------------------------------
# MamboSU / Sukisu-Ultra: Add ksu_handle_execveat_sucompat + ksu_handle_execveat
# and guard old ksu_handle_execve_sucompat from ksu_syscall_table dependency
# --------------------------------------------------------------------------
fix_execveat_handlers() {
    if [ ! -f "$SUCOMPAT_C" ]; then return; fi

    # Guard old ksu_handle_execve_sucompat with #ifndef CONFIG_KSU_SUSFS
    # (it uses ksu_syscall_table from syscall_hook_manager.c which is not compiled)
    if [ "$MANAGER" != "ksu-next" ] && [ "$MANAGER" != "mambosu" ] && grep -q "ksu_handle_execve_sucompat" "$SUCOMPAT_C" 2>/dev/null && \
       grep -q "ksu_syscall_table" "$SUCOMPAT_C" 2>/dev/null && \
       ! grep -q '#ifndef CONFIG_KSU_SUSFS' "$SUCOMPAT_C" 2>/dev/null; then

        sed -i '/^long ksu_handle_execve_sucompat/i\
#ifndef CONFIG_KSU_SUSFS' "$SUCOMPAT_C"

        # Find the closing brace of ksu_handle_execve_sucompat
        local funcstart
        funcstart=$(grep -n "^long ksu_handle_execve_sucompat" "$SUCOMPAT_C" | head -1 | cut -d: -f1)
        if [ -n "$funcstart" ]; then
            # Find the next line that has "^}" after the function start
            local funcend
            funcend=$(awk -v s="$funcstart" 'NR>s && /^}/{print NR; exit}' "$SUCOMPAT_C")
            if [ -n "$funcend" ]; then
                sed -i "${funcend}a\\#endif /* !CONFIG_KSU_SUSFS */" "$SUCOMPAT_C"
            fi
        fi
        echo "[SUSFS-Fixup] sucompat.c: Guarded old ksu_handle_execve_sucompat"
    fi

    # Add ksu_handle_execveat_sucompat + ksu_handle_execveat if missing
    if ! grep -q "ksu_handle_execveat_sucompat" "$SUCOMPAT_C" 2>/dev/null; then
        cat >> "$SUCOMPAT_C" << 'EXECVEAT_SUCOMPAT_EOF'

#ifdef CONFIG_KSU_SUSFS
static const char _su_path[] = "/system/bin/su";
static const char _sh_path[] = "/system/bin/sh";
static const char _ksud_path[] = KSUD_PATH;

int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                 void *argv_user, void *envp_user,
                 int *__never_use_flags)
{
    struct filename *filename;
    int ret;

    if (unlikely(!filename_ptr))
        return 0;

    filename = *filename_ptr;
    if (IS_ERR(filename))
        return 0;

    if (!ksu_handle_execveat_init(filename,
            (struct user_arg_ptr *)argv_user,
            (struct user_arg_ptr *)envp_user))
        return 0;

    if (likely(memcmp(filename->name, _su_path, sizeof(_su_path))))
        return 0;

    if (!ksu_is_allow_uid_for_current(current_uid().val))
        return 0;

    pr_info("ksu_handle_execveat_sucompat: su found\n");
    memcpy((void *)filename->name, _ksud_path, sizeof(_ksud_path));

    ret = escape_with_root_profile();
    if (ret)
        pr_err("escape_with_root_profile() failed: %d\n", ret);

    return 0;
}

int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
            void *envp, int *flags)
{
    if (ksu_handle_execveat_ksud(fd, filename_ptr, argv, envp, flags))
        return 0;
    return ksu_handle_execveat_sucompat(fd, filename_ptr, argv, envp, flags);
}
#endif /* CONFIG_KSU_SUSFS */
EXECVEAT_SUCOMPAT_EOF
        echo "[SUSFS-Fixup] sucompat.c: Added ksu_handle_execveat_sucompat + ksu_handle_execveat"
    fi
}

# --------------------------------------------------------------------------
# KernelSU-Next: Restore hook objects removed by patch, fix bridge
# --------------------------------------------------------------------------
fix_ksu_next_kbuild() {
    if [ ! -f "$KBUILD" ]; then return; fi

    # The SUSFS patch removes lsm_hook, syscall_event_bridge, tp_marker, etc.
    # KernelSU-Next needs them. Restore if missing.
    local need_restore=0

    for obj in "hook/lsm_hook.o" "hook/syscall_event_bridge.o" "hook/syscall_hook_manager.o" "hook/tp_marker.o" "infra/symbol_resolver.o"; do
        local src_file="$KSU_KERNEL/$(echo $obj | sed 's/\.o$/.c/')"
        if [ -f "$src_file" ] && ! grep -q "$obj" "$KBUILD" 2>/dev/null; then
            need_restore=1
            break
        fi
    done

    if [ "$need_restore" -eq 1 ]; then
        # Insert after hook/setuid_hook.o
        if ! grep -q "hook/lsm_hook.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/hook/lsm_hook.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/lsm_hook.o' "$KBUILD"
        fi
        if ! grep -q "hook/syscall_event_bridge.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/hook/syscall_event_bridge.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/syscall_event_bridge.o' "$KBUILD"
        fi
        if ! grep -q "hook/syscall_hook_manager.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/hook/syscall_hook_manager.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/syscall_hook_manager.o' "$KBUILD"
        fi
        if ! grep -q "hook/tp_marker.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/hook/tp_marker.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/tp_marker.o' "$KBUILD"
        fi
        if ! grep -q "infra/symbol_resolver.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/infra/symbol_resolver.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += infra/symbol_resolver.o' "$KBUILD"
        fi
        # Arch-specific patch memory and syscall hook
        if ! grep -q "hook/arm64/patch_memory.o" "$KBUILD" 2>/dev/null && [ -d "$KSU_KERNEL/hook/arm64" ]; then
            sed -i '/hook\/tp_marker.o/a\
ifeq ($(CONFIG_ARM64),y)\
kernelsu-objs += hook/arm64/patch_memory.o\
kernelsu-objs += hook/arm64/syscall_hook.o\
else ifeq ($(CONFIG_X86_64),y)\
kernelsu-objs += hook/x86_64/patch_memory.o\
kernelsu-objs += hook/x86_64/syscall_hook.o\
endif' "$KBUILD"
        fi
        echo "[SUSFS-Fixup] Kbuild: Restored hook objects for $MANAGER"
    fi
}

# --------------------------------------------------------------------------
# KernelSU-Next: syscall_event_bridge.c setresuid fix
# --------------------------------------------------------------------------
fix_ksu_next_bridge() {
    if [ ! -f "$BRIDGE_C" ]; then return; fi

    if grep -q "ksu_handle_setresuid(old_uid, current_uid().val)" "$BRIDGE_C" 2>/dev/null; then
        sed -i 's/ksu_handle_setresuid(old_uid, current_uid()\.val);/{\
        uid_t ruid = PT_REGS_PARM1(regs);\
        uid_t euid = PT_REGS_PARM2(regs);\
        uid_t suid = PT_REGS_PARM3(regs);\
        ksu_handle_setresuid(ruid, euid, suid);\
    }/' "$BRIDGE_C"
        echo "[SUSFS-Fixup] syscall_event_bridge.c: Fixed setresuid 3-arg"
    fi

    # Fix ksu_handle_stat call signature for KernelSU-Next tracepoints
    # We renamed it to ksu_handle_stat_user to avoid colliding with VFS hook signature.
    if grep -q "ksu_handle_stat(dfd, filename_user, flags);" "$BRIDGE_C" 2>/dev/null; then
        sed -i 's|ksu_handle_stat(dfd, filename_user, flags);|ksu_handle_stat_user(dfd, filename_user, flags);|' "$BRIDGE_C"
        echo "[SUSFS-Fixup] syscall_event_bridge.c: Renamed ksu_handle_stat to ksu_handle_stat_user"
    fi

    # tp_marker.h include
    if [ -f "$SETUID_HOOK_C" ] && grep -q "ksu_set_task_tracepoint_flag" "$SETUID_HOOK_C" 2>/dev/null; then
        if ! grep -q "hook/tp_marker.h" "$SETUID_HOOK_C" 2>/dev/null; then
            sed -i '/#include "hook\/setuid_hook.h"/a #include "hook/tp_marker.h"' "$SETUID_HOOK_C"
        fi
    fi
}

# --------------------------------------------------------------------------
# KernelSU-Next: supercall.c reboot handler (kprobe-free architecture)
# --------------------------------------------------------------------------
fix_ksu_next_supercall() {
    if [ ! -f "$SUPERCALL_C" ]; then return; fi

    # KernelSU-Next's SUSFS patch replaces kprobe with direct dispatch
    # If supercall.c still has kprobe, the patch failed — apply manually
    if grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then
        # kprobe still present = supercall.c patch failed
        # For KSU-Next, the bridge approach also works
        fix_kprobe_supercall
        return
    fi

    # Patch succeeded but ksu_supercall_reboot_handler may be missing
    if ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_C" 2>/dev/null; then
        cat >> "$SUPERCALL_C" << 'SUPERCALL_NEXT_EOF'

int ksu_supercall_reboot_handler(void __user **arg)
{
    struct ksu_install_fd_tw *tw;
    tw = kzalloc(sizeof(*tw), GFP_KERNEL);
    if (!tw) return 0;
    tw->outp = (int __user *)(*arg);
    tw->cb.func = ksu_install_fd_tw_func;
    if (task_work_add(current, &tw->cb, TWA_RESUME)) {
        kfree(tw);
        pr_warn("install fd add task_work failed\n");
    }
    return 0;
}
SUPERCALL_NEXT_EOF
        echo "[SUSFS-Fixup] supercall.c: Added ksu_supercall_reboot_handler"
    fi

    if [ -f "$SUPERCALL_H" ] && ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_H" 2>/dev/null; then
        sed -i '/ksu_install_fd/a int ksu_supercall_reboot_handler(void __user **arg);' "$SUPERCALL_H" 2>/dev/null || true
    fi
}

# --------------------------------------------------------------------------
# KernelSU-Next: ksud compatibility wrappers
# --------------------------------------------------------------------------
fix_ksu_next_ksud() {
    if [ ! -f "$KSUD_INT_C" ]; then return; fi

    # Fix extern → include for ksu_handle_execveat_init
    if grep -q "extern int ksu_handle_execveat_init" "$KSUD_INT_C" 2>/dev/null; then
        if ! grep -q "feature/sucompat.h" "$KSUD_INT_C" 2>/dev/null; then
            sed -i '/#include "selinux\/selinux.h"/a #include "feature/sucompat.h"' "$KSUD_INT_C"
        fi
        sed -i '/^extern int ksu_handle_execveat_init/d' "$KSUD_INT_C"
    fi

    # ksu_execve_hook_ksud wrapper (needed by syscall_event_bridge.c)
    if grep -q "syscall_event_bridge.o" "$KBUILD" 2>/dev/null && \
       ! grep -q "ksu_execve_hook_ksud" "$KSUD_INT_C" 2>/dev/null; then
        if [ -f "$KSUD_H" ] && ! grep -q "ksu_execve_hook_ksud" "$KSUD_H" 2>/dev/null; then
            if grep -q "ksu_handle_execveat_ksud" "$KSUD_H" 2>/dev/null; then
                sed -i '/ksu_handle_execveat_ksud/,/;/{/;/a\
\
void ksu_execve_hook_ksud(const struct pt_regs *regs);\
void ksu_stop_input_hook_runtime(void);
}' "$KSUD_H"
            fi
        fi

        cat >> "$KSUD_INT_C" << 'KSUD_COMPAT_EOF'

extern void ksu_stop_ksud_execve_hook(void);

void ksu_execve_hook_ksud(const struct pt_regs *regs)
{
    const char __user **filename_user_p = (const char __user **)&PT_REGS_PARM1(regs);
    const char __user *const __user *__argv = (const char __user *const __user *)PT_REGS_PARM2(regs);
    struct user_arg_ptr argv = { .ptr.native = __argv };
    char path[256];
    long ret;
    unsigned long addr;
    const char __user *fn;

    static const char app_process[] = "/system/bin/app_process";
    static bool first_zygote = true;
    static const char system_bin_init[] = "/system/bin/init";
    static bool init_second_stage_executed = false;

    if (!filename_user_p) return;
    addr = untagged_addr((unsigned long)*filename_user_p);
    fn = (const char __user *)addr;
    memset(path, 0, sizeof(path));
    ret = strncpy_from_user(path, fn, sizeof(path) - 1);
    if (ret <= 0) return;

    if (unlikely(!memcmp(path, system_bin_init, sizeof(system_bin_init) - 1) && __argv)) {
        char buf[16];
        if (!init_second_stage_executed &&
            check_argv(argv, 1, "second_stage", buf, sizeof(buf))) {
            pr_info("/system/bin/init second_stage executed\n");
            apply_kernelsu_rules();
            cache_sid();
            setup_ksu_cred();
            init_second_stage_executed = true;
        }
    }

    if (unlikely(first_zygote && !memcmp(path, app_process, sizeof(app_process) - 1) && __argv)) {
        char buf[16];
        if (check_argv(argv, 1, "-Xzygote", buf, sizeof(buf))) {
            pr_info("exec zygote, /data prepared, second_stage: %d\n", init_second_stage_executed);
            on_post_fs_data();
            first_zygote = false;
            ksu_stop_ksud_execve_hook();
        }
    }

#ifdef CONFIG_KSU_SUSFS
    {
        struct filename fname;
        fname.name = path;
        (void)ksu_handle_execveat_init(&fname, &argv, NULL);
    }
#endif
}

void ksu_stop_input_hook_runtime(void)
{
    extern struct static_key_true ksu_is_input_hook_enabled;
    if (static_key_enabled(&ksu_is_input_hook_enabled))
        static_branch_disable(&ksu_is_input_hook_enabled);
    pr_info("ksu_is_input_hook_enabled disabled\n");
}
KSUD_COMPAT_EOF
        echo "[SUSFS-Fixup] ksud_integration.c: Added compat wrappers"
    fi

    # ksu_late_loaded restoration
    if grep -q "ksu_late_loaded" "$INIT_C" 2>/dev/null; then
        if ! grep -q "bool ksu_late_loaded" "$INIT_C" 2>/dev/null; then
            sed -i '/^struct cred \*ksu_cred;/a bool ksu_late_loaded;' "$INIT_C" 2>/dev/null || true
        fi
        if [ -f "$KSU_H" ] && ! grep -q "extern bool ksu_late_loaded" "$KSU_H" 2>/dev/null; then
            sed -i '/^extern struct cred \*ksu_cred;/a extern bool ksu_late_loaded;' "$KSU_H" 2>/dev/null || true
        fi
    fi

    # Remove dead symbol refs if corresponding .o not in Kbuild
    if [ -f "$KBUILD" ]; then
        if ! grep -q "tp_marker.o" "$KBUILD" 2>/dev/null && [ -f "$APP_PROFILE_C" ]; then
            sed -i '/ksu_set_task_tracepoint_flag/d' "$APP_PROFILE_C" 2>/dev/null || true
            sed -i '/ksu_clear_task_tracepoint_flag/d' "$APP_PROFILE_C" 2>/dev/null || true
        fi
        if ! grep -q "syscall_event_bridge.o" "$KBUILD" 2>/dev/null && [ -f "$KSUD_INT_C" ]; then
            sed -i '/extern void ksu_stop_ksud_execve_hook/d' "$KSUD_INT_C" 2>/dev/null || true
            sed -i '/ksu_stop_ksud_execve_hook/d' "$KSUD_INT_C" 2>/dev/null || true
        fi
    fi
}

fix_ksu_next_susfs_umount() {
    # Inject susfs_set_current_proc_umounted() into setuid_hook.c
    #
    # CRITICAL DESIGN: This flag MUST be set at the setuid_hook level, NOT inside
    # ksu_handle_umount(). The reason is ksu_handle_umount() has multiple early
    # returns (ksu_module_mounted, ksu_kernel_umount_enabled, ksu_cred) that
    # prevent the flag from being set when no modules are installed. But SUSFS
    # map hiding needs the flag regardless of module state.
    #
    # The flag must be CONDITIONAL (only for apps needing umount), matching
    # SukiSU's pattern. If set unconditionally, fs/exec.c's do_execveat_common
    # hook will skip su handling for ALL apps, breaking root.
    if [ -f "$SETUID_HOOK_C" ]; then
        # Ensure workqueue include
        if ! grep -q "linux/workqueue.h" "$SETUID_HOOK_C" 2>/dev/null; then
            sed -i '/#include <linux\/susfs_def.h>/a #include <linux/workqueue.h>' "$SETUID_HOOK_C"
        fi

        # Repair existing direct calls if found
        if grep -q "susfs_run_sus_path_loop()" "$SETUID_HOOK_C" 2>/dev/null; then
            echo "[SUSFS-Fixup] setuid_hook.c: Migrating direct loop call to deferred workqueue"
            # Delete the old-style loop call block completely
            sed -i '/#ifdef CONFIG_KSU_SUSFS_SUS_PATH/,/#endif/d' "$SETUID_HOOK_C"
            # Inject new deferred workqueue block before susfs_set_current_proc_umounted()
            sed -i '/susfs_set_current_proc_umounted/i #ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\t\t{\n\t\t\textern struct work_struct susfs_extra_works;\n\t\t\tschedule_work(\&susfs_extra_works);\n\t\t}\n#endif' "$SETUID_HOOK_C"
        fi

        if ! grep -q "susfs_set_current_proc_umounted" "$SETUID_HOOK_C" 2>/dev/null; then
            sed -i '/ksu_handle_umount(old_uid, new_uid);/a \
\n#ifdef CONFIG_KSU_SUSFS\
\t/* Mark apps that need SUSFS hiding (map, mount, etc.).\
\t * This must be independent of ksu_module_mounted because SUSFS\
\t * map hiding needs this flag even when no modules are installed.\
\t * Only set for apps that should be umounted (not root-granted apps). */\
\tif (is_isolated_process(new_uid) ||\
\t    (is_appuid(new_uid) \&\& ksu_uid_should_umount(new_uid))) {\
#ifdef CONFIG_KSU_SUSFS_SUS_PATH\
\t\t{\
\t\t\textern struct work_struct susfs_extra_works;\
\t\t\tschedule_work(&susfs_extra_works);\
\t\t}\
#endif\
\t\tsusfs_set_current_proc_umounted();\
\t}\
#endif' "$SETUID_HOOK_C"
            echo "[SUSFS-Fixup] setuid_hook.c: Added conditional susfs_set_current_proc_umounted (workqueue)"
        fi
    fi
}

# ==========================================================================
# [SHARED] selinux_hide.c — remove undefined context_struct_compute_av_fn
# ==========================================================================
# The kernel's context_struct_compute_av in security/selinux/ss/services.c is
# static and not exported. selinux_hide.c has its own local copy, so remove
# the extern reference and always use the local implementation.
SELINUX_HIDE_C="$KSU_KERNEL/feature/selinux_hide.c"
if [ -f "$SELINUX_HIDE_C" ] && grep -q "context_struct_compute_av_fn\|security_dump_masked_av_fn" "$SELINUX_HIDE_C" 2>/dev/null; then
    # Remove the extern declarations (multi-line)
    sed -i '/^extern void context_struct_compute_av_fn/,/struct extended_perms \*xperms);/d' "$SELINUX_HIDE_C"
    sed -i '/^extern void security_dump_masked_av_fn/,/const char \*reason);/d' "$SELINUX_HIDE_C"
    # Replace conditional context_struct_compute_av_fn call with direct call
    sed -i '/context_struct_compute_av_fn/,+4{
        /if (context_struct_compute_av_fn)/c\    context_struct_compute_av(policydb, scontext, tcontext, tclass, avd, NULL);
        /context_struct_compute_av_fn(policydb/d
        /} else {/d
        /context_struct_compute_av(policydb/d
        /^[[:space:]]*}$/d
    }' "$SELINUX_HIDE_C"
    # Remove security_dump_masked_av_fn conditional call (debug audit, safe to drop)
    sed -i '/if (security_dump_masked_av_fn)/,+1d' "$SELINUX_HIDE_C"
    echo "[SUSFS-Fixup] selinux_hide.c: Removed undefined context_struct_compute_av_fn and security_dump_masked_av_fn"
fi

# ==========================================================================
# Dispatch per manager
# ==========================================================================
case "$MANAGER" in
    sukisu)
        fix_sulog_type_mismatch
        fix_execveat_handlers
        fix_kprobe_supercall
        ;;
    mambosu)
        fix_sulog_type_mismatch
        fix_execveat_handlers
        # MamboSU uses KernelSU-Next hooking architecture
        fix_ksu_next_kbuild
        fix_ksu_next_bridge
        fix_ksu_next_ksud
        # If it still has kprobe supercall, fix it, otherwise use next's
        if [ -f "$SUPERCALL_C" ] && grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then
            fix_kprobe_supercall
        else
            fix_ksu_next_supercall
        fi
        # Fix adb_root call signature mismatch in syscall_event_bridge.c
        # SUSFS patch changed adb_root from (struct pt_regs *) to
        # (const char *filename, void ***envp_user_ptr) but bridge still uses old call
        if [ -f "$BRIDGE_C" ] && grep -q 'ksu_adb_root_handle_execve((struct pt_regs \*)regs)' "$BRIDGE_C" 2>/dev/null; then
            sed -i 's|ksu_adb_root_handle_execve((struct pt_regs \*)regs)|ksu_adb_root_handle_execve((const char *)PT_REGS_PARM1(regs), (void __user ***)\&PT_REGS_PARM3(regs))|' "$BRIDGE_C"
            echo "[SUSFS-Fixup] syscall_event_bridge.c: Fixed adb_root call signature"
        fi
        # Restore ksu_sulog_capture_root_execve in event.c if missing
        if [ -f "$SULOG_EVENT_C" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_C" 2>/dev/null; then
            cat >> "$SULOG_EVENT_C" << 'SULOG_EXECVE_EOF'

struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user,
                                                              const char __user *const __user *argv_user, gfp_t gfp)
{
    struct user_arg_ptr _argv_wrap = { .ptr.native = argv_user };
    return ksu_sulog_capture(KSU_SULOG_EVENT_ROOT_EXECVE, filename_user, &_argv_wrap, gfp);
}
SULOG_EXECVE_EOF
            echo "[SUSFS-Fixup] sulog/event.c: Restored ksu_sulog_capture_root_execve"
        fi
        if [ -f "$SULOG_EVENT_H" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_H" 2>/dev/null; then
            sed -i '/ksu_sulog_capture_sucompat/i struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user, const char __user *const __user *argv_user, gfp_t gfp);' "$SULOG_EVENT_H"
        fi
        # MamboSU: Restore ksu_late_loaded removed by SUSFS patch
        if [ -f "$INIT_C" ] && grep -q "ksu_late_loaded" "$INIT_C" 2>/dev/null && \
           ! grep -q "bool ksu_late_loaded" "$INIT_C" 2>/dev/null; then
            # Restore variable definition after ksu_cred
            sed -i '/^struct cred \*ksu_cred;/a bool ksu_late_loaded;' "$INIT_C"
            # Restore #ifdef MODULE initialization block before the debug block
            sed -i '/^int __init kernelsu_init(void)/,/^{/{/^{/a\
#ifdef MODULE\n\tksu_late_loaded = (current->pid != 1);\n#else\n\tksu_late_loaded = false;\n#endif
}' "$INIT_C"
            echo "[SUSFS-Fixup] init.c: Restored ksu_late_loaded definition and init"
        fi
        if [ -f "$KSU_H" ] && grep -q "ksu_late_loaded" "$INIT_C" 2>/dev/null && \
           ! grep -q "ksu_late_loaded" "$KSU_H" 2>/dev/null; then
            sed -i '/^extern struct cred \*ksu_cred;/a extern bool ksu_late_loaded;' "$KSU_H"
            echo "[SUSFS-Fixup] ksu.h: Restored extern ksu_late_loaded"
        fi
        ;;
    ksu-next)
        fix_ksu_next_kbuild
        fix_ksu_next_bridge
        fix_ksu_next_supercall
        fix_ksu_next_ksud
        fix_execveat_handlers
        fix_ksu_next_susfs_umount
        ;;
    *)
        echo "[SUSFS-Fixup] Unknown manager '$MANAGER' — applying best-effort fixes"
        fix_sulog_type_mismatch
        # If kprobe-based, fix it; if not, try ksu-next fixes
        if [ -f "$SUPERCALL_C" ] && grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then
            fix_kprobe_supercall
        else
            fix_ksu_next_kbuild
            fix_ksu_next_bridge
            fix_ksu_next_supercall
            fix_ksu_next_ksud
        fi
        ;;
esac

echo "[SUSFS-Fixup] All compatibility fixups applied for $MANAGER!"
