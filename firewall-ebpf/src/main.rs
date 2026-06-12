#![no_std]
#![no_main]

use aya_ebpf::{helpers::bpf_printk, macros::tracepoint, programs::TracePointContext};

#[tracepoint]
pub fn firewall(_ctx: TracePointContext) -> u32 {
    // Print to the kernel trace pipe: sudo cat /sys/kernel/tracing/trace_pipe
    unsafe { bpf_printk!(c"hello from eBPF: a process called execve") };
    0
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
