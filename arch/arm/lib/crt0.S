/* SPDX-License-Identifier: GPL-2.0+ */
/*
 *  crt0 - C-runtime startup Code for ARM U-Boot
 *
 *  Copyright (c) 2012  Albert ARIBAUD <albert.u.boot@aribaud.net>
 */

#include <config.h>
#include <asm-offsets.h>
#include <linux/linkage.h>
#include <asm/assembler.h>
#include <system-constants.h>

/*
 * This file handles the target-independent stages of the U-Boot
 * start-up where a C runtime environment is needed. Its entry point
 * is _main and is branched into from the target's start.S file.
 *
 * _main execution sequence is:
 *
 * 1. Set up initial environment for calling board_init_f().
 *    This environment only provides a stack and a place to store
 *    the GD ('global data') structure, both located in some readily
 *    available RAM (SRAM, locked cache...). In this context, VARIABLE
 *    global data, initialized or not (BSS), are UNAVAILABLE; only
 *    CONSTANT initialized data are available. GD should be zeroed
 *    before board_init_f() is called.
 *
 * 2. Call board_init_f(). This function prepares the hardware for
 *    execution from system RAM (DRAM, DDR...) As system RAM may not
 *    be available yet, , board_init_f() must use the current GD to
 *    store any data which must be passed on to later stages. These
 *    data include the relocation destination, the future stack, and
 *    the future GD location.
 *
 * 3. Set up intermediate environment where the stack and GD are the
 *    ones allocated by board_init_f() in system RAM, but BSS and
 *    initialized non-const data are still not available.
 *
 * 4a.For U-Boot proper (not SPL), call relocate_code(). This function
 *    relocates U-Boot from its current location into the relocation
 *    destination computed by board_init_f().
 *
 * 4b.For SPL, board_init_f() just returns (to crt0). There is no
 *    code relocation in SPL.
 *
 * 5. Set up final environment for calling board_init_r(). This
 *    environment has BSS (initialized to 0), initialized non-const
 *    data (initialized to their intended value), and stack in system
 *    RAM (for SPL moving the stack and GD into RAM is optional - see
 *    CONFIG_SPL_STACK_R). GD has retained values set by board_init_f().
 *
 * 6. For U-Boot proper (not SPL), some CPUs have some work left to do
 *    at this point regarding memory, so call c_runtime_cpu_setup.
 *
 * 7. Branch to board_init_r().
 *
 * For more information see 'Board Initialisation Flow in README.
 */

/*
 * Macro for clearing BSS during SPL execution. Usually called during the
 * relocation process for most boards before entering board_init_r(), but
 * can also be done early before entering board_init_f() on plaforms that
 * can afford it due to sufficient memory being available early.
 */

.macro CLEAR_BSS
	ldr	r0, =__bss_start	/* this is auto-relocated! */

#ifdef CONFIG_USE_ARCH_MEMSET
	ldr	r3, =__bss_end		/* this is auto-relocated! */
	mov	r1, #0x00000000		/* prepare zero to clear BSS */

	subs	r2, r3, r0		/* r2 = memset len */
	bl	memset
#else
	ldr	r1, =__bss_end		/* this is auto-relocated! */
	mov	r2, #0x00000000		/* prepare zero to clear BSS */

clbss_l:cmp	r0, r1			/* while not at end of BSS */
	strlo	r2, [r0]		/* clear 32-bit BSS word */
	addlo	r0, r0, #4		/* move to next */
	blo	clbss_l
#endif
.endm

/*
 * entry point of crt0 sequence
 * _main 在 start.S 中被调用, 用于初始化C runtime环境并调用 board_init_f
 */

ENTRY(_main)

/* Call arch_very_early_init before initializing C runtime environment. */
/**
 * 首先查看是否打开了 CONFIG_IS_ENABLED(ARCH_VERY_EARLY_INIT) 这个宏，如果打开了，
 * 就调用 arch_very_early_init 函数，这个函数是在板级目录下的 lowlevel_init.S 中定义的
 * 用于初始化板级相关的配置
 */
#if CONFIG_IS_ENABLED(ARCH_VERY_EARLY_INIT)
	bl	arch_very_early_init
#endif

/*
 * Set up initial C runtime environment and call board_init_f(0).
 */
/**
 * 现在看看有没有打开 TPL_BUILD 和 CONFIG_TPL_NEEDS_SEPARATE_STACK 这两个宏
 * 如果有，则配置 TPL 的栈地址为 CONFIG_TPL_STACK
 *
 * 如果定义了 SPL_BUILD 和 CONFIG_SPL_STACK 这两个宏，则配置 SPL 的栈地址为 CONFIG_SPL_STACK
 * 则配置SPL的栈地址为 CONFIG_SPL_STACK
 *
 * 如果SPL和TPL都不是用独立的栈，那么就配置栈地址为 SYS_INIT_SP_ADDR
 */
#if defined(CONFIG_TPL_BUILD) && defined(CONFIG_TPL_NEEDS_SEPARATE_STACK)
	ldr	r0, =(CONFIG_TPL_STACK)
#elif defined(CONFIG_SPL_BUILD) && defined(CONFIG_SPL_STACK)
	ldr	r0, =(CONFIG_SPL_STACK)
#else
	ldr	r0, =(SYS_INIT_SP_ADDR)
#endif

	/**
	 * 清除 r0 的低三位，因为栈地址需要是8字节对齐的
	 */
	bic	r0, r0, #7	/* 8-byte alignment for ABI compliance */

	/**
	 * 现在， 将 栈地址配置到栈指针寄存器 sp 中
	 */
	mov	sp, r0

	/**
	 * 这个函数是用于保留一段内存，用于分配一段空间存放全局数据结构 global_data_t
	 * 这个数据结构在 arch/arm/include/asm/global_data.h 中定义
	 * 里面存放了一些板子的信息，日志的格式等乱七八糟的信息
	 *
	 * 这个函数有个参数 top, 用于指定分配的内存的顶部地址，返回值是 top - sizeof(global_data_t) 的地址
	 *
	 * 在ARM调用约定中，前四个参数存放在 r0-r3 中，返回值是存放在 r0 中
	 *
	 * 所以此处的 top 参数是存在 r0 中的，也就是栈顶地址，返回值是存放在 r0 中的
	 *
	 * 也就表明 global_data_t 结构体是存放在栈中的，并且是放在栈的最底部
	 *
	 * 这整个过程就是为了把 global_data_t 结构体压入栈中
	 */
	bl	board_init_f_alloc_reserve

	/**
	 * 将global_data_t 压入栈中后，更新栈指针
	 */
	mov	sp, r0

	/* set up gd here, outside any C code */
	/**
	 * 将当前栈顶地址存放到 r9 中
	 */
	mov	r9, r0

	/**
	 * 现在调用 board_init_f_init_reserve 函数
	 * 这个函数在 common/init/board_init.c 中定义
	 * 
	 * 这个函数有个参数： ulong base
	 * 这个 base 表示的是 global_data_t 结构体的地址，也就是寄存器 r0
	 * 这个函数的作用是初始化 global_data_t 结构体
	 * 
	 */
	bl	board_init_f_init_reserve

#if defined(CONFIG_DEBUG_UART) && CONFIG_IS_ENABLED(SERIAL)
	bl	debug_uart_init
#endif

#if defined(CONFIG_SPL_BUILD) && defined(CONFIG_SPL_EARLY_BSS)
	CLEAR_BSS
#endif

	mov	r0, #0
	bl	board_init_f

#if ! defined(CONFIG_SPL_BUILD)

/*
 * Set up intermediate environment (new sp and gd) and call
 * relocate_code(addr_moni). Trick here is that we'll return
 * 'here' but relocated.
 */

	ldr	r0, [r9, #GD_START_ADDR_SP]	/* sp = gd->start_addr_sp */
	bic	r0, r0, #7	/* 8-byte alignment for ABI compliance */
	mov	sp, r0
	ldr	r9, [r9, #GD_NEW_GD]		/* r9 <- gd->new_gd */

	adr	lr, here
#if defined(CONFIG_POSITION_INDEPENDENT)
	adr	r0, _main
	ldr	r1, _start_ofs
	add	r0, r1
	ldr	r1, =CONFIG_TEXT_BASE
	sub	r1, r0
	add	lr, r1
#if defined(CONFIG_SYS_RELOC_GD_ENV_ADDR)
	ldr	r0, [r9, #GD_ENV_ADDR]		/* r0 = gd->env_addr */
	add	r0, r0, r1
	str	r0, [r9, #GD_ENV_ADDR]
#endif
#endif
	ldr	r0, [r9, #GD_RELOC_OFF]		/* r0 = gd->reloc_off */
	add	lr, lr, r0
#if defined(CONFIG_CPU_V7M)
	orr	lr, #1				/* As required by Thumb-only */
#endif
	ldr	r0, [r9, #GD_RELOCADDR]		/* r0 = gd->relocaddr */
	b	relocate_code
here:
/*
 * now relocate vectors
 */

	bl	relocate_vectors

/* Set up final (full) environment */

	bl	c_runtime_cpu_setup	/* we still call old routine here */
#endif
#if !defined(CONFIG_SPL_BUILD) || CONFIG_IS_ENABLED(FRAMEWORK)

#if !defined(CONFIG_SPL_BUILD) || !defined(CONFIG_SPL_EARLY_BSS)
	CLEAR_BSS
#endif

# ifdef CONFIG_SPL_BUILD
	/* Use a DRAM stack for the rest of SPL, if requested */
	bl	spl_relocate_stack_gd
	cmp	r0, #0
	movne	sp, r0
	movne	r9, r0
# endif

#if ! defined(CONFIG_SPL_BUILD)
	bl coloured_LED_init
	bl red_led_on
#endif
	/* call board_init_r(gd_t *id, ulong dest_addr) */
	mov     r0, r9                  /* gd_t */
	ldr	r1, [r9, #GD_RELOCADDR]	/* dest_addr */
	/* call board_init_r */
#if CONFIG_IS_ENABLED(SYS_THUMB_BUILD)
	ldr	lr, =board_init_r	/* this is auto-relocated! */
	bx	lr
#else
	ldr	pc, =board_init_r	/* this is auto-relocated! */
#endif
	/* we should not return here. */
#endif

ENDPROC(_main)

_start_ofs:
	.word	_start - _main
