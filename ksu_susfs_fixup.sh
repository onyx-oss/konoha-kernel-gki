#!/bin/bash
# ==========================================================================
# SUSFS v2.1 Compatibility Fixup — Dynamic Multi-Manager Support
# ==========================================================================
# Surgically repairs SUSFS integration after 10_enable_susfs_for_ksu.patch
# which may partially fail on different KernelSU forks.
#
# Supported managers: KernelSU-Next, Sukisu-Ultra, MamboSU, 
#                     KernelSU Official, MKSU, KowSU, Wild KSU
# ==========================================================================
set -e

KSU_KERNEL="$1"
MANAGER_HINT="$2"

if [ -z "$KSU_KERNEL" ] || [ ! -d "$KSU_KERNEL" ]; then
    echo "Usage: $0 <path-to-ksu/kernel> [variant-name]"
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
            ksu-next|sukisu|resukisu|mambosu|apatch|folkpatch|ksu-official|mksu|kow-ksu|wild-ksu)
                echo "$hint" ;;
            *) echo "unknown" ;;
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
            *tiann/KernelSU*)                echo "ksu-official"; return ;;
            *mksu-org/MKSU*)                 echo "mksu"; return ;;
            *Kow-Mate/KernelSU*)             echo "kow-ksu"; return ;;
            *Wild-C/KernelSU*)               echo "wild-ksu"; return ;;
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
# [SHARED] sucompat.h — Complete rebuild to clean state
# ==========================================================================
rebuild_sucompat_h() {
    [ -f "$SUCOMPAT_H" ] || return 0
    local has_execve_sucompat=0 has_execveat_sucompat=0
    if [ -f "$SUCOMPAT_C" ]; then
        grep -q "ksu_handle_execve_sucompat" "$SUCOMPAT_C" 2>/dev/null && has_execve_sucompat=1
        grep -q "ksu_handle_execveat_sucompat" "$SUCOMPAT_C" 2>/dev/null && has_execveat_sucompat=1
    fi
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

    if [ "$has_execve_sucompat" -eq 1 ]; then
        cat >> "$SUCOMPAT_H" << 'EOF'

#ifndef CONFIG_KSU_SUSFS
long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, const struct pt_regs *regs);
#endif
EOF
    fi

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
    if ! grep -q "linux/susfs_def.h" "$SUCOMPAT_C" 2>/dev/null; then
        sed -i '1,/#include/{/#include/a #include <linux/susfs_def.h>
        }' "$SUCOMPAT_C" 2>/dev/null || true
    fi

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
        echo "[SUSFS-Fixup] sucompat.c: Fixed ksu_handle_stat version gate"
    fi

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
# Specific Fix Functions
# ==========================================================================
fix_kprobe_supercall() {
    if [ ! -f "$SUPERCALL_C" ]; then return; fi
    if ! grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then return; fi
    if ! grep -q "SUSFS_MAGIC" "$DISPATCH_C" 2>/dev/null; then return; fi

    if grep -q "ksu_susfs_dispatch_reboot" "$SUPERCALL_C" 2>/dev/null; then
        sed -i '/#ifdef CONFIG_KSU_SUSFS/,/#endif/d' "$SUPERCALL_C"
        echo "[SUSFS-Fixup] supercall.c: Removed kprobe SUSFS bridge (atomic context unsafe)"
    fi

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
        sed -i '/ksu_install_fd/a int ksu_supercall_reboot_handler(void __user **arg);' "$SUPERCALL_H" 2>/dev/null || true
    fi
}

fix_sulog_type_mismatch() {
    if [ ! -f "$SUCOMPAT_C" ]; then return; fi
    if [ -f "$SULOG_EVENT_H" ] && grep -q "struct user_arg_ptr \*argv_user" "$SULOG_EVENT_H" 2>/dev/null; then
        if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user' "$SUCOMPAT_C" 2>/dev/null; then
            sed -i '/pending_sucompat = ksu_sulog_capture_sucompat(\*filename_user, argv_user/c\
    {\
        struct user_arg_ptr _argv_wrap = { .ptr.native = argv_user };\
        pending_sucompat = ksu_sulog_capture_sucompat(*filename_user, \&_argv_wrap, GFP_KERNEL);\
    }' "$SUCOMPAT_C"
            echo "[SUSFS-Fixup] sucompat.c: Fixed sulog argv_user type mismatch"
        fi
    fi
}

fix_execveat_handlers() {
    if [ ! -f "$SUCOMPAT_C" ]; then return; fi
    if [ "$MANAGER" != "ksu-next" ] && grep -q "ksu_handle_execve_sucompat" "$SUCOMPAT_C" 2>/dev/null && \
       grep -q "ksu_syscall_table" "$SUCOMPAT_C" 2>/dev/null && \
       ! grep -q '#ifndef CONFIG_KSU_SUSFS' "$SUCOMPAT_C" 2>/dev/null; then
        sed -i '/^long ksu_handle_execve_sucompat/i\
#ifndef CONFIG_KSU_SUSFS' "$SUCOMPAT_C"
        local funcstart=$(grep -n "^long ksu_handle_execve_sucompat" "$SUCOMPAT_C" | head -1 | cut -d: -f1)
        if [ -n "$funcstart" ]; then
            local funcend=$(awk -v s="$funcstart" 'NR>s && /^}/{print NR; exit}' "$SUCOMPAT_C")
            [ -n "$funcend" ] && sed -i "${funcend}a\\#endif /* !CONFIG_KSU_SUSFS */" "$SUCOMPAT_C"
        fi
    fi

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
    if (unlikely(!filename_ptr)) return 0;
    filename = *filename_ptr;
    if (IS_ERR(filename)) return 0;
    if (!ksu_handle_execveat_init(filename, (struct user_arg_ptr *)argv_user, (struct user_arg_ptr *)envp_user)) return 0;
    if (likely(memcmp(filename->name, _su_path, sizeof(_su_path)))) return 0;
    if (!ksu_is_allow_uid_for_current(current_uid().val)) return 0;
    pr_info("ksu_handle_execveat_sucompat: su found\n");
    memcpy((void *)filename->name, _ksud_path, sizeof(_ksud_path));
    ret = escape_with_root_profile();
    if (ret) pr_err("escape_with_root_profile() failed: %d\n", ret);
    return 0;
}

int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
            void *envp, int *flags)
{
    if (ksu_handle_execveat_ksud(fd, filename_ptr, argv, envp, flags)) return 0;
    return ksu_handle_execveat_sucompat(fd, filename_ptr, argv, envp, flags);
}
#endif
EXECVEAT_SUCOMPAT_EOF
        echo "[SUSFS-Fixup] sucompat.c: Added ksu_handle_execveat_sucompat"
    fi
}

fix_ksu_next_kbuild() {
    if [ ! -f "$KBUILD" ]; then return; fi
    local need_restore=0
    for obj in "hook/lsm_hook.o" "hook/syscall_event_bridge.o" "hook/syscall_hook_manager.o" "hook/tp_marker.o"; do
        local src_file="$KSU_KERNEL/$(echo $obj | sed 's/\.o$/.c/')"
        if [ -f "$src_file" ] && ! grep -q "$obj" "$KBUILD" 2>/dev/null; then
            need_restore=1; break
        fi
    done
    if [ "$need_restore" -eq 1 ]; then
        sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/lsm_hook.o' "$KBUILD"
        sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/syscall_event_bridge.o' "$KBUILD"
        sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/syscall_hook_manager.o' "$KBUILD"
        sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/tp_marker.o' "$KBUILD"
        echo "[SUSFS-Fixup] Kbuild: Restored hook objects"
    fi
}

fix_ksu_next_bridge() {
    if [ ! -f "$BRIDGE_C" ]; then return; fi
    if grep -q "ksu_handle_setresuid(old_uid, current_uid().val)" "$BRIDGE_C" 2>/dev/null; then
        sed -i 's/ksu_handle_setresuid(old_uid, current_uid()\.val);/{\
        uid_t ruid = PT_REGS_PARM1(regs);\
        uid_t euid = PT_REGS_PARM2(regs);\
        uid_t suid = PT_REGS_PARM3(regs);\
        ksu_handle_setresuid(ruid, euid, suid);\
    }/' "$BRIDGE_C"
    fi
    sed -i 's|ksu_handle_stat(dfd, filename_user, flags);|ksu_handle_stat_user(dfd, filename_user, flags);|' "$BRIDGE_C" 2>/dev/null || true
}

fix_ksu_next_ksud() {
    if [ ! -f "$KSUD_INT_C" ]; then return; fi
    if grep -q "extern int ksu_handle_execveat_init" "$KSUD_INT_C" 2>/dev/null; then
        sed -i '/#include "selinux\/selinux.h"/a #include "feature/sucompat.h"' "$KSUD_INT_C"
        sed -i '/^extern int ksu_handle_execveat_init/d' "$KSUD_INT_C"
    fi
}

fix_ksu_next_susfs_umount() {
    if [ -f "$SETUID_HOOK_C" ] && ! grep -q "susfs_set_current_proc_umounted" "$SETUID_HOOK_C" 2>/dev/null; then
        sed -i '/ksu_handle_umount(old_uid, new_uid);/a \
\n#ifdef CONFIG_KSU_SUSFS\
\tif (is_isolated_process(new_uid) || (is_appuid(new_uid) && ksu_uid_should_umount(new_uid))) {\
#ifdef CONFIG_KSU_SUSFS_SUS_PATH\
\t\textern struct work_struct susfs_extra_works; schedule_work(&susfs_extra_works);\
#endif\
\t\tsusfs_set_current_proc_umounted();\
\t}\
#endif' "$SETUID_HOOK_C"
        echo "[SUSFS-Fixup] setuid_hook.c: Added susfs_set_current_proc_umounted"
    fi
}

# ==========================================================================
# Dispatch Logic
# ==========================================================================
case "$MANAGER" in
    mambosu|sukisu)
        fix_sulog_type_mismatch
        fix_execveat_handlers
        fix_kprobe_supercall
        ;;
    ksu-next|mksu|kow-ksu|wild-ksu|ksu-official)
        # Sebagian besar fork modern mengikuti struktur Next/Official baru
        fix_ksu_next_kbuild
        fix_ksu_next_bridge
        fix_ksu_next_ksud
        fix_execveat_handlers
        fix_ksu_next_susfs_umount
        ;;
    *)
        echo "[SUSFS-Fixup] Unknown manager '$MANAGER' — best effort mode"
        fix_sulog_type_mismatch
        fix_execveat_handlers
        ;;
esac

echo "[SUSFS-Fixup] All compatibility fixups applied for $MANAGER!"
