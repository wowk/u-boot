/* SPDX-License-Identifier: GPL-2.0+ */
/*
 *  armboot - Startup Code for ARM920 CPU-core
 *
 *  Copyright (c) 2001	Marius Gröger <mag@sysgo.de>
 *  Copyright (c) 2002	Alex Züpke <azu@sysgo.de>
 *  Copyright (c) 2002	Gary Jennejohn <garyj@denx.de>
 */

#include <asm-offsets.h>
#include <config.h>

/*
 *************************************************************************
 *
 * Startup Code (called from the ARM reset exception vector)
 *
 * do important init only if we don't start from memory!
 * relocate armboot to ram
 * setup stack
 * jump to second stage
 *
 *************************************************************************
 */

	.globl	reset

reset:
	/*
	 * 如果想看ARM寄存器相关的细节，可以查看文档 ARM Architecture Reference Manual
	 * 不同ARM指令集版本，有不同的手册，比如ARM920T对应的指令集版本为ARMv4T
	 * 如果想看ARM920T的细节，可以查看文档 ARM920T Technical Reference Manual
	 *
	 * CPSR 可以在文档 ARM Architecture Reference Manual 中查看
	 * 对于目前 CPSR 寄存器 （Current Program Status Register）, 其可以控制ARM的处理器模式
	 * 通过设置CPSR寄存器的值，可以切换ARM处理器的模式，刚上电的时候，我们需要配置处理器的模式
	 * CPSR 的 bit[4:0] 用于控制处理器的模式，bit[7:5] 用于控制处理器的状态
	 *
	 */
	 * set the cpu to SVC32 mode
	 */
	/* 读取CPSR寄存器的值并保存到 r0 */
	mrs	r0, cpsr
	/* bic 表示 bit clear, 此语句用于清除 r0 的低五位 */
	bic	r0, r0, #0x1f
	// 置位 bit[7] 表示禁用 IRQ 中断
	// 置位 bit[6] 表示禁用 FIQ 中断
	// 忽略 bit[5]
	// 将 bit[4:0] 设为 0x13, 二进制是 0b10011, 对应的处理器模式为 SuperVisor, 也就是 SVC32 模式 （因为是32位处理器）
	orr	r0, r0, #0xd3
	msr	cpsr, r0

	/*
	 * we do sys-critical inits only at reboot,
	 * not when booting from ram!
	 * 调用定义的 low_level_init 函数, 这个函数首先会flush 指令和数据cache，然后关闭MMU和cache
	 * 之后调用 lowlevel_init 函数，这个函数是在板级目录下的 lowlevel_init.S 中定义的
	 */
#if !CONFIG_IS_ENABLED(SKIP_LOWLEVEL_INIT)
	bl	cpu_init_crit
#endif

	/**
	 * 跳转到 _main 开始执行，这个函数是在 arch/arm/lib/crt0.S 中定义的
	 * 属于C runtime的一部分
   */
	bl	_main

/*------------------------------------------------------------------------------*/

/**
 * 这个函数在 arch/arm/lib/crt0.S 中调用，用户初始化C runtime环境
 
 */
	.globl	c_runtime_cpu_setup
c_runtime_cpu_setup:
	// 直接返回调用处，这个函数是一个空函数
	mov	pc, lr

/*
 *************************************************************************
 *
 * CPU_init_critical registers
 *
 * setup important registers
 * setup memory timing
 *
 *************************************************************************
 */


#if !CONFIG_IS_ENABLED(SKIP_LOWLEVEL_INIT)
cpu_init_crit:
	/*
	 * flush v4 I/D caches
	 */
	mov	r0, #0
	mcr	p15, 0, r0, c7, c7, 0	/* flush v3/v4 cache */
	mcr	p15, 0, r0, c8, c7, 0	/* flush v4 TLB */

	/*
	 * disable MMU stuff and caches
	 */
	mrc	p15, 0, r0, c1, c0, 0
	bic	r0, r0, #0x00002300	@ clear bits 13, 9:8 (--V- --RS)
	bic	r0, r0, #0x00000087	@ clear bits 7, 2:0 (B--- -CAM)
	orr	r0, r0, #0x00000002	@ set bit 1 (A) Align
	orr	r0, r0, #0x00001000	@ set bit 12 (I) I-Cache
	mcr	p15, 0, r0, c1, c0, 0

#if !CONFIG_IS_ENABLED(SKIP_LOWLEVEL_INIT_ONLY)
	/*
	 * before relocating, we have to setup RAM timing
	 * because memory timing is board-dependend, you will
	 * find a lowlevel_init.S in your board directory.
	 */
	mov	ip, lr

	bl	lowlevel_init
	mov	lr, ip
#endif
	mov	pc, lr
#endif /* CONFIG_IS_ENABLED(SKIP_LOWLEVEL_INIT) */
